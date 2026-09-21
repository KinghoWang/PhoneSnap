import AppKit

@MainActor
final class RecentScreenshotsPresenter {
    /// Newest first. Persists across batches so the panel shows a running
    /// "recent from iPhone" strip rather than only the last run.
    private var items: [URL] = []
    private var panelController: RecentScreenshotsPanelController?

    private static let maxItems = 20

    /// Shows the panel immediately on the first upload and appends live as
    /// the rest of the batch streams in — no debounce; waiting for the batch
    /// to go quiet made the panel feel several seconds late.
    func enqueue(fileURL: URL, activate: Bool = false) {
        items.removeAll { $0 == fileURL }
        items.insert(fileURL, at: 0)
        if items.count > Self.maxItems {
            items.removeLast(items.count - Self.maxItems)
        }

        if let panelController {
            panelController.update(fileURLs: items)
            panelController.show(activate: activate)
        } else {
            let controller = RecentScreenshotsPanelController(fileURLs: items) { [weak self] controller in
                if self?.panelController === controller {
                    self?.panelController = nil
                }
            }
            controller.onItemRemoved = { [weak self] removed in
                guard let self else { return }
                self.items.removeAll { $0 == removed }
                self.panelController?.update(fileURLs: self.items)
            }
            panelController = controller
            controller.show(activate: activate)
        }
    }
}

@MainActor
final class RecentScreenshotsPanelController: NSObject {
    private let panel: NSPanel
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let documentView = RecentScreenshotSelectionView(frame: .zero)
    private let deleteButton = NSButton(title: "删除所选", target: nil, action: nil)
    private var selection = RecentScreenshotSelection()
    private var orderedURLs: [URL] = []
    private let emptyLabel = NSTextField(labelWithString: "暂无最近截图")
    private let hintLabel = NSTextField(labelWithString: "回车复制单张 · 空白处拖动框选 · ⌘加选 · ⇧连选 · 双击编辑")
    private let onClosed: (RecentScreenshotsPanelController) -> Void
    /// Raised when a thumbnail trashes its file, so the owner can drop it
    /// from the strip's backing list.
    var onItemRemoved: ((URL) -> Void)?
    /// Cache so live batch updates reuse views instead of re-decoding images.
    private var itemViews: [URL: RecentScreenshotThumbnailView] = [:]

    private static let panelSize = NSSize(width: 760, height: 330)
    private static let edgeInset: CGFloat = 18
    private static let contentInset: CGFloat = 14
    private static let itemSize = NSSize(width: 200, height: 230)

    init(fileURLs: [URL], onClosed: @escaping (RecentScreenshotsPanelController) -> Void) {
        self.onClosed = onClosed
        let frame = Self.defaultFrame(size: Self.panelSize)
        panel = RecentScreenshotsPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "最近截图"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let root = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.contentView = root

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        stackView.orientation = .horizontal
        stackView.alignment = .top
        stackView.distribution = .gravityAreas
        stackView.spacing = 10
        stackView.edgeInsets = NSEdgeInsets(
            top: Self.contentInset,
            left: Self.contentInset,
            bottom: Self.contentInset,
            right: Self.contentInset
        )
        stackView.translatesAutoresizingMaskIntoConstraints = false

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)
        scrollView.documentView = documentView
        documentView.onBegin = { [weak self] flags in
            guard let self else { return }
            self.selection.beginMarquee(additive: !flags.intersection([.command, .shift]).isEmpty)
            self.refreshSelection()
        }
        documentView.onMarquee = { [weak self] start, end in
            guard let self else { return }
            let frames = self.itemViews.mapValues { self.documentView.convert($0.bounds, from: $0) }
            self.selection.marquee(from: start, to: end, frames: frames)
            self.refreshSelection()
        }
        documentView.onDelete = { [weak self] in self?.deleteSelected() }
        documentView.onCopy = { [weak self] in
            guard let self else { return }
            guard let target = self.selection.copyTarget(in: self.orderedURLs) else { NSSound.beep(); return }
            self.itemViews[target]?.copyAction()
        }
        documentView.onSelectAll = { [weak self] in
            guard let self else { return }
            self.selection.selectAll(self.orderedURLs)
            self.refreshSelection()
        }

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hintLabel)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.bezelStyle = .rounded
        deleteButton.toolTip = "将所选原图移到废纸篓，可从废纸篓恢复"
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -4),

            hintLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            hintLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            deleteButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            deleteButton.centerYAnchor.constraint(equalTo: hintLabel.centerYAnchor),
            deleteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),

            documentView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
            documentView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),

            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: documentView.heightAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])

        update(fileURLs: fileURLs)
    }

    func show(activate: Bool = false) {
        panel.setFrame(Self.defaultFrame(size: panel.frame.size), display: false)
        panel.orderFrontRegardless()
        if activate {
            if let latest = orderedURLs.first {
                selection.click(latest, ordered: orderedURLs, modifiers: [])
                refreshSelection()
            }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
            panel.makeFirstResponder(documentView)
        }
    }

    /// Incremental: existing thumbnails are never removed and re-added — a
    /// full rebuild tears down the view under the cursor and cancels any
    /// in-progress drag while a batch is still streaming in.
    func update(fileURLs: [URL]) {
        orderedURLs = fileURLs
        selection.retain(Set(fileURLs))
        emptyLabel.isHidden = !fileURLs.isEmpty

        let desired = Set(fileURLs)
        for (url, view) in itemViews where !desired.contains(url) {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
            itemViews[url] = nil
        }

        var index = 0
        for url in fileURLs {
            let item: RecentScreenshotThumbnailView
            if let cached = itemViews[url] {
                item = cached
            } else {
                guard let image = NSImage(contentsOf: url) else {
                    Log.error("Could not load recent screenshot image at \(url.path)")
                    continue
                }
                item = RecentScreenshotThumbnailView(image: image, fileURL: url, size: Self.itemSize)
                item.onRemoved = { [weak self] removed in self?.onItemRemoved?(removed) }
                item.onSelect = { [weak self] modifiers in
                    guard let self else { return }
                    self.panel.makeKey()
                    self.panel.makeFirstResponder(self.documentView)
                    self.selection.click(url, ordered: self.orderedURLs, modifiers: modifiers)
                    self.refreshSelection()
                }
                item.onContextSelect = { [weak self] in
                    guard let self else { return }
                    if !self.selection.selected.contains(url) {
                        self.selection.click(url, ordered: self.orderedURLs, modifiers: [])
                    }
                    self.refreshSelection()
                }
                item.onTrashSelection = { [weak self] in self?.deleteSelected() }
                item.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    item.widthAnchor.constraint(equalToConstant: Self.itemSize.width),
                    item.heightAnchor.constraint(equalToConstant: Self.itemSize.height)
                ])
                itemViews[url] = item
            }
            let arranged = stackView.arrangedSubviews
            if !(arranged.indices.contains(index) && arranged[index] === item) {
                stackView.insertArrangedSubview(item, at: min(index, arranged.count))
            }
            index += 1
        }
        selection.retain(Set(itemViews.keys))
        refreshSelection()
    }

    private func refreshSelection() {
        for (url, view) in itemViews { view.isSelected = selection.selected.contains(url) }
        deleteButton.isEnabled = !selection.selected.isEmpty
        deleteButton.title = selection.selected.isEmpty ? "删除所选" : "删除所选（\(selection.selected.count)）"
    }

    @objc private func deleteSelected() {
        let urls = orderedURLs.filter { selection.selected.contains($0) }
        guard !urls.isEmpty else { return }
        let result = RecentScreenshotDeletion.perform(urls) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        for url in result.removed { onItemRemoved?(url) }
        update(fileURLs: orderedURLs.filter { !result.removed.contains($0) })
        if !result.failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = "\(result.failed.count) 张截图未能移到废纸篓"
            alert.informativeText = "失败的截图仍保留在列表中，请检查文件是否存在及访问权限。已成功移动 \(result.removed.count) 张。"
            alert.beginSheetModal(for: panel)
        }
    }

    private static func defaultFrame(size: NSSize) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first!
        let vf = screen.visibleFrame
        let width = min(size.width, vf.width - 2 * edgeInset)
        let height = min(size.height, vf.height - 2 * edgeInset)
        let x = vf.maxX - width - edgeInset
        let y = vf.maxY - height - edgeInset
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

extension RecentScreenshotsPanelController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            onClosed(self)
        }
    }
}

@MainActor
final class RecentScreenshotThumbnailView: NSView, NSDraggingSource {
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    var onContextSelect: (() -> Void)?
    var onTrashSelection: (() -> Void)?
    var isSelected = false { didSet { updateSelectionAppearance() } }
    private var selectionOnly = false
    private let image: NSImage
    private let fileURL: URL
    private let imageLayer = CALayer()
    private let label = NSTextField(labelWithString: "")
    private let copiedLabel = NSTextField(labelWithString: "已复制")

    init(image: NSImage, fileURL: URL, size: NSSize) {
        self.image = image
        self.fileURL = fileURL
        super.init(frame: NSRect(origin: .zero, size: size))

        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        imageLayer.contents = image
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor
        imageLayer.cornerRadius = 6
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)

        let metadata = ScreenshotMetadata.read(from: fileURL)
        let summary = ScreenshotMetadata.summary(metadata, bytes: ScreenshotMetadata.fileBytes(fileURL))
        label.stringValue = summary.joined(separator: "\n")
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 4
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        copiedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        copiedLabel.textColor = .white
        copiedLabel.alignment = .center
        copiedLabel.wantsLayer = true
        copiedLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        copiedLabel.layer?.cornerRadius = 8
        copiedLabel.translatesAutoresizingMaskIntoConstraints = false
        copiedLabel.isHidden = true
        addSubview(copiedLabel)

        let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let dimensions = pixels.map { "\($0.width) × \($0.height) 像素" } ?? "像素尺寸未知"
        var detail = [fileURL.lastPathComponent, dimensions] + summary
        if let metadata {
            detail.append(metadata.sizeExplanation)
            if let path = metadata.path { detail.append("通路证据：\(path)") }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
            detail.append("Mac 保存时间：\(formatter.string(from: metadata.savedAt))")
            if metadata.source == .relay { detail.append("接收计时：HTTP 响应头到图片保存；不含空闲等图、手机上传或回执返回。") }
            if metadata.source == .nearby { detail.append("接收计时：开始接收图片正文到保存；不含发现、连接或回执返回。普通 Wi-Fi 与热点没有独立确认信号，不据接口名或网络费用特征猜测；点对点只在连接端点证实时标注。") }
            if metadata.source == .relay { detail.append("公网加密中转：即使插着 USB 或连接 Wi-Fi／热点，也不代表这张图采用直传。") }
        }
        toolTip = detail.joined(separator: "\n")
        menu = makeContextMenu()
        let pin = NSButton(title: "", target: self, action: #selector(pinAction))
        pin.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "钉选到屏幕")
        pin.toolTip = "钉选到屏幕"
        pin.bezelStyle = .rounded
        pin.controlSize = .small
        pin.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pin)

        NSLayoutConstraint.activate([
            pin.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pin.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            pin.widthAnchor.constraint(equalToConstant: 24),
            pin.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            label.heightAnchor.constraint(equalToConstant: 60),

            copiedLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            copiedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            copiedLabel.widthAnchor.constraint(equalToConstant: 64),
            copiedLabel.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Removed from the strip by the owning panel when the file is trashed.
    var onRemoved: ((URL) -> Void)?

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, Selector)] = [
            ("复制", #selector(copyAction)),
            ("编辑／隐私打码", #selector(editAction)),
            ("钉选到屏幕", #selector(pinAction)),
            ("用预览打开原图", #selector(openAction)),
            ("另存副本…", #selector(saveAction)),
            ("在访达中显示", #selector(revealAction)),
            ("移到废纸篓", #selector(trashAction))
        ]
        for (title, action) in entries {
            if title == "移到废纸篓" { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc func copyAction() {
        Pasteboard.write(fileURL: fileURL)
        flashCopied()
    }

    @objc private func openAction() {
        NSWorkspace.shared.open(fileURL)
    }

    @objc private func editAction() { ScreenshotEditor.shared.open(fileURL: fileURL) }
    @objc private func pinAction() { PinnedImagePresenter.shared.pin(fileURL: fileURL) }

    @objc private func saveAction() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: fileURL, to: destination)
        } catch {
            Log.error("Save a Copy failed: \(error)")
            NSSound.beep()
        }
    }

    @objc private func revealAction() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func trashAction() {
        if let onTrashSelection { onTrashSelection(); return }
        do {
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            onRemoved?(fileURL)
        } catch {
            Log.error("Move to Trash failed: \(error)")
            NSSound.beep()
        }
    }

    /// The panel moves when dragged by its background; a drag that starts on
    /// a thumbnail must start an image drag instead of moving the window.
    override var mouseDownCanMoveWindow: Bool { false }

    /// PhoneSnap is a menu bar app, so this panel is usually in an inactive
    /// application. Without this, macOS spends the first click activating the
    /// window instead of delivering it, so `mouseDown` never records a start
    /// point and the first drag attempt silently does nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        imageLayer.frame = imageRect()
        setHovered(mouseIsInside())
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(mouseIsInside())
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    /// Views shift under a stationary cursor as new thumbnails stream in, so
    /// enter/exit events alone leave stale highlights — recheck on layout.
    private func mouseIsInside() -> Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    private var isHovered = false

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateSelectionAppearance()
        if hovered { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
    }

    private func updateSelectionAppearance() {
        layer?.borderColor = (isSelected || isHovered) ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
        layer?.borderWidth = isSelected ? 3 : (isHovered ? 2 : 1)
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : NSColor.controlBackgroundColor.cgColor
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextSelect?()
        menu?.items.last?.title = onTrashSelection == nil ? "移到废纸篓" : "将所选截图移到废纸篓"
        super.rightMouseDown(with: event)
    }

    private var mouseDownLocation: NSPoint?
    private var dragSessionActive = false

    override func mouseDown(with event: NSEvent) {
        pendingCopy?.cancel()
        selectionOnly = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        onSelect?(event.modifierFlags)
        mouseDownLocation = event.locationInWindow
        dragSessionActive = false
    }

    override func mouseDragged(with event: NSEvent) {
        // Start exactly one drag session per gesture, and only after the
        // cursor has actually moved — beginning a session on every drag
        // event made drags flaky and turned click jitter into failed drags.
        guard !dragSessionActive else { return }
        guard let down = mouseDownLocation else { return }
        let dx = event.locationInWindow.x - down.x
        let dy = event.locationInWindow.y - down.y
        guard dx * dx + dy * dy >= 9 else { return }
        dragSessionActive = true

        let pbItem = NSPasteboardItem()
        pbItem.setDataProvider(self, forTypes: [.fileURL])
        pbItem.setString(fileURL.absoluteString, forType: .fileURL)
        // Also carry raw PNG bytes so drop targets that don't accept file
        // URLs (web chat boxes, some agent UIs) still receive the image.
        if let data = try? Data(contentsOf: fileURL) {
            pbItem.setData(data, forType: .png)
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
        let dragSize = NSSize(width: min(140, bounds.width), height: min(120, bounds.height))
        let location = convert(event.locationInWindow, from: nil)
        let dragFrame = NSRect(
            x: location.x - dragSize.width / 2,
            y: location.y - dragSize.height / 2,
            width: dragSize.width,
            height: dragSize.height
        )
        draggingItem.setDraggingFrame(dragFrame, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragSessionActive = false
        mouseDownLocation = nil
    }

    private var pendingCopy: DispatchWorkItem?

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        if dragSessionActive { dragSessionActive = false; return }
        if selectionOnly { return }
        if event.clickCount >= 2 {
            // Cancel the pending single-click copy — otherwise a double
            // click copies on the first click and opens on the second.
            pendingCopy?.cancel()
            pendingCopy = nil
            ScreenshotEditor.shared.open(fileURL: fileURL)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingCopy = nil
                Pasteboard.write(fileURL: self.fileURL)
                self.flashCopied()
            }
            pendingCopy = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    private func imageRect() -> NSRect {
        NSRect(
            x: 6,
            y: 73,
            width: max(0, bounds.width - 12),
            height: max(0, bounds.height - 80)
        )
    }

    private func flashCopied() {
        copiedLabel.isHidden = false
        copiedLabel.alphaValue = 1
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.9
            copiedLabel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.copiedLabel.isHidden = true
        })
    }
}

extension RecentScreenshotThumbnailView: NSPasteboardItemDataProvider {
    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        // The file URL is written inline on the pasteboard item.
    }
}
