import AppKit
import NearbyTransport

@MainActor
final class NearbySetupController {
    private var receivers: [String: NearbyReceiver] = [:]
    private var states: [String: String] = [:]
    private var devices: [NearbyTrustedDevice] = []
    private var status = "附近接收：未开启"
    private let receive: (Data, ScreenshotReceiveContext) -> Bool

    init(receive: @escaping (Data, ScreenshotReceiveContext) -> Bool) {
        self.receive = receive
        do {
            devices = try NearbyTrustedDeviceStore.load()
            if UserDefaults.standard.bool(forKey: "PhoneSnapNearbyEnabled") { startAuthorized() }
        } catch { status = "无法读取授权，未开启附近接收" }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        do { devices = try NearbyTrustedDeviceStore.load() }
        catch { showError("无法读取已有授权；为避免覆盖，未进行更改。"); return }
        let alert = NSAlert()
        alert.messageText = "iPhone 附近传输 · 设备授权"
        let details = devices.map { "\($0.name)：\(states[$0.id] ?? "未开启接收")" }.joined(separator: "\n")
        alert.informativeText = "\(status)\n\(details)\n\n已授权不代表在线或已连接。设备名只是你设置的备注，不是手机硬件身份。每台手机请使用独立配对文件；共享同一文件的设备无法分别撤销。\n\n只在本机保存授权与回执记录，不改变热点、VPN 或 HTTP 接收。"
        let chooser = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28), pullsDown: false)
        chooser.addItems(withTitles: devices.isEmpty ? ["尚未添加设备"] : devices.map { $0.name + ($0.legacyShared ? "（共享，无法逐台撤销）" : "") })
        alert.accessoryView = chooser
        alert.addButton(withTitle: "添加设备并导出配对…")
        let manage = alert.addButton(withTitle: "管理所选授权…")
        manage.isEnabled = !devices.isEmpty
        alert.addButton(withTitle: receivers.isEmpty ? "开启附近接收" : "暂停附近接收")
        alert.addButton(withTitle: "关闭窗口")
        switch alert.runModal() {
        case .alertFirstButtonReturn: addDevice()
        case .alertSecondButtonReturn:
            if devices.indices.contains(chooser.indexOfSelectedItem) { manageDevice(devices[chooser.indexOfSelectedItem]) }
        case NSApplication.ModalResponse(rawValue: 1002):
            if receivers.isEmpty {
                guard !devices.isEmpty else { showError("请先添加设备并导出配对文件。"); return }
                UserDefaults.standard.set(true, forKey: "PhoneSnapNearbyEnabled")
                startAuthorized()
            } else {
                stop()
                UserDefaults.standard.set(false, forKey: "PhoneSnapNearbyEnabled")
            }
        default: break
        }
    }

    func stop() {
        let active = Array(receivers.values)
        receivers.removeAll()
        states.removeAll()
        for receiver in active { receiver.stop() }
        status = "附近接收：已暂停（授权仍保留）"
    }

    private func startAuthorized() {
        guard !devices.isEmpty else { status = "附近接收：未开启（尚无授权）"; return }
        for device in devices where receivers[device.id] == nil {
            let identifier = device.id
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let journal = base.appendingPathComponent("PhoneSnap/NearbyReceipts/\(identifier).json")
            states[identifier] = "正在启动"
            let receive = self.receive
            let receiver = NearbyReceiver(pairing: device.pairing, receive: { data in
                receive(data, ScreenshotReceiveContext(source: .nearby))
            }, state: { [weak self] value in
                DispatchQueue.main.async {
                    guard let self, self.receivers[identifier] != nil else { return }
                    self.states[identifier] = value
                }
            }, receipts: NearbyReceiptStore(url: journal), receiveWithContext: { data, started, path in
                receive(data, ScreenshotReceiveContext(source: .nearby, started: started, path: path))
            })
            receivers[identifier] = receiver
            receiver.start()
        }
        status = "附近接收已启用 · \(devices.count) 项授权（不代表已连接）"
    }

    private func addDevice() {
        guard devices.count < 8 else { showError("最多保留 8 项授权。请先撤销不再使用的设备。"); return }
        let alert = NSAlert()
        alert.messageText = "为这台 iPhone 创建独立授权"
        alert.informativeText = "旧设备不会失效。请给新授权起一个备注名，并只把新文件导入这一台手机；以后可单独撤销它。"
        let name = NSTextField(string: "我的 iPhone")
        name.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = name
        alert.addButton(withTitle: "选择导出位置…")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let device = try NearbyTrustedDevice.create(name: name.stringValue)
            guard let url = try export(device) else { return }
            let updated = devices + [device]
            try NearbyTrustedDeviceStore.save(updated)
            devices = updated
            UserDefaults.standard.set(true, forKey: "PhoneSnapNearbyEnabled")
            startAuthorized()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { showError("未完成新设备授权。请检查备注名（1–50 字）、钥匙串和导出目录；不要导入未完成授权的文件。") }
    }

    private func manageDevice(_ device: NearbyTrustedDevice) {
        let alert = NSAlert()
        alert.messageText = "管理授权：\(device.name)"
        alert.informativeText = device.legacyShared
            ? "这是旧版共享钥匙，无法知道有几台手机持有。撤销会让所有持有这份旧文件的设备失效；如要逐台管理，请先为各手机添加独立授权。"
            : "重新导出不会更换钥匙。撤销后，这份配对文件也会失效，不影响其他独立授权。若文件曾被共享，所有持有这份文件的设备都会失效。"
        alert.addButton(withTitle: "重新导出配对…")
        alert.addButton(withTitle: "撤销这项授权…")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do { if let url = try export(device) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            catch { showError("导出失败；现有授权未改变。") }
        case .alertSecondButtonReturn: revoke(device)
        default: break
        }
    }

    private func revoke(_ device: NearbyTrustedDevice) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确认撤销“\(device.name)”？"
        alert.informativeText = "会断开这项授权的正在进行的附近传输；已经开始保存的图片可能仍会保存完成。对应的旧配对文件将无法再次连接。不删除已收截图，也不影响其他独立授权。恢复时需添加新授权并重新导入手机。"
        alert.addButton(withTitle: "撤销授权并断开")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let updated = devices.filter { $0.id != device.id }
            try NearbyTrustedDeviceStore.save(updated)
            devices = updated
            receivers.removeValue(forKey: device.id)?.stop()
            states.removeValue(forKey: device.id)
            status = "授权已撤销 · 剩余 \(devices.count) 项"
            if devices.isEmpty { UserDefaults.standard.set(false, forKey: "PhoneSnapNearbyEnabled") }
            if device.legacyShared {
                do { try NearbyPairingStore.remove() }
                catch { showError("本版已撤销该共享授权，但旧版钥匙串记录未能清除。请勿回退启动旧版 PhoneSnap；需解锁钥匙串后清理遗留授权。"); return }
            }
        } catch { showError("撤销未完成，原授权仍保留；请解锁钥匙串后重试。") }
    }

    private func export(_ device: NearbyTrustedDevice) throws -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PhoneSnap 私密配对.phonesnappair"
        panel.allowedFileTypes = ["phonesnappair"]
        panel.message = "当前授权：\(device.name)。配对文件相当于授权钥匙，请勿公开、上传 GitHub 或给其他设备复用。"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try NearbyPairingFile.write(device.pairing, to: url)
        return url
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "PhoneSnap 附近传输"
        alert.informativeText = text
        alert.runModal()
    }
}
