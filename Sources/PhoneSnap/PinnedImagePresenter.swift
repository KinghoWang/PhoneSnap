import AppKit

@MainActor
final class PinnedImagePresenter {
    static let shared = PinnedImagePresenter()
    private(set) var controllers: [PinnedImageWindowController] = []

    @discardableResult
    func pin(fileURL: URL) -> PinnedImageWindowController? {
        guard let image = NSImage(contentsOf: fileURL) else { NSSound.beep(); return nil }
        return pin(image: image)
    }

    @discardableResult
    func pin(image: NSImage, at origin: NSPoint? = nil) -> PinnedImageWindowController? {
        guard let controller = PinnedImageWindowController(image: image, at: origin) else { NSSound.beep(); return nil }
        controller.onClosed = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        if let window = controller.window {
            if origin == nil, let previous = controllers.last?.window, let screen = window.screen {
                let offset = previous.frame.offsetBy(dx: 24, dy: -24)
                let candidate = NSRect(origin: offset.origin, size: window.frame.size)
                if screen.visibleFrame.contains(candidate) { window.setFrameOrigin(candidate.origin) }
            }
            controllers.append(controller)
            window.orderFrontRegardless()
        }
        return controller
    }
}

@MainActor
final class PinnedImageWindowController: NSWindowController, NSWindowDelegate {
    let image: NSImage
    var onClosed: (() -> Void)?
    let actions = NSStackView()
    private var outsideClicks: Any?
    private var localClicks: Any?

    init?(image: NSImage, at origin: NSPoint? = nil) {
        guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0,
              pixels.width > 0, pixels.height > 0, pixels.width <= 50_000_000 / pixels.height else { return nil }
        self.image = NSImage(cgImage: pixels, size: image.size)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = image.size
        let panel = NSPanel(contentRect: NSRect(origin: available.origin, size: size),
                            styleMask: [.borderless, .resizable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "PhoneSnap · 钉图"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: min(200, size.width), height: min(120, size.height))
        panel.delegate = self
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]
        let picture = PinnedImageView()
        picture.image = self.image
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.onClick = { [weak self] count in self?.handleImageClick(count: count) }
        let edit = NSButton(title: "编辑", target: self, action: #selector(editImage))
        let copy = NSButton(title: "复制", target: self, action: #selector(copyImage))
        let dismiss = NSButton(title: "关闭", target: self, action: #selector(dismissImage))
        for button in [edit, copy, dismiss] { button.bezelStyle = .rounded }
        dismiss.toolTip = "仅关闭钉图，不删除原图"
        for button in [edit, copy, dismiss] { actions.addArrangedSubview(button) }
        actions.spacing = 6
        actions.wantsLayer = true
        actions.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        actions.layer?.cornerRadius = 8
        actions.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        actions.isHidden = true
        actions.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(picture)
        root.addSubview(actions)
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            picture.topAnchor.constraint(equalTo: root.topAnchor),
            picture.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            actions.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6)
        ])
        panel.contentView = root
        panel.setFrameOrigin(origin ?? NSPoint(x: max(available.minX, available.midX - panel.frame.width / 2),
                                     y: min(available.maxY - panel.frame.height, available.midY - panel.frame.height / 2)))
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func handleImageClick(count: Int) {
        if count >= 2 { close(); return }
        actions.isHidden.toggle()
        if !actions.isHidden, outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideControls() }
            }
            localClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    if event.window !== self?.window { self?.hideControls() }
                }
                return event
            }
        } else if actions.isHidden { hideControls() }
    }

    func hideControls() {
        actions.isHidden = true
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let localClicks { NSEvent.removeMonitor(localClicks) }
        outsideClicks = nil
        localClicks = nil
    }

    @objc private func editImage() { ScreenshotEditor.shared.open(image: image) }

    @objc private func copyImage() {
        guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    @objc private func dismissImage() { close() }

    func windowWillClose(_ notification: Notification) { hideControls(); onClosed?() }
}

private final class PinnedImageView: NSImageView {
    var onClick: ((Int) -> Void)?
    private var pressPoint: NSPoint?
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        pressPoint = event.locationInWindow
        if event.clickCount >= 2 { pressPoint = nil; onClick?(event.clickCount) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressPoint else { return }
        let distance = hypot(event.locationInWindow.x - pressPoint.x, event.locationInWindow.y - pressPoint.y)
        if distance > 3 {
            self.pressPoint = nil
            window?.performDrag(with: event)
        }
    }
    override func mouseUp(with event: NSEvent) {
        if pressPoint != nil { onClick?(1) }
        pressPoint = nil
    }
}
