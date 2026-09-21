import AppKit
import UniformTypeIdentifiers
import ImageIO

final class EditorWindow: NSWindow {
    var onCommand: ((String, Bool) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), !(firstResponder is NSTextView),
           onCommand?(event.charactersIgnoringModifiers?.lowercased() ?? "", event.modifierFlags.contains(.shift)) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class EditedImageDragButton: NSButton, NSDraggingSource {
    var imageProvider: (() -> NSImage?)?
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard let image = imageProvider?(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let grabbitDocument: GrabbitDocument
    private let sourceURL: URL?
    private let imageView = NSImageView()
    private let overlay = AnnotationOverlay()
    private let cropOverlay = CropOverlayView()
    private let canvas = NSView()
    private let scroll = NSScrollView()
    private let tools = NSSegmentedControl(labels: ["选择", "箭头", "矩形", "文字", "手动打码", "裁剪"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "编辑副本，不覆盖原图。智能识别可能漏检；复制或导出前请检查。")
    private let privacyButton = NSButton(title: "智能打码（本机）", target: nil, action: nil)
    private let extractAllButton = NSButton(title: "整图提取文字", target: nil, action: nil)
    private let extractRegionButton = NSButton(title: "框选提取文字", target: nil, action: nil)
    private let redactionStyle = NSPopUpButton(frame: .zero, pullsDown: false)
    private let redactionColor = NSColorWell()
    private let redactionIntensity = NSSlider(value: 80, minValue: 10, maxValue: 100, target: nil, action: nil)
    private var extractionID: UUID?
    private var extractionResult: TextExtractionResultController?
    private var revision = 0
    private var scanID: UUID?
    private var exportedRevision: Int?
    private var zoom: CGFloat = 1
    var onClosed: (() -> Void)?

    init(document: GrabbitDocument, sourceURL: URL? = nil) {
        self.grabbitDocument = document
        self.sourceURL = sourceURL
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "PhoneSnap · 截图编辑"
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        document.borderEnabled = false
        document.shadowEnabled = false
        document.addWindowController(self)
        overlay.document = document
        overlay.imageProvider = { [weak document] in document?.currentImage }
        overlay.imageDisplayRectProvider = { [weak self] in self?.canvas.bounds ?? .zero }
        overlay.onCopy = { [weak self] in self?.copyEdited() }
        overlay.onOCRRegionSelected = { [weak self] region in self?.extractText(region: region) }
        overlay.onSelectionChanged = { [weak self] _ in
            guard let self, let selected = self.overlay.selectedRedaction else { return }
            self.tools.selectedSegment = 4
            self.redactionStyle.selectItem(at: selected.pixelated ? 1 : 0)
            if !selected.pixelated { self.redactionColor.color = selected.color }
            self.redactionIntensity.doubleValue = Double(selected.intensity)
            self.redactionColor.isEnabled = !selected.pixelated
            self.redactionIntensity.isEnabled = selected.pixelated
            self.overlay.currentBlurStyle = .pixelate
            self.overlay.currentBlurIntensity = selected.intensity
            self.overlay.currentFillColor = self.redactionColor.color
            self.overlay.currentBorderColor = self.redactionColor.color
            self.overlay.currentBorderWeight = 0
            self.overlay.activeTool = selected.pixelated ? .blur : .shape
        }
        cropOverlay.imageDisplayRectProvider = { [weak self] in self?.canvas.bounds ?? .zero }
        cropOverlay.onCropConfirmed = { [weak self] rect in self?.crop(to: rect) }
        cropOverlay.onCropCancelled = { [weak self] in self?.selectTool(0) }
        document.onAnnotationsChanged = { [weak self] in
            guard let self else { return }
            self.revision += 1
            self.overlay.needsDisplay = true
            self.window?.isDocumentEdited = self.exportedRevision != self.revision
        }
        document.onImageChanged = { [weak self] in
            self?.revision += 1
            self?.updateCanvas()
        }
        window.onCommand = { [weak self] key, shift in
            guard let self else { return false }
            switch key {
            case "c": self.copyEdited()
            case "s": self.saveEdited()
            case "z": shift ? self.redoEdit() : self.undoEdit()
            default: return false
            }
            return true
        }
        makeContent()
        zoom = min(1, min(950 / max(1, document.currentImage.size.width), 620 / max(1, document.currentImage.size.height)))
        updateCanvas()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String { "PhoneSnap · 截图编辑" }

    private func makeContent() {
        guard let root = window?.contentView else { return }
        tools.target = self
        tools.action = #selector(toolChanged)
        tools.selectedSegment = 0
        let undo = button("撤销", #selector(undoEdit))
        let redo = button("重做", #selector(redoEdit))
        let smaller = button("缩小", #selector(zoomOut))
        let larger = button("放大", #selector(zoomIn))
        privacyButton.target = self
        privacyButton.action = #selector(detectPrivacy)
        privacyButton.bezelStyle = .rounded
        let top = NSStackView(views: [tools, undo, redo, smaller, larger, privacyButton])
        top.spacing = 6
        top.orientation = .horizontal
        extractAllButton.target = self
        extractAllButton.action = #selector(extractAllText)
        extractRegionButton.target = self
        extractRegionButton.action = #selector(selectTextRegion)
        for button in [extractAllButton, extractRegionButton] { button.bezelStyle = .rounded }
        let extractionNote = NSTextField(labelWithString: "本机中英文 OCR · 仅识别当前已编辑画面")
        extractionNote.font = .systemFont(ofSize: 11)
        extractionNote.textColor = .secondaryLabelColor
        let extractionRow = NSStackView(views: [extractAllButton, extractRegionButton, extractionNote])
        extractionRow.spacing = 8
        redactionStyle.addItems(withTitles: ["纯色", "马赛克"])
        redactionStyle.target = self
        redactionStyle.action = #selector(redactionChanged)
        redactionColor.color = .black
        redactionColor.target = self
        redactionColor.action = #selector(redactionChanged)
        redactionIntensity.target = self
        redactionIntensity.action = #selector(redactionChanged)
        redactionIntensity.isContinuous = false
        redactionIntensity.isEnabled = false
        redactionColor.widthAnchor.constraint(equalToConstant: 42).isActive = true
        redactionIntensity.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let redactionRow = NSStackView(views: [NSTextField(labelWithString: "打码样式"), redactionStyle,
            NSTextField(labelWithString: "颜色"), redactionColor, NSTextField(labelWithString: "粗细"), redactionIntensity,
            NSTextField(labelWithString: "马赛克可能保留可辨认内容；敏感文字建议纯色")])
        redactionRow.spacing = 8
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.documentView = canvas
        imageView.imageScaling = .scaleAxesIndependently
        canvas.addSubview(imageView)
        canvas.addSubview(overlay)
        canvas.addSubview(cropOverlay)
        cropOverlay.isHidden = true
        for view in [imageView, overlay, cropOverlay] {
            view.autoresizingMask = [.width, .height]
        }
        let drag = EditedImageDragButton(title: "拖出编辑结果", target: nil, action: nil)
        drag.bezelStyle = .rounded
        drag.imageProvider = { [weak self] in self?.renderedImage() }
        let bottom = NSStackView(views: [button("复制结果 ⌘C", #selector(copyEdited)), button("另存为… ⌘S", #selector(saveEdited)), button("钉选编辑结果", #selector(pinEdited)), drag])
        bottom.spacing = 8
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        for view in [top, extractionRow, redactionRow, scroll, status, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            extractionRow.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            extractionRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            extractionRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            redactionRow.topAnchor.constraint(equalTo: extractionRow.bottomAnchor, constant: 8),
            redactionRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            redactionRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: redactionRow.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        return result
    }

    private func updateCanvas() {
        let size = grabbitDocument.currentImage.size
        canvas.setFrameSize(NSSize(width: max(1, size.width * zoom), height: max(1, size.height * zoom)))
        imageView.image = grabbitDocument.currentImage
        for view in [imageView, overlay, cropOverlay] { view.frame = canvas.bounds }
        overlay.needsDisplay = true
    }

    @objc private func toolChanged() { selectTool(tools.selectedSegment) }

    @objc private func redactionChanged() {
        let pixelated = redactionStyle.indexOfSelectedItem == 1
        redactionColor.color = redactionColor.color.withAlphaComponent(1)
        redactionColor.isEnabled = !pixelated
        redactionIntensity.isEnabled = pixelated
        overlay.changeSelectedRedaction(pixelated: pixelated, color: redactionColor.color,
                                        intensity: CGFloat(redactionIntensity.doubleValue))
        overlay.currentBlurStyle = .pixelate
        overlay.currentBlurIntensity = CGFloat(redactionIntensity.doubleValue)
        overlay.currentFillColor = redactionColor.color
        overlay.currentBorderColor = redactionColor.color
        if tools.selectedSegment == 4 {
            overlay.currentBorderWeight = 0
            overlay.activeTool = pixelated ? .blur : .shape
        }
    }

    private func selectTool(_ index: Int) {
        overlay.finalizeEditing()
        tools.selectedSegment = index < tools.segmentCount ? index : -1
        cropOverlay.isHidden = index != 5
        overlay.isHidden = index == 5
        switch index {
        case 1: overlay.activeTool = .arrow
        case 2:
            overlay.currentBorderColor = .systemRed
            overlay.currentBorderWeight = 2
            overlay.currentFillColor = .clear
            overlay.activeTool = .shape
        case 3: overlay.activeTool = .text
        case 4:
            overlay.currentBorderColor = redactionColor.color.withAlphaComponent(1)
            overlay.currentBorderWeight = 0
            overlay.currentFillColor = redactionColor.color.withAlphaComponent(1)
            overlay.currentBlurStyle = .pixelate
            overlay.currentBlurIntensity = CGFloat(redactionIntensity.doubleValue)
            overlay.activeTool = redactionStyle.indexOfSelectedItem == 1 ? .blur : .shape
            status.stringValue = "拖框覆盖隐私。选择工具可移动、缩放或删除遮挡；导出前检查。"
        case 5:
            overlay.activeTool = .none
            cropOverlay.reset()
            status.stringValue = "拖动选择裁剪区域，按回车确认，Esc 取消。裁剪会合并当前标注，可撤销。"
        case 6:
            overlay.activeTool = .ocr
            status.stringValue = "拖框后松开鼠标提取文字。仅识别当前已编辑画面，已打码区域不会回读原图。"
        default: overlay.activeTool = .none
        }
        window?.makeFirstResponder(index == 5 ? cropOverlay : overlay)
    }

    @objc private func undoEdit() { overlay.finalizeEditing(); grabbitDocument.undoManager?.undo(); overlay.needsDisplay = true }
    @objc private func redoEdit() { overlay.finalizeEditing(); grabbitDocument.undoManager?.redo(); overlay.needsDisplay = true }
    @objc private func zoomIn() { zoom = min(2, zoom * 1.25); updateCanvas() }
    @objc private func zoomOut() { zoom = max(0.08, zoom / 1.25); updateCanvas() }

    func renderedImage() -> NSImage? {
        guard scanID == nil else {
            status.stringValue = "正在识别，请等待结果并检查后再复制、导出或裁剪。"
            return nil
        }
        overlay.finalizeEditing()
        return grabbitDocument.flattenedForSharing(displayWidth: canvas.bounds.width)
    }

    func crop(to rect: CGRect) {
        guard let rendered = renderedImage(),
              let cgImage = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let pixels = CGRect(x: rect.minX * CGFloat(cgImage.width), y: (1 - rect.maxY) * CGFloat(cgImage.height),
                            width: rect.width * CGFloat(cgImage.width), height: rect.height * CGFloat(cgImage.height)).integral
        guard pixels.width >= 1, pixels.height >= 1, let cropped = cgImage.cropping(to: pixels) else { return }
        grabbitDocument.loadImage(NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height)))
        grabbitDocument.undoManager?.setActionName("裁剪并合并标注")
        selectTool(0)
        status.stringValue = "已裁剪。原图未覆盖；可撤销。"
    }

    @objc func pinEdited() {
        guard let image = renderedImage(), PinnedImagePresenter.shared.pin(image: image) != nil else { return }
        status.stringValue = "已钉选当前编辑结果。关闭钉图不会删除原图；需要长期保留请另存为。"
    }

    @objc private func copyEdited() {
        guard let image = renderedImage(), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            status.stringValue = "复制失败，未输出原图。"
            return
        }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { status.stringValue = "写入剪贴板失败，请重试。"; return }
        exportedRevision = revision
        window?.isDocumentEdited = false
        status.stringValue = "已复制合并后的编辑结果（不含原图文件引用）。请确认没有漏遮挡。"
    }

    @objc private func saveEdited() {
        guard let image = renderedImage(), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "截图-已编辑.png"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if let sourceURL, destination.resolvingSymlinksInPath().standardizedFileURL == sourceURL.resolvingSymlinksInPath().standardizedFileURL {
            status.stringValue = "为保留原图，请换一个文件名保存编辑副本。"
            return
        }
        do {
            try data.write(to: destination, options: .atomic)
            exportedRevision = revision
            window?.isDocumentEdited = false
            status.stringValue = "已保存合并后的 PNG 副本。"
        } catch { status.stringValue = "保存失败，请检查文件夹权限或磁盘空间。" }
    }

    @objc private func detectPrivacy() {
        guard scanID == nil else { return }
        overlay.finalizeEditing()
        guard let image = grabbitDocument.currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        extractionID = nil
        setExtractionEnabled(false)
        let identifier = UUID()
        scanID = identifier
        let startingRevision = revision
        privacyButton.isEnabled = false
        status.stringValue = "正在本机识别文字、人脸、二维码和头像候选，不上传图片…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try PrivacyDetector.detect(in: image) }
            DispatchQueue.main.async {
                guard let self, self.scanID == identifier else { return }
                self.scanID = nil
                self.privacyButton.isEnabled = true
                self.setExtractionEnabled(true)
                guard self.revision == startingRevision else {
                    self.status.stringValue = "识别期间图片有改动，已丢弃旧结果。请重新识别。"
                    return
                }
                switch result {
                case .success(let regions):
                    self.grabbitDocument.addPrivacyRegions(regions.map(\.rect),
                        pixelated: self.redactionStyle.indexOfSelectedItem == 1,
                        color: self.redactionColor.color, intensity: CGFloat(self.redactionIntensity.doubleValue))
                    self.selectTool(0)
                    let categories = Set(regions.map { $0.kind.rawValue }).sorted().joined(separator: "、")
                    self.status.stringValue = regions.isEmpty
                        ? "未检出候选，不代表没有隐私。请检查姓名、地址和头像，必要时手动打码。"
                        : "已遮挡 \(regions.count) 处候选（\(categories)）。姓名、地址和非人脸头像可能漏检；可选中删除误遮挡。"
                case .failure:
                    self.status.stringValue = "本机识别失败，未自动遮挡。请使用手动打码，不要把失败当作没有隐私。"
                }
            }
        }
    }

    func makeOCRSnapshot(region: CGRect?) -> CGImage? {
        guard let flattened = renderedImage(),
              let image = flattened.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return try? TextExtraction.image(from: image, region: region)
    }

    private func setExtractionEnabled(_ enabled: Bool) {
        extractAllButton.isEnabled = enabled
        extractRegionButton.isEnabled = enabled
    }

    @objc private func extractAllText() { extractText(region: nil) }
    @objc private func selectTextRegion() { selectTool(6) }

    private func extractText(region: CGRect?) {
        guard extractionID == nil, scanID == nil, window?.attachedSheet == nil else { return }
        guard let snapshot = makeOCRSnapshot(region: region) else {
            status.stringValue = "无法提取：请确认图片有效、识别区域足够大，并等待打码任务完成。"
            return
        }
        selectTool(0)
        let identifier = UUID()
        let startingRevision = revision
        extractionID = identifier
        setExtractionEnabled(false)
        privacyButton.isEnabled = false
        status.stringValue = "正在本机提取当前画面的文字，不上传图片，不读取原图文件…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try TextExtraction.recognize(in: snapshot) }
            DispatchQueue.main.async {
                guard let self, self.extractionID == identifier else { return }
                self.extractionID = nil
                self.setExtractionEnabled(true)
                self.privacyButton.isEnabled = true
                guard self.revision == startingRevision else {
                    self.status.stringValue = "识别期间图片被修改，已丢弃旧文字结果。请重新提取。"
                    return
                }
                switch result {
                case .success(let text):
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self.status.stringValue = "未识别到文字。可尝试框选更清晰区域；已打码的文字不会恢复。"
                        return
                    }
                    guard let window = self.window, window.isVisible, window.attachedSheet == nil else { return }
                    let controller = TextExtractionResultController(text: text)
                    controller.onClosed = { [weak self] in self?.extractionResult = nil }
                    self.extractionResult = controller
                    self.status.stringValue = "文字已提取，尚未复制。请在结果窗口检查、修正后复制或导出。"
                    controller.present(on: window)
                case .failure:
                    self.status.stringValue = "本机文字识别失败。图片未修改，剪贴板未写入；请稍后重试或缩小识别区域。"
                }
            }
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { grabbitDocument.undoManager }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        overlay.finalizeEditing()
        guard revision > 0, exportedRevision != revision else { return true }
        let alert = NSAlert()
        alert.messageText = "关闭未导出的编辑？"
        alert.informativeText = "原图不会修改，但当前标注和遮挡会丢失。"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃并关闭")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        scanID = nil
        extractionID = nil
        extractionResult?.dismissResult()
        extractionResult = nil
        grabbitDocument.onAnnotationsChanged = nil
        grabbitDocument.onImageChanged = nil
        grabbitDocument.removeWindowController(self)
        onClosed?()
    }
}

@MainActor
final class ScreenshotEditor {
    static let shared = ScreenshotEditor()
    private var editors: [EditorWindowController] = []
    var hasOpenEditors: Bool { !editors.isEmpty }

    func open(fileURL: URL) {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 50_000_000 / height,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
              ] as CFDictionary) else {
            let alert = NSAlert()
            alert.messageText = "无法打开这张图片"
            alert.informativeText = "请选择有效的位图文件，且总像素不超过 5000 万。"
            alert.runModal()
            return
        }
        let normalized = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        open(image: normalized, sourceURL: fileURL)
    }

    func open(image: NSImage, sourceURL: URL? = nil) {
        let controller = EditorWindowController(document: GrabbitDocument(image: image), sourceURL: sourceURL)
        controller.onClosed = { [weak self, weak controller] in self?.editors.removeAll { $0 === controller } }
        editors.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(fileURL: url)
    }

    func canTerminate() -> Bool {
        editors.allSatisfy { editor in
            guard let window = editor.window else { return true }
            return editor.windowShouldClose(window)
        }
    }
}
