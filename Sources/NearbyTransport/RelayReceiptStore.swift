import Foundation

public nonisolated enum RelayDelivery {
    public static func process(_ envelope: RelayEnvelope, pairing: RelayPairing,
                               receipts: RelayReceiptStore, trace: RelayDiagnostics? = nil, save: (Data) -> Bool) throws -> String {
        trace?.record(.decryptBegin)
        let image = try RelayCrypto.open(envelope, pairing: pairing)
        trace?.record(.decryptEnd, bytes: image.count)
        if let receipt = try receipts.lookup(envelope) {
            trace?.record(.duplicateReceipt)
            return receipt
        }
        trace?.record(.saveBegin)
        guard save(image) else { throw RelayError.storage }
        trace?.record(.saveEnd)
        let receipt = try RelayCrypto.receipt(envelope, image: image, pairing: pairing)
        try receipts.save(envelope, receipt: receipt)
        trace?.record(.receiptPersisted)
        return receipt
    }
}

public nonisolated struct RelayReceiptStore {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    private struct Record: Codable {
        let fingerprint: String
        let expires: Int64
        let receipt: String
    }

    private func file(_ envelope: RelayEnvelope) throws -> URL {
        guard UUID(uuidString: envelope.channel)?.uuidString.lowercased() == envelope.channel,
              UUID(uuidString: envelope.transfer)?.uuidString.lowercased() == envelope.transfer else {
            throw RelayError.invalidEnvelope
        }
        return directory.appendingPathComponent("\(envelope.channel)-\(envelope.transfer).json")
    }

    public func lookup(_ envelope: RelayEnvelope) throws -> String? {
        let url = try file(envelope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.fingerprint == envelope.fingerprint else { throw RelayError.invalidEnvelope }
        return record.receipt
    }

    public func save(_ envelope: RelayEnvelope, receipt: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let now = Int64(Date().timeIntervalSince1970)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in files where url.pathExtension == "json" {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
            if record.expires + 120 < now { try FileManager.default.removeItem(at: url) }
        }
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).count < 512 else { throw RelayError.storage }
        let data = try JSONEncoder().encode(Record(fingerprint: envelope.fingerprint, expires: envelope.expires, receipt: receipt))
        let url = try file(envelope)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw RelayError.storage }
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw RelayError.storage
        }
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
}
