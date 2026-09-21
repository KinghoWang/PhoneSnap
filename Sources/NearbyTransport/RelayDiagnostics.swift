import Foundation

public nonisolated final class RelayDiagnostics: @unchecked Sendable {
    public enum Origin: String, Sendable { case app, shortcut, mac }
    public enum Operation: String, Sendable { case send, poll, ack }
    public enum Event: String, Sendable {
        case begin, inputBegin, inputReady, pairingReady, encryptBegin, encryptEnd, encodeEnd
        case requestBegin, responseHeaders, responseBody, dns, connection, tls, upload, serverWait, download, reusedConnection
        case envelopeDecoded, decryptBegin, decryptEnd, duplicateReceipt, saveBegin, saveEnd, receiptPersisted
        case receiptVerified, finishSuccess, finishFailure
        case wireBinary, wireJSON
        case modeOriginal, modeFast, preparationBegin, preparationEnd, compressed, keptOriginal
        case routeCheckBegin, directPairingMissing, directUnavailable, directSaved, relaySelected
    }
    private let lock = NSLock()
    private static let fileLock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private let timestamp: String
    private let beijingTimestamp: String
    private let identifier = UUID().uuidString.lowercased()
    private var transferID = UUID().uuidString.lowercased()
    private let origin: Origin
    private let directory: URL
    private var active: Bool
    private var entries: [String] = []
    private var persistenceFailed = false
    private var receiveStart: TimeInterval?
    private var receivedBytes: Int?

    public var receivedTransferBytes: Int? {
        lock.lock(); defer { lock.unlock() }
        return receivedBytes
    }

    public var receiveStartedUptime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return receiveStart
    }

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneSnap/RelayDiagnostics", isDirectory: true)
    }

    public init(origin: Origin, directory: URL = RelayDiagnostics.directory, active: Bool = true, startedAt: Date = Date()) {
        timestamp = ISO8601DateFormatter().string(from: startedAt)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss XXX"
        beijingTimestamp = formatter.string(from: startedAt)
        self.origin = origin
        self.directory = directory
        self.active = active
        record(.begin)
    }

    public var transfer: String {
        lock.lock(); defer { lock.unlock() }
        return transferID
    }

    public var text: String {
        lock.lock(); defer { lock.unlock() }
        return render()
    }

    private func render() -> String {
        "PhoneSnap 加密中转诊断 v1\n发送编号：\(transferID)\norigin=\(origin.rawValue) started_utc=\(timestamp)\n"
        + "北京时间：\(beijingTimestamp)\n"
        + "计时为本机单调时钟；不要跨设备相减。发送编号仅用于关联，不是送达证明。\n"
        + "shortcut 从 AppIntent 开始，不包含系统截屏及动作启动；Mac poll 的首字节前等待包含空闲等图。\n"
        + "网络 metrics 缺失或连接复用时不补零；upload 为本机请求体发送区间，不是 Mac 保存确认。\n"
        + "connection 包含 TLS，不能与 tls 相加；upload 含请求头，serverWait 含服务端等待及回执链路。\n"
        + "persistence_failed=\(persistenceFailed)\n" + entries.joined(separator: "\n")
    }

    public func activate(transfer: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let transfer, UUID(uuidString: transfer)?.uuidString.lowercased() == transfer { transferID = transfer }
        active = true
        persist()
    }

    public func record(_ event: Event, operation: Operation? = nil, bytes: Int? = nil, status: Int? = nil, milliseconds: Double? = nil, reason: RelayImagePreparation.Reason? = nil) {
        lock.lock(); defer { lock.unlock() }
        if event == .responseBody, operation == .poll, let bytes, bytes >= 0 { receivedBytes = bytes }
        if event == .responseHeaders, operation == .poll, status == 200, receiveStart == nil {
            receiveStart = ProcessInfo.processInfo.systemUptime
        }
        var line = String(format: "+%.3fs ", max(0, ProcessInfo.processInfo.systemUptime - started)) + event.rawValue
        if let operation { line += " operation=\(operation.rawValue)" }
        if let bytes { line += " bytes=\(bytes)" }
        if let reason { line += " reason=\(reason.rawValue)" }
        if let status { line += " code=\(status)" }
        if let milliseconds, milliseconds.isFinite { line += String(format: " duration_ms=%.2f", max(0, milliseconds)) }
        if entries.count < 96 { entries.append(line) }
        if active { persist() }
    }

    public func fail(_ error: Error) {
        activate()
        let code: Int
        if let urlError = error as? URLError { code = urlError.errorCode }
        else if let relayError = error as? RelayError {
            switch relayError {
            case .http(let status): code = status
            case .invalidPairing: code = 10001
            case .invalidEnvelope: code = 10002
            case .invalidReceipt: code = 10003
            case .tooLarge: code = 10004
            case .storage: code = 10005
            }
        } else if error is CancellationError { code = -999 }
        else { code = 10000 }
        record(.finishFailure, status: code)
    }

    private func persist() {
        Self.fileLock.lock(); defer { Self.fileLock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            let destination = directory.appendingPathComponent(identifier + ".log")
            try Data(render().utf8).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let files = try Self.files(directory)
            for file in files.dropFirst(20) { try FileManager.default.removeItem(at: file) }
        } catch { persistenceFailed = true }
    }

    private static func files(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "log" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }

    public static func latest(directory: URL = RelayDiagnostics.directory) -> String? {
        fileLock.lock(); defer { fileLock.unlock() }
        guard let file = try? files(directory).first,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536 else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }
}
