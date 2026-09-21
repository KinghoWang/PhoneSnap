import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let wiredStatus: () -> String
    private let wirelessStatus: () -> String
    private let wirelessEnabled: () -> Bool
    private let onToggleWireless: (Bool) -> Void
    private let onOpenSettings: () -> Void
    private let onRotatePairing: () -> Void
    private let onShowLast: () -> Void
    private let onRevealFolder: () -> Void
    private let onSetupWireless: () -> Void
    private let onSetupNearby: () -> Void
    private let onSetupRelay: () -> Void

    init(wiredStatus: @escaping () -> String,
         wirelessStatus: @escaping () -> String,
         wirelessEnabled: @escaping () -> Bool,
         onToggleWireless: @escaping (Bool) -> Void,
         onOpenSettings: @escaping () -> Void,
         onRotatePairing: @escaping () -> Void,
         onShowLast: @escaping () -> Void,
         onRevealFolder: @escaping () -> Void,
         onSetupWireless: @escaping () -> Void,
         onSetupNearby: @escaping () -> Void = {},
         onSetupRelay: @escaping () -> Void = {}) {
        self.wiredStatus = wiredStatus
        self.wirelessStatus = wirelessStatus
        self.wirelessEnabled = wirelessEnabled
        self.onToggleWireless = onToggleWireless
        self.onOpenSettings = onOpenSettings
        self.onRotatePairing = onRotatePairing
        self.onShowLast = onShowLast
        self.onRevealFolder = onRevealFolder
        self.onSetupWireless = onSetupWireless
        self.onSetupNearby = onSetupNearby
        self.onSetupRelay = onSetupRelay
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setConnected(false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
    }

    /// Swap the menu bar icon to reflect whether a trusted iPhone is attached.
    func setConnected(_ connected: Bool) {
        guard let button = statusItem.button else { return }
        let candidates = connected
            ? ["iphone.gen3.badge.checkmark", "iphone.badge.checkmark", "iphone"]
            : ["iphone.gen3", "iphone"]
        let symbol = candidates.lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "PhoneSnap") }
            .first
        if let symbol {
            symbol.isTemplate = true
            button.image = symbol
            button.title = ""
        } else {
            button.image = nil
            button.title = "📱"
        }
        button.toolTip = connected ? "PhoneSnap — 已连接 iPhone" : "PhoneSnap — 未连接有线 iPhone"
    }

    @objc private func setupNearbyAction() { onSetupNearby() }
    @objc private func setupRelayAction() { onSetupRelay() }

    func refresh() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        for (title, action) in [
            ("Mac 区域截图…", #selector(captureRegion)),
            ("Mac 窗口截图…", #selector(captureWindow)),
            ("Mac 主屏幕截图", #selector(captureScreen)),
            ("打开图片并编辑…", #selector(editFile)),
            ("设置截图快捷键…（\(CaptureHotkey.shared.displayName)）", #selector(configureCaptureKey))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let status = NSMenuItem(title: wiredStatus(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let wireless = NSMenuItem(title: wirelessStatus(), action: nil, keyEquivalent: "")
        wireless.isEnabled = false
        menu.addItem(wireless)
        menu.addItem(.separator())

        let setup = NSMenuItem(title: "设置无线快捷指令…", action: #selector(setupWirelessAction), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        let nearby = NSMenuItem(title: "设置 iPhone 附近传输…", action: #selector(setupNearbyAction), keyEquivalent: "")
        nearby.target = self
        menu.addItem(nearby)
        let relay = NSMenuItem(title: "设置端到端加密中转…", action: #selector(setupRelayAction), keyEquivalent: "")
        relay.target = self
        menu.addItem(relay)

        let rotate = NSMenuItem(
            title: "重置配对…",
            action: #selector(rotatePairingAction),
            keyEquivalent: ""
        )
        rotate.target = self
        rotate.toolTip = "生成新的配对凭据。已安装的快捷指令需要重新配置。"
        menu.addItem(rotate)

        menu.addItem(.separator())

        let show = NSMenuItem(title: "显示最近截图", action: #selector(showLastAction), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let reveal = NSMenuItem(title: "在访达中打开截图文件夹", action: #selector(revealAction), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "退出 PhoneSnap", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc private func captureRegion() { MacCapture.shared.capture(.region) }
    @objc private func captureWindow() { MacCapture.shared.capture(.window) }
    @objc private func captureScreen() { MacCapture.shared.capture(.screen) }
    @objc private func editFile() { ScreenshotEditor.shared.openFile() }
    @objc private func configureCaptureKey() { CaptureHotkey.shared.configure() }

    @objc private func toggleWirelessAction() { onToggleWireless(!wirelessEnabled()) }
    @objc private func settingsAction() { onOpenSettings() }
    @objc private func rotatePairingAction() { onRotatePairing() }
    @objc private func setupWirelessAction() { onSetupWireless() }
    @objc private func showLastAction() { onShowLast() }
    @objc private func revealAction() { onRevealFolder() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}
