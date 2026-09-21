import AppKit

private final class CapturePermissionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class CapturePermissionGuide: NSWindowController {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    let applicationURL = Bundle.main.bundleURL
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let checkAccess: () -> Bool

    init(checkAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.checkAccess = checkAccess
        let window = CapturePermissionPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 300),
                                            styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: false)
        window.title = "PhoneSnap · 截图权限"
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        super.init(window: window)

        let card = NSBox(frame: NSRect(origin: .zero, size: window.frame.size))
        card.boxType = .custom
        card.titlePosition = .noTitle
        card.cornerRadius = 18
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .windowBackgroundColor
        card.contentViewMargins = .zero
        window.contentView = card

        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)!)
        arrow.contentTintColor = .controlAccentColor
        arrow.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "将 PhoneSnap 拖入权限列表")
        title.font = .boldSystemFont(ofSize: 18)
        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill",
                                                  accessibilityDescription: "关闭授权引导")!,
                                   target: self, action: #selector(closeGuide))
        closeButton.title = ""
        closeButton.setAccessibilityLabel("关闭授权引导")
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.toolTip = "关闭授权引导（Esc）"
        let header = NSStackView(views: [arrow, title, NSView(), closeButton])
        header.spacing = 10
        header.alignment = .centerY

        let instructions = NSTextField(wrappingLabelWithString:
            "在「屏幕与系统音频录制」中找到并开启 PhoneSnap；没有时，拖入下方应用。\n拖入无效？点「在 Finder 中显示本应用」，再用系统设置的「＋」添加。")
        instructions.font = .systemFont(ofSize: 13)
        let dragView = CapturePermissionDragView(applicationURL: applicationURL)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        let identity = NSTextField(labelWithString:
            "当前版本 \(version)（\(build)） · \(applicationURL.path)")
        identity.font = .systemFont(ofSize: 11)
        identity.textColor = .secondaryLabelColor
        identity.isSelectable = true
        identity.lineBreakMode = .byTruncatingMiddle
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        identity.toolTip = applicationURL.path
        statusLabel.font = .systemFont(ofSize: 12)
        let actions = NSStackView()
        actions.spacing = 8
        for (name, action) in [("打开权限设置", #selector(openPermissionSettings)),
                               ("在 Finder 中显示本应用", #selector(revealApplication)),
                               ("重新检查权限", #selector(recheckPermission))] {
            let button = NSButton(title: name, target: self, action: action)
            button.bezelStyle = .rounded
            actions.addArrangedSubview(button)
        }
        actions.arrangedSubviews.first?.toolTip = "打开系统设置中的屏幕与系统音频录制"
        actions.arrangedSubviews[1].toolTip = "若拖入无效，使用系统设置的「＋」添加这里选中的应用"
        let stack = NSStackView(views: [header, instructions, dragView, statusLabel, actions, identity])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        guard let content = card.contentView else { return }
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            arrow.widthAnchor.constraint(equalToConstant: 22),
            arrow.heightAnchor.constraint(equalToConstant: 24),
            dragView.heightAnchor.constraint(equalToConstant: 62)
        ])
        for view in [header, instructions, dragView, statusLabel, identity] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NotificationCenter.default.addObserver(self, selector: #selector(recheckIfVisible),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recheckIfVisible),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        if let window, !window.isVisible,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.minY + 24))
        }
        recheckPermission()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func recheckPermission() {
        statusLabel.stringValue = checkAccess()
            ? "已检测到权限。请关闭卡片并手动截图，确认权限已生效；不会自动截图或上传。"
            : "尚未检测到权限。添加后仍需开启开关；已开启则完整退出并重新打开 PhoneSnap，再手动截图。"
    }

    @objc private func recheckIfVisible() {
        guard window?.isVisible == true else { return }
        recheckPermission()
    }

    @objc private func closeGuide() {
        close()
    }

    @objc private func openPermissionSettings() {
        if !NSWorkspace.shared.open(Self.settingsURL) {
            statusLabel.stringValue = "无法直接打开设置。请手动进入系统设置 → 隐私与安全性 → 屏幕与系统音频录制。"
        }
    }

    @objc private func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
    }
}
