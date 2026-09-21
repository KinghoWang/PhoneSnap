import AppKit

final class CapturePermissionDragView: NSView, NSDraggingSource, NSPasteboardWriting {
    nonisolated private let applicationURL: URL
    private let applicationIcon: NSImage
    private var mouseDownLocation: NSPoint?

    init(applicationURL: URL) {
        self.applicationURL = applicationURL
        applicationIcon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        super.init(frame: .zero)

        let icon = NSImageView(image: applicationIcon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: "PhoneSnap")
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        let hint = NSTextField(labelWithString: "拖动此应用 → 系统权限列表")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [name, hint])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(labels)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14)
        ])
        toolTip = "拖动当前正在运行的应用：\(applicationURL.path)"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("PhoneSnap，可拖动到系统权限列表")
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.setFill()
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard hypot(location.x - start.x, location.y - start.y) >= 4 else { return }
        mouseDownLocation = nil
        let item = NSDraggingItem(pasteboardWriter: self)
        item.setDraggingFrame(NSRect(x: location.x - 20, y: location.y - 20, width: 40, height: 40),
                              contents: applicationIcon)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    nonisolated func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL]
    }

    nonisolated func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .fileURL ? applicationURL.absoluteString : nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
