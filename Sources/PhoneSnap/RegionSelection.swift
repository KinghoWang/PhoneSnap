import AppKit

enum RegionSelectionAction: Int, CaseIterable {
    case pin, edit, copy, save, ocr, cancel
    var title: String { ["钉选", "编辑", "复制", "保存", "OCR 提取", "取消"][rawValue] }
}

final class RegionSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RegionSelectionView: NSView {
    let toolbar = NSStackView()
    private let image: NSImage
    private let screenOrigin: NSPoint
    private var selectionRect = CGRect.zero
    private var interaction: WindowSnapSelection
    private var tracking: NSTrackingArea?
    var onSelection: (() -> Void)?
    var onAction: ((RegionSelectionAction, NSImage?, NSRect?) -> Void)?

    init(image: NSImage, frame: NSRect, screenOrigin: NSPoint = .zero, windowFrames: [CGRect] = []) {
        self.image = image
        self.screenOrigin = screenOrigin
        interaction = WindowSnapSelection(bounds: CGRect(origin: .zero, size: frame.size),
            windows: windowFrames.map { $0.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y) })
        super.init(frame: frame)
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        toolbar.layer?.cornerRadius = 8
        for action in RegionSelectionAction.allCases {
            let button = NSButton(title: action.title, target: self, action: #selector(chooseAction(_:)))
            button.tag = action.rawValue
            button.bezelStyle = .rounded
            if action == .copy { button.title = "复制 ↩"; button.toolTip = "按回车复制选区" }
            toolbar.addArrangedSubview(button)
        }
        toolbar.isHidden = true
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func selection(from start: CGPoint, to end: CGPoint, bounds: CGRect) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
    }

    func setSelection(_ rect: CGRect) {
        selectionRect = rect.intersection(bounds)
        interaction.rect = selectionRect
        interaction.committed = !selectionRect.isNull && selectionRect.width >= 3 && selectionRect.height >= 3
        toolbar.isHidden = selectionRect.isNull || selectionRect.width < 3 || selectionRect.height < 3
        toolbar.orientation = bounds.width < 380 ? .vertical : .horizontal
        let size = toolbar.fittingSize
        let below = selectionRect.minY - size.height - 8
        let preferredY = below >= 8 ? below : selectionRect.maxY + 8
        toolbar.frame = NSRect(x: max(0, min(selectionRect.maxX - size.width, bounds.maxX - size.width)),
                               y: max(0, min(preferredY, bounds.maxY - size.height)),
                               width: size.width, height: size.height)
        needsDisplay = true
    }

    func selectedImage() -> NSImage? {
        guard interaction.committed, !selectionRect.isNull, selectionRect.width >= 3, selectionRect.height >= 3,
              bounds.width > 0, bounds.height > 0,
              let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let region = CGRect(x: selectionRect.minX / bounds.width, y: selectionRect.minY / bounds.height,
                            width: selectionRect.width / bounds.width, height: selectionRect.height / bounds.height)
        guard let crop = try? TextExtraction.image(from: pixels, region: region) else { return nil }
        return NSImage(cgImage: crop, size: selectionRect.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        let shade = NSBezierPath(rect: bounds)
        if !selectionRect.isEmpty, !selectionRect.isNull { shade.appendRect(selectionRect) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        shade.fill()
        if !selectionRect.isEmpty, !selectionRect.isNull {
            NSColor.systemGreen.setStroke()
            let border = NSBezierPath(rect: selectionRect.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()
            if interaction.committed {
                NSColor.white.setFill()
                for point in [CGPoint(x: selectionRect.minX, y: selectionRect.minY),
                              CGPoint(x: selectionRect.maxX, y: selectionRect.minY),
                              CGPoint(x: selectionRect.minX, y: selectionRect.maxY),
                              CGPoint(x: selectionRect.maxX, y: selectionRect.maxY)] {
                    NSBezierPath(rect: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        onSelection?()
        interaction.begin(at: convert(event.locationInWindow, from: nil))
        selectionRect = interaction.rect
        toolbar.isHidden = true
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        interaction.drag(to: convert(event.locationInWindow, from: nil))
        selectionRect = interaction.rect
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        interaction.end(at: convert(event.locationInWindow, from: nil))
        setSelection(interaction.rect)
    }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if !event.isARepeat { performAction(.copy) }
        } else if event.keyCode == 53 {
            if interaction.reset() { clearSelection() }
            else { onAction?(.cancel, nil, nil) }
        }
        else { super.keyDown(with: event) }
    }
    func clearSelection() {
        interaction.reset()
        selectionRect = .zero
        toolbar.isHidden = true
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    func preview(at point: CGPoint) {
        interaction.hover(at: point)
        selectionRect = interaction.rect
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { preview(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        preview(at: CGPoint(x: bounds.minX - 1, y: bounds.minY - 1))
    }
    @objc private func chooseAction(_ sender: NSButton) {
        guard let action = RegionSelectionAction(rawValue: sender.tag) else { return }
        performAction(action)
    }

    private func performAction(_ action: RegionSelectionAction) {
        if action == .cancel { onAction?(action, nil, nil); return }
        guard let selection = selectedImage() else { NSSound.beep(); return }
        onAction?(action, selection, selectionRect.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y))
    }
}

@MainActor
final class RegionSelectionSession {
    private var windows: [NSWindow] = []

    init(snapshots: [(NSRect, NSImage)], windowFrames: [CGRect] = [], onAction: @escaping (RegionSelectionAction, NSImage?, NSRect?) -> Void) {
        for (frame, image) in snapshots {
            let window = RegionSelectionWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.acceptsMouseMovedEvents = true
            let view = RegionSelectionView(image: image, frame: NSRect(origin: .zero, size: frame.size), screenOrigin: frame.origin, windowFrames: windowFrames)
            view.onSelection = { [weak self, weak view] in
                for other in self?.windows ?? [] {
                    if let candidate = other.contentView as? RegionSelectionView, candidate !== view { candidate.clearSelection() }
                }
            }
            view.onAction = onAction
            window.contentView = view
            window.makeFirstResponder(view)
            windows.append(window)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        for window in windows { window.orderFrontRegardless() }
        for window in windows where window.frame.contains(NSEvent.mouseLocation) {
            (window.contentView as? RegionSelectionView)?.preview(at: window.convertPoint(fromScreen: NSEvent.mouseLocation))
        }
        (windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first)?.makeKey()
    }

    func close() {
        for window in windows { window.close() }
        windows.removeAll()
    }
}
