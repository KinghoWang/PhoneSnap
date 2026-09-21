import Foundation
import OSLog

public nonisolated enum NearbySendOrigin: String, Sendable {
    case app, shortcut, unspecified
}

nonisolated struct NearbyDiagnostics {
    let identifier: String
    private let timestamp = ISO8601DateFormatter().string(from: Date())
    private let started = ContinuousClock.now
    private(set) var entries: [String] = []
    private var dropped = 0
    private static let logger = Logger(subsystem: "dev.phonesnap.nearby", category: "transfer")

    init(identifier: UUID = UUID()) { self.identifier = identifier.uuidString }

    mutating func append(_ message: String) {
        let duration = started.duration(to: .now)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let entry = String(format: "+%.3fs ", seconds) + message
        entries.append(entry)
        if entries.count > 80 { entries.removeFirst(); dropped += 1 }
        let transferIdentifier = identifier
        Self.logger.notice("transfer=\(transferIdentifier, privacy: .public) \(entry, privacy: .public)")
    }

    var text: String {
        "PhoneSnap 诊断 v3\n发送编号：" + identifier + "\n开始时间（UTC）：" + timestamp
            + "\n说明：候选接口不是实际通路；enqueue 不是 Mac 收件确认。"
            + "\n连接准备包含服务解析/TCP/TLS，当前日志不单独区分这三步。"
            + "\n协议 v2 的发送编号与 Mac 回执一致；v1 兼容模式仍只有单字节回执。"
            + "\nApp 内发送会对照旧版 name_only 发现；它只观察，不参与选路或发图。"
            + "\n发现汇总：updates 为回调次数，total 为最近结果数，matched 为匹配已配对 Mac 的结果数。"
            + (dropped == 0 ? "" : "\n已省略较早事件：\(dropped)")
            + "\n" + entries.joined(separator: "\n")
    }
}

public nonisolated enum NearbyDiagnosticFile {
    public static func save(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        guard data.count <= 131072 else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var destination = url
        try destination.setResourceValues(values)
    }

    public static func load(from url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= 131072 else { throw CocoaError(.fileReadTooLarge) }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
