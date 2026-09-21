import Foundation

public nonisolated enum RelayWire {
    public static let contentType = "application/vnd.phonesnap.encrypted.v1"
    public static let maxBytes = 8 + 512 + RelayCrypto.maxImageBytes + 28

    private struct Metadata: Codable {
        let version: Int
        let channel: String
        let transfer: String
        let expires: Int64

        func validate() throws {
            guard version == 1, expires > 0, expires <= 9_007_199_254_740_991,
                  UUID(uuidString: channel)?.uuidString.lowercased() == channel,
                  UUID(uuidString: transfer)?.uuidString.lowercased() == transfer else {
                throw RelayError.invalidEnvelope
            }
        }
    }

    public static func encode(_ envelope: RelayEnvelope) throws -> Data {
        let metadata = Metadata(version: envelope.version, channel: envelope.channel,
                                transfer: envelope.transfer, expires: envelope.expires)
        try metadata.validate()
        guard envelope.ciphertext.utf8.count <= RelayCrypto.maxWireBytes,
              let combined = Data(base64Encoded: envelope.ciphertext),
              combined.count > 28, combined.count <= RelayCrypto.maxImageBytes + 28,
              combined.base64EncodedString() == envelope.ciphertext else { throw RelayError.invalidEnvelope }
        let header = try JSONEncoder().encode(metadata)
        guard header.count <= 512 else { throw RelayError.invalidEnvelope }
        var result = Data("PSB1".utf8)
        var length = UInt32(header.count).bigEndian
        result.append(withUnsafeBytes(of: &length) { Data($0) })
        result.append(header)
        result.append(combined)
        return result
    }

    public static func decode(_ data: Data) throws -> RelayEnvelope {
        guard data.count <= maxBytes else { throw RelayError.tooLarge }
        let frame = Data(data)
        guard frame.count >= 8, frame.prefix(4) == Data("PSB1".utf8) else { throw RelayError.invalidEnvelope }
        let length = frame[4..<8].reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 512, frame.count > 8 + length + 28,
              frame.count - 8 - length <= RelayCrypto.maxImageBytes + 28 else { throw RelayError.invalidEnvelope }
        let header = frame.subdata(in: 8..<(8 + length))
        guard let object = try JSONSerialization.jsonObject(with: header) as? [String: Any],
              Set(object.keys) == Set(["version", "channel", "transfer", "expires"]) else { throw RelayError.invalidEnvelope }
        let metadata = try JSONDecoder().decode(Metadata.self, from: header)
        try metadata.validate()
        return RelayEnvelope(version: metadata.version, channel: metadata.channel,
                             transfer: metadata.transfer, expires: metadata.expires,
                             ciphertext: frame.suffix(from: 8 + length).base64EncodedString())
    }
}
