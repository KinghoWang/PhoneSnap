import SwiftUI
import Combine
import PhotosUI
import AppIntents
import UniformTypeIdentifiers

@MainActor
final class PhoneSnapRelayModel: ObservableObject {
    static let shared = PhoneSnapRelayModel()
    @Published var paired = false
    @Published var busy = false
    @Published var status = "跨网络可选链路：本机加密，只有配对设备能解密；不降级明文。"
    @Published var pendingPairing: RelayPairing?
    @Published var showConfirmation = false
    private var directProgressID: UUID?

    func refresh() {
        do { paired = try RelayPairingStore.load() != nil }
        catch { status = "无法读取加密配对，请解锁手机后重试。" }
    }

    func importPairing(_ url: URL) {
        guard !busy else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard url.pathExtension.lowercased() == "phonesnaprelay",
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096 else {
                throw RelayError.invalidPairing
            }
            let pairing = try RelayPairing.decode(Data(contentsOf: url))
            guard pairing.receiveToken == nil else { throw RelayError.invalidPairing }
            pendingPairing = pairing
            showConfirmation = true
        } catch { status = "导入失败，请选择 Mac 导出的 .phonesnaprelay 私密文件，不是服务器配置。" }
    }

    func confirm() {
        guard !busy, let pairing = pendingPairing else { return }
        defer { pendingPairing = nil }
        do {
            try RelayPairingStore.save(pairing)
            paired = true
            status = "独立加密配对已保存，不代表服务器或 Mac 已在线。"
        } catch { status = "配对未保存，请检查钥匙串访问。" }
    }

    func send(_ image: Data, trace: RelayDiagnostics) async throws {
        try await performSend(image, trace: trace, automatic: false, origin: .app)
    }

    func sendAutomatically(_ image: Data, trace: RelayDiagnostics, origin: NearbySendOrigin = .app) async throws {
        try await performSend(image, trace: trace, automatic: true, origin: origin)
    }

    private func performSend(_ image: Data, trace: RelayDiagnostics, automatic: Bool, origin: NearbySendOrigin) async throws {
        guard !busy, !PhoneSnapModel.shared.busy else {
            trace.fail(PhoneSnapIntentError.busy)
            throw PhoneSnapIntentError.busy
        }
        busy = true
        defer { busy = false }
        do {
            if automatic {
                _ = try await AutomaticTransfer.send(direct: {
                    try await self.sendDirectIfAvailable(image, trace: trace, origin: origin)
                }, relay: {
                    trace.record(.relaySelected)
                    try await self.sendPrepared(image, trace: trace)
                })
            } else {
                trace.record(.relaySelected)
                try await sendPrepared(image, trace: trace)
            }
            trace.record(.finishSuccess)
        } catch {
            trace.fail(error)
            status = "未确认送达。已开始直传时不会切换公网重发，请先核对 Mac 最近截图。\n" + error.localizedDescription
            throw error
        }
    }

    private func sendDirectIfAvailable(_ image: Data, trace: RelayDiagnostics, origin: NearbySendOrigin) async throws -> Bool {
        trace.record(.routeCheckBegin, bytes: image.count)
        status = "正在检查直传连接（最多 3 秒，尚未发送图片）…"
        guard let pairing = try NearbyPairingStore.load() else {
            trace.record(.directPairingMissing)
            return false
        }
        guard let identifier = UUID(uuidString: trace.transfer) else { throw NearbyError.invalidFrame }
        directProgressID = identifier
        defer { directProgressID = nil }
        let sender = NearbySender(origin: origin, onDiagnostic: { [weak self] phase, _ in
            Task { @MainActor [weak self] in
                guard let self, self.busy, self.directProgressID == identifier else { return }
                if phase != "发现 Mac", phase != "建立连接" {
                    self.status = "直传 · \(phase)；不会切换公网重发。"
                }
            }
        })
        guard let report = try await sender.sendIfAvailable(image, pairing: pairing, transferID: identifier) else {
            trace.record(.directUnavailable)
            return false
        }
        trace.record(.directSaved, bytes: image.count)
        status = String(format: "直传 · Mac 已确认保存 · %.2f 秒", report.totalSeconds) + "\n" + report.path
        return true
    }

    private func sendPrepared(_ image: Data, trace: RelayDiagnostics) async throws {
        guard let pairing = try RelayPairingStore.load() else { throw RelayError.invalidPairing }
        trace.record(.pairingReady)
        status = "公网加密 · 正在准备发送，等待 Mac 保存回执…"
        let began = Date()
        do {
            try Task.checkCancellation()
            let mode = RelayImageMode.load()
            trace.record(mode == .fast ? .modeFast : .modeOriginal)
            trace.record(.preparationBegin, bytes: image.count)
            let prepared = try await Task.detached(priority: .userInitiated) {
                try RelayImagePreparation.prepare(image, mode: mode)
            }.value
            try Task.checkCancellation()
            trace.record(.preparationEnd, bytes: prepared.data.count)
            trace.record(prepared.compressed ? .compressed : .keptOriginal, bytes: prepared.data.count, reason: prepared.reason)
            let transfer = try await RelayHTTP.send(prepared.data, pairing: pairing, trace: trace)
            status = String(format: "端到端加密 · Mac 已确认保存 · %.2f 秒", Date().timeIntervalSince(began)) + "\n发送编号：" + transfer
        } catch {
            status = "未确认送达；Mac 可能已保存但回执未返回。不会改用明文。\n" + error.localizedDescription
            throw error
        }
    }
}

struct PhoneSnapRelaySection: View {
    @StateObject private var model = PhoneSnapRelayModel.shared
    @State private var selection: PhotosPickerItem?
    @AppStorage(RelayImageMode.defaultsKey) private var imageMode = RelayImageMode.original.rawValue

    var body: some View {
        DisclosureGroup("手动公网发送与画质") {
            Text("此入口固定使用公网，适合单独测试。日常使用上方自动发送。")
                .font(.footnote).foregroundStyle(.secondary)
            Text(model.paired ? "已保存独立加密配对（不代表连接成功）" : "尚未配对，请展开下方“公网配对管理”")
            Picker("公网发送画质", selection: $imageMode) {
                Text("原图").tag(RelayImageMode.original.rawValue)
                Text("快速").tag(RelayImageMode.fast.rawValue)
            }.pickerStyle(.segmented).disabled(model.busy)
            Text("快速：本机有损压缩后加密，不缩小像素，小字可能受影响。选择会记住，并用于加密快捷指令。")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.status).font(.footnote).textSelection(.enabled)
            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                Label("公网加密 · 发送图片", systemImage: "lock.shield")
            }.disabled(!model.paired || model.busy)
            if model.busy { ProgressView("等待可验证的 Mac 保存回执") }
        }
        .task { model.refresh() }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            Task {
                defer { selection = nil }
                let trace = RelayDiagnostics(origin: .app)
                trace.record(.inputBegin)
                let image: Data
                do {
                    guard let loaded = try await item.loadTransferable(type: Data.self) else { throw RelayError.invalidEnvelope }
                    image = loaded
                } catch {
                    trace.fail(error)
                    model.status = "图片准备失败，可复制加密中转诊断。"
                    return
                }
                trace.record(.inputReady, bytes: image.count)
                do {
                    try await model.send(image, trace: trace)
                } catch {
                    model.status = "未确认送达，不会改用明文；若发送已开始，Mac 可能已保存但回执未返回。\n" + error.localizedDescription
                }
            }
        }
    }
}

struct PhoneSnapRelayTools: View {
    @StateObject private var model = PhoneSnapRelayModel.shared
    @State private var showImporter = false
    @State private var copyingDiagnostic = false
    @State private var copyFeedback = ""

    var body: some View {
        Group {
            DisclosureGroup("公网配对管理") {
                Button("导入加密中转配对文件…") { showImporter = true }.disabled(model.busy)
                Text("使用自己 Mac 导出的独立加密配对文件；不要公开或从服务器下载配对文件。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            DisclosureGroup("自动发送与公网诊断") {
                Button {
                    guard !copyingDiagnostic else { return }
                    copyingDiagnostic = true
                    copyFeedback = "正在读取诊断…"
                    Task {
                        defer { copyingDiagnostic = false }
                        let text = await Task.detached(priority: .userInitiated) { RelayDiagnostics.latest() }.value
                        guard let text, !text.isEmpty else {
                            copyFeedback = "未找到可读取的诊断，请先发送一张测试图片。"
                            return
                        }
                        let pasteboard = UIPasteboard.general
                        let previousCount = pasteboard.changeCount
                        pasteboard.string = text
                        copyFeedback = pasteboard.changeCount != previousCount
                            ? "已复制诊断，可直接粘贴。" : "未能写入剪贴板，请重试。"
                    }
                } label: {
                    HStack {
                        Label(copyingDiagnostic ? "正在读取诊断…" : "复制最近一次发送诊断", systemImage: "doc.on.doc")
                        Spacer(minLength: 0)
                        if copyingDiagnostic { ProgressView() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(copyingDiagnostic)
                if !copyFeedback.isEmpty {
                    Text(copyFeedback).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { model.importPairing(url) }
        }
        .alert("信任此加密配对？", isPresented: $model.showConfirmation) {
            Button("确认来自自己的 Mac 并保存") { model.confirm() }
            Button("取消", role: .cancel) { model.pendingPairing = nil }
        } message: {
            Text("只接收自己 Mac 当面导出的文件，不能从中转服务器下载配对。文件持有者能够解密图片或伪造回执。导入会替换本机旧的加密中转配对。服务地址：\(model.pendingPairing?.baseURL ?? "")")
        }
    }
}

struct SendEncryptedImageIntent: AppIntent {
    static var title: LocalizedStringResource = "发送图片到 Mac（自动选路）"
    static var description = IntentDescription("发送前优先检查已配对的直传连接；3 秒内未建立连接才使用端到端加密公网兜底。开始直传后不会改走公网重发。USB 相册收图是独立功能，插线不代表此动作走 USB。")
    static var supportedModes: IntentModes = .background

    @Parameter(title: "图片", supportedContentTypes: [.image])
    var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("将\(\.$image)端到端加密发送到 Mac")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let trace = RelayDiagnostics(origin: .shortcut)
        trace.record(.inputBegin)
        let data = image.data
        trace.record(.inputReady, bytes: data.count)
        try await PhoneSnapRelayModel.shared.sendAutomatically(data, trace: trace, origin: .shortcut)
        return .result()
    }
}
