import SwiftUI
import Combine
import PhotosUI
import UniformTypeIdentifiers
import UIKit

@MainActor
final class PhoneSnapModel: ObservableObject {
    static let shared = PhoneSnapModel()
    @Published var paired = false
    @Published var busy = false
    @Published var status = "导入 Mac 导出的私密配对文件后即可发送。"
    @Published var transferDetails = ""
    @Published var diagnosticLog = ""
    @Published var diagnosticSaveError = ""
    @Published var diagnosticCopied = false
    @Published var pendingPairing: NearbyPairing?
    @Published var showPairingConfirmation = false
    private var sender: NearbySender?
    private var activeDiagnosticID: UUID?
    private let diagnosticURL = URL.applicationSupportDirectory.appendingPathComponent("PhoneSnap/latest-transfer.log")

    init() {
        diagnosticLog = (try? NearbyDiagnosticFile.load(from: diagnosticURL)) ?? ""
    }

    private func saveDiagnostic(_ text: String) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        diagnosticLog = "PhoneSnap \(version) (\(build))\n" + text
        do {
            try NearbyDiagnosticFile.save(diagnosticLog, to: diagnosticURL)
            diagnosticSaveError = ""
        } catch {
            diagnosticSaveError = "日志暂未保存到本机，可先复制当前日志。"
        }
    }

    func copyDiagnostic() {
        UIPasteboard.general.string = diagnosticLog
        diagnosticCopied = true
    }

    func refreshPairing() {
        do { paired = try NearbyPairingStore.load() != nil }
        catch { status = error.localizedDescription }
    }

    func importPairing(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size <= 4096 else { throw NearbyError.invalidPairing }
            pendingPairing = try NearbyPairing.decode(Data(contentsOf: url))
            showPairingConfirmation = true
        } catch { status = "导入失败：请使用 Mac 导出的 .phonesnappair 文件。" }
    }

    func confirmPairing() {
        guard let pairing = pendingPairing else { return }
        defer { pendingPairing = nil }
        guard !busy else { status = "请先完成或取消当前发送，再重新导入配对。"; return }
        do {
            try NearbyPairingStore.save(pairing)
            paired = true
            status = "配对已保存（不代表已连接）。请先选择测试图片发送。"
        } catch { status = error.localizedDescription }
    }

    func forgetPairing() {
        guard !busy else { return }
        do {
            try NearbyPairingStore.remove()
            paired = false
            pendingPairing = nil
            transferDetails = ""
            status = "已清除本机 Mac 配对。Mac 端的授权需在 Mac 上单独撤销。"
        } catch { status = "未能清除配对，请解锁设备后重试。" }
    }

    func send(_ data: Data, origin: NearbySendOrigin = .app) async throws {
        guard !busy, !PhoneSnapRelayModel.shared.busy else { throw PhoneSnapIntentError.busy }
        guard let pairing = try NearbyPairingStore.load() else { throw PhoneSnapIntentError.notPaired }
        _ = try NearbyFrame.header(byteCount: data.count)
        busy = true
        status = "正在发现 Mac 并发送原图…"
        transferDetails = ""
        diagnosticCopied = false
        let diagnosticID = UUID()
        activeDiagnosticID = diagnosticID
        let sender = NearbySender(origin: origin) { [weak self] phase, text in
            Task { @MainActor [weak self] in
                guard let self, self.busy, self.activeDiagnosticID == diagnosticID else { return }
                self.status = "正在\(phase)…"
                self.saveDiagnostic(text)
            }
        }
        self.sender = sender
        defer { busy = false; self.sender = nil; activeDiagnosticID = nil }
        do {
            let report = try await sender.send(data, pairing: pairing)
            saveDiagnostic(report.diagnostics)
            status = String(format: "Mac 已确认保存 · %.1f 秒 · %.2f MB", report.totalSeconds, Double(data.count) / 1_000_000)
            transferDetails = report.route + "\n接口：" + report.path + String(format: "\n发现与选路 %.2f 秒 · 连接 %.2f 秒\n发送及保存确认 %.2f 秒", report.discoverySeconds, report.connectionSeconds, report.deliverySeconds)
        } catch {
            status = error.localizedDescription
            transferDetails = (error as? NearbyTransferFailure)?.details ?? ""
            if let failure = error as? NearbyTransferFailure { saveDiagnostic(failure.diagnostics) }
            throw error
        }
    }

    func cancel() { sender?.cancel() }
}

struct PhoneSnapRootView: View {
    @StateObject private var model = PhoneSnapModel.shared

    var body: some View {
        PhoneSnapView()
        .onOpenURL { url in
            switch url.pathExtension.lowercased() {
            case "phonesnappair": model.importPairing(url)
            case "phonesnaprelay": PhoneSnapRelayModel.shared.importPairing(url)
            default: break
            }
        }
        .alert("信任此 Mac？", isPresented: $model.showPairingConfirmation) {
            Button("信任并保存") { model.confirmPairing() }
            Button("取消", role: .cancel) { model.pendingPairing = nil }
        } message: {
            Text("仅导入你自己的 Mac 当面导出的文件。导入后，发送的图片将交给持有同一配对钥匙的设备；已有配对会被替换。")
        }
    }
}

struct PhoneSnapView: View {
    @StateObject private var model = PhoneSnapModel.shared
    @StateObject private var automaticModel = PhoneSnapRelayModel.shared
    @State private var showImporter = false
    @State private var showForgetConfirmation = false
    @State private var selection: PhotosPickerItem?
    @State private var manualSelection: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section("自动发送 · 直传优先") {
                    Text("先检查直传连接，3 秒内未建立连接才用公网；开始直传后不跨通路重发。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(automaticModel.status).accessibilityIdentifier("phonesnap.automatic.status")
                    PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                        Label("选择图片 · 自动发送", systemImage: "photo")
                    }
                    .disabled((!model.paired && !automaticModel.paired) || model.busy || automaticModel.busy)
                    if automaticModel.busy { ProgressView("选路或等待 Mac 保存回执") }
                    Text("直传保留原图；公网使用已保存的画质设置。USB 相册收图独立运行，插线不代表本次采用 USB。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("管理与帮助") {
                    DisclosureGroup("手动附近直传") {
                        Text(model.status).accessibilityIdentifier("phonesnap.status")
                        if !model.transferDetails.isEmpty { Text(model.transferDetails).font(.footnote) }
                        PhotosPicker(selection: $manualSelection, matching: .images, preferredItemEncoding: .current) {
                            Label("附近直传 · 发送原图", systemImage: "photo")
                        }.disabled(!model.paired || model.busy || automaticModel.busy)
                        if model.busy { Button("取消发送", role: .cancel) { model.cancel() } }
                    }
                    PhoneSnapRelaySection()
                    DisclosureGroup("附近配对管理") {
                        Button("导入 Mac 配对文件") { showImporter = true }
                            .disabled(model.busy)
                        if model.paired {
                            Button("清除本机 Mac 配对…", role: .destructive) { showForgetConfirmation = true }
                                .disabled(model.busy)
                        }
                        Text("在 Mac PhoneSnap 菜单中选择“设置 iPhone 附近传输”，导出 .phonesnappair 文件后导入。请勿公开配对文件。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("附近直传诊断") {
                        if model.diagnosticLog.isEmpty {
                            Text("尚无附近直传诊断，请先发送一张测试图片。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Button(model.diagnosticCopied ? "已复制附近直传诊断" : "复制附近直传诊断") { model.copyDiagnostic() }
                            DisclosureGroup("查看事件时间线") {
                                Text(model.diagnosticLog).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if !model.diagnosticSaveError.isEmpty { Text(model.diagnosticSaveError).foregroundStyle(.orange) }
                            Text("仅本机保留最近一次；历史记录不代表当前连接状态。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    PhoneSnapRelayTools()
                    DisclosureGroup("使用帮助与快捷指令") {
                        Text("附近直传：两端开启 Wi-Fi，Mac 保持唤醒并开启附近接收。可以同 Wi-Fi、连接热点或靠近使用；不会自动切换热点或 VPN。")
                        Text("快捷指令先添加“截屏”，再添加“发送图片到 Mac（自动选路）”，把截屏结果传给“图片”。可绑定操作按钮或轻点背面。“发送图片到附近 Mac”只走直传，不会公网兜底。")
                        Text("日常使用“发送图片到 Mac（自动选路）”。原“端到端加密发送图片到 Mac”动作保留同一内部标识，更新为自动选路；手动公网入口仍可单独测试。Mac 需运行并开启对应接收。")
                        Text("公网原图模式保留输入数据；快速模式遇到小图、真实透明像素、多帧、超出像素限制或压缩后更大时保留原数据。服务器只收密文，但仍能看到大小和传输时间。")
                        Text("后台发送成功不弹确认；失败提示原因，系统权限提示仍可能出现。")
                    }
                    .font(.footnote)
                }
            }
            .navigationTitle("截图传 Mac")
            .confirmationDialog("清除本机保存的 Mac 配对？", isPresented: $showForgetConfirmation, titleVisibility: .visible) {
                Button("清除本机配对", role: .destructive) { model.forgetPairing() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("这只让本机暂时不能发送，不会撤销 Mac 端授权。若要让旧配对文件失效，请在 Mac PhoneSnap 的设备授权中撤销对应项目。恢复时需要重新导入配对文件。")
            }
            .task { model.refreshPairing(); automaticModel.refresh() }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.phoneSnapPairing, .data]) { result in
                switch result {
                case .success(let url): model.importPairing(url)
                case .failure: model.status = "未能读取所选配对文件。"
                }
            }
            .onChange(of: selection) { _, item in
                guard let item else { return }
                Task {
                    defer { selection = nil }
                    let trace = RelayDiagnostics(origin: .app)
                    trace.record(.inputBegin)
                    let image: Data
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw NearbyError.invalidFrame }
                        image = data
                    } catch {
                        trace.fail(error)
                        automaticModel.status = "图片准备失败：" + error.localizedDescription
                        return
                    }
                    trace.record(.inputReady, bytes: image.count)
                    do { try await automaticModel.sendAutomatically(image, trace: trace) }
                    catch { }
                }
            }
            .onChange(of: manualSelection) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw NearbyError.invalidFrame }
                        try await model.send(data)
                    } catch { model.status = error.localizedDescription }
                    manualSelection = nil
                }
            }
        }
    }
}

extension UTType {
    static let phoneSnapPairing = UTType(exportedAs: "dev.phonesnap.pairing", conformingTo: .data)
}
