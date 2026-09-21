import AppKit
import NearbyTransport

@MainActor
final class RelaySetupController: NSObject {
    private let receive: (Data, ScreenshotReceiveContext) -> Bool
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var receiver: Task<Void, Never>?
    private var status = "未开启。仅发送密文；服务器无法解密图片。"
    private let enabledKey = "PhoneSnapE2EERelayEnabled"
    private let receipts = RelayReceiptStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PhoneSnap/RelayReceipts"))

    init(receive: @escaping (Data, ScreenshotReceiveContext) -> Bool) { self.receive = receive }

    func restore() {
        if UserDefaults.standard.bool(forKey: enabledKey) { start() }
    }

    func stop() {
        receiver?.cancel()
        receiver = nil
    }

    private func update(_ text: String) {
        status = text
        statusLabel?.stringValue = text
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 510),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "PhoneSnap · 端到端加密中转"
            window.isReleasedWhenClosed = false
            let title = NSTextField(wrappingLabelWithString: "可选自建中转 · 没有默认公共服务器\n手机自动发送优先直传；仅无法建立直传连接时使用已配置的公网兜底。图片始终端到端加密。")
            let statusLabel = NSTextField(wrappingLabelWithString: status)
            self.statusLabel = statusLabel
            let notice = NSTextField(wrappingLabelWithString: "首次配置：创建配对 → 导出服务器配置和手机配对文件 → 部署服务 → 开启接收。\n手机配对文件含解密密钥，只通过可信渠道交给自己的手机，绝不能上传服务器。服务器配置也含访问凭据，请勿公开。")
            notice.font = .systemFont(ofSize: 12)
            let controls = NSStackView()
            controls.orientation = .vertical
            controls.alignment = .leading
            controls.spacing = 12
            controls.addArrangedSubview(title)
            controls.addArrangedSubview(statusLabel)
            for (label, action) in [("创建独立加密配对", #selector(createPairing)),
                                    ("导出手机私密配对文件…", #selector(exportPhone)),
                                    ("导出服务器配置（不含解密密钥）…", #selector(exportServer)),
                                    ("开启加密接收", #selector(start)), ("关闭加密接收", #selector(disable)),
                                    ("复制最近一次加密中转诊断", #selector(copyDiagnostics)),
                                    ("打开加密中转日志文件夹", #selector(openDiagnostics))] {
                controls.addArrangedSubview(NSButton(title: label, target: self, action: action))
            }
            controls.addArrangedSubview(notice)
            controls.translatesAutoresizingMaskIntoConstraints = false
            window.contentView!.addSubview(controls)
            NSLayoutConstraint.activate([
                controls.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
                controls.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
                controls.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20)
            ])
            window.setContentSize(NSSize(width: 580, height: 510))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func createPairing() {
        do {
            guard try RelayPairingStore.load() == nil else {
                update("已有独立配对，未覆盖。可以重新导出，不需要重新生成密钥。")
                return
            }
            let alert = NSAlert()
            alert.messageText = "配置你自己的中转服务器"
            alert.informativeText = "请输入 HTTPS 域名，不含账号、路径或查询参数。不会使用开发者的私人服务器；创建配对不会发送网络请求。"
            let endpoint = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
            endpoint.placeholderString = "https://snap.example.com"
            alert.accessoryView = endpoint
            alert.addButton(withTitle: "创建配对")
            alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = endpoint
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let pairing = try RelayPairing.generate(baseURL: endpoint.stringValue)
            try RelayPairingStore.save(pairing)
            update("配对已写入本机钥匙串。尚未连接，也未向服务器发送任何内容。")
        } catch RelayError.invalidPairing {
            update("服务地址无效。请输入 HTTPS 域名，例如 https://snap.example.com，不含路径、账号或查询参数。未创建配对。")
        } catch { update("无法创建配对，请检查本机钥匙串访问。") }
    }

    @objc private func exportPhone() { export(phone: true) }
    @objc private func exportServer() { export(phone: false) }

    private func export(phone: Bool) {
        do {
            guard let pairing = try RelayPairingStore.load() else { update("请先创建独立加密配对。"); return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = phone ? "PhoneSnap-private.phonesnaprelay" : "phonesnap-relay-channels.json"
            panel.message = phone ? "内含解密密钥：仅交给自己的 iPhone，不要上传服务器或公开分享。" : "仅此文件交给服务器。内含访问凭据，但不含图片解密密钥。"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let data = try phone ? pairing.phoneConfiguration() : pairing.serverConfiguration()
            let staging = url.deletingLastPathComponent().appendingPathComponent(".phonesnap-relay-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw RelayError.storage
            }
            defer { try? FileManager.default.removeItem(at: staging) }
            guard rename(staging.path, url.path) == 0 else { throw RelayError.storage }
            update(phone ? "已导出私密手机配对。请当面核对来源，不要发送给服务器。" : "已导出服务器配置。仍需部署中转服务，并在 iPhone 导入另一份手机配对文件。")
        } catch { update("导出未完成，未修改现有配对。") }
    }

    @objc private func disable() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        stop()
        update("加密接收已关闭；未删除配对，不影响附近接收。")
    }

    @objc private func copyDiagnostics() {
        guard let text = RelayDiagnostics.latest() else {
            update("尚无加密中转诊断，请先发送一张测试图片。")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openDiagnostics() {
        guard FileManager.default.fileExists(atPath: RelayDiagnostics.directory.path) else {
            update("尚无日志目录，请先发送一张测试图片。")
            return
        }
        NSWorkspace.shared.open(RelayDiagnostics.directory)
    }

    @objc private func start() {
        guard receiver == nil else { return }
        do {
            guard let pairing = try RelayPairingStore.load(), pairing.receiveToken != nil else {
                update("请先创建配对、部署服务，并给手机导入配对文件。")
                return
            }
            UserDefaults.standard.set(true, forKey: enabledKey)
            update("正在连接加密中转服务，尚未确认收件…")
            receiver = Task { [weak self] in
                while !Task.isCancelled {
                    let trace = RelayDiagnostics(origin: .mac, active: false)
                    do {
                        guard let envelope = try await RelayHTTP.next(pairing: pairing, trace: trace) else {
                            self?.update("中转连接可用，等待密文；不代表已收到图片。")
                            continue
                        }
                        try Task.checkCancellation()
                        guard let self else { return }
                        let receipt = try RelayDelivery.process(envelope, pairing: pairing, receipts: self.receipts, trace: trace) { data in
                            self.receive(data, ScreenshotReceiveContext(source: .relay, started: trace.receiveStartedUptime,
                                                                       transferBytes: trace.receivedTransferBytes))
                        }
                        try await RelayHTTP.acknowledge(envelope, receipt: receipt, pairing: pairing, trace: trace)
                        trace.record(.finishSuccess)
                        self.update("已解密并保存图片，加密回执已提交中转服务。")
                    } catch {
                        trace.fail(error)
                        if Task.isCancelled { return }
                        self?.update("加密中转暂不可用或密文验证失败；未确认本次送达，3 秒后重连。")
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                }
            }
        } catch { update("无法读取钥匙串中的加密配对，未启动接收。") }
    }
}
