import Foundation
import CryptoKit
import Security

public nonisolated enum RelayError: Error, LocalizedError {
    case invalidPairing, invalidEnvelope, invalidReceipt, tooLarge, http(Int), storage

    public var errorDescription: String? {
        switch self {
        case .invalidPairing: return "端到端加密配对无效，请重新从可信 Mac 导入。"
        case .invalidEnvelope: return "密文已过期、被修改或不属于此配对，已拒绝。"
        case .invalidReceipt: return "没有通过 Mac 加密保存回执验证，不能确认送达。"
        case .tooLarge: return "加密中转单张图片上限为 8 MiB。"
        case .http(let status): return "加密中转 HTTP \(status)；未确认 Mac 保存，不会改用明文。"
        case .storage: return "无法安全保存配对或防重放记录，已停止处理。"
        }
    }
}

public nonisolated struct RelayPairing: Codable, Sendable {
    public var version = 1
    public var baseURL: String
    public var channel: String
    public var secret: String
    public var uploadToken: String
    public var receiveToken: String?

    public static func generate(baseURL: String) throws -> Self {
        let input = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = input.hasSuffix("/") ? String(input.dropLast()) : input
        let result = Self(baseURL: endpoint, channel: UUID().uuidString.lowercased(),
                          secret: random(), uploadToken: random(), receiveToken: random())
        try result.validate()
        return result
    }

    private static func random() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }

    public func validate() throws {
        guard version == 1, let url = URLComponents(string: baseURL),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty, url.port == nil || url.port == 443,
              UUID(uuidString: channel)?.uuidString.lowercased() == channel,
              Data(base64Encoded: secret)?.count == 32,
              Data(base64Encoded: uploadToken)?.count == 32,
              receiveToken == nil || Data(base64Encoded: receiveToken!)?.count == 32,
              secret != uploadToken, secret != receiveToken, uploadToken != receiveToken else {
            throw RelayError.invalidPairing
        }
    }

    public func phoneConfiguration() throws -> Data {
        try validate()
        var phone = self
        phone.receiveToken = nil
        return try JSONEncoder().encode(phone)
    }

    public func serverConfiguration() throws -> Data {
        try validate()
        guard let receiveToken else { throw RelayError.invalidPairing }
        return try JSONSerialization.data(withJSONObject: ["channels": [
            ["channel": channel, "uploadToken": uploadToken, "receiveToken": receiveToken]
        ]], options: [.prettyPrinted, .sortedKeys])
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw RelayError.invalidPairing }
        let pairing = try JSONDecoder().decode(Self.self, from: data)
        try pairing.validate()
        return pairing
    }
}

public nonisolated struct RelayEnvelope: Codable, Sendable {
    public var version: Int
    public var channel: String
    public var transfer: String
    public var expires: Int64
    public var ciphertext: String

    var authenticatedData: Data {
        Data("phonesnap-relay|\(version)|\(channel)|\(transfer)|\(expires)".utf8)
    }

    public var fingerprint: String {
        SHA256.hash(data: authenticatedData + Data(ciphertext.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public nonisolated enum RelayCrypto {
    public static let maxImageBytes = 8 * 1024 * 1024
    public static let maxWireBytes = 12 * 1024 * 1024

    private static func key(_ pairing: RelayPairing, direction: String) throws -> SymmetricKey {
        try pairing.validate()
        guard let data = Data(base64Encoded: pairing.secret) else { throw RelayError.invalidPairing }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: data),
                                     salt: Data(pairing.channel.utf8),
                                     info: Data("phonesnap-relay-v1/\(direction)".utf8), outputByteCount: 32)
    }

    public static func seal(_ data: Data, pairing: RelayPairing,
                            now: TimeInterval = Date().timeIntervalSince1970,
                            transfer: String = UUID().uuidString.lowercased()) throws -> RelayEnvelope {
        guard !data.isEmpty, data.count <= maxImageBytes else { throw RelayError.tooLarge }
        guard UUID(uuidString: transfer)?.uuidString.lowercased() == transfer else { throw RelayError.invalidEnvelope }
        var envelope = RelayEnvelope(version: 1, channel: pairing.channel,
                                     transfer: transfer, expires: Int64(now) + 90, ciphertext: "")
        let sealed = try AES.GCM.seal(data, using: key(pairing, direction: "image"), authenticating: envelope.authenticatedData)
        guard let combined = sealed.combined else { throw RelayError.invalidEnvelope }
        envelope.ciphertext = combined.base64EncodedString()
        return envelope
    }

    public static func open(_ envelope: RelayEnvelope, pairing: RelayPairing,
                            now: TimeInterval = Date().timeIntervalSince1970) throws -> Data {
        guard envelope.version == 1, envelope.channel == pairing.channel,
              UUID(uuidString: envelope.transfer)?.uuidString.lowercased() == envelope.transfer,
              Double(envelope.expires) > now, Double(envelope.expires) <= now + 95,
              envelope.ciphertext.utf8.count <= maxWireBytes,
              let combined = Data(base64Encoded: envelope.ciphertext),
              combined.count > 28, combined.count <= maxImageBytes + 28 else { throw RelayError.invalidEnvelope }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key(pairing, direction: "image"),
                                authenticating: envelope.authenticatedData)
    }

    private static func receiptMessage(_ envelope: RelayEnvelope, image: Data) -> Data {
        Data("Mac_saved|\(envelope.fingerprint)|".utf8) + Data(SHA256.hash(data: image))
    }

    public static func receipt(_ envelope: RelayEnvelope, image: Data, pairing: RelayPairing) throws -> String {
        let sealed = try AES.GCM.seal(receiptMessage(envelope, image: image), using: key(pairing, direction: "receipt"),
                                      authenticating: envelope.authenticatedData)
        guard let combined = sealed.combined else { throw RelayError.invalidReceipt }
        return combined.base64EncodedString()
    }

    public static func verify(_ receipt: String, envelope: RelayEnvelope, image: Data, pairing: RelayPairing) throws {
        guard receipt.utf8.count <= 4096, let data = Data(base64Encoded: receipt) else { throw RelayError.invalidReceipt }
        let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(pairing, direction: "receipt"),
                                      authenticating: envelope.authenticatedData)
        guard opened == receiptMessage(envelope, image: image) else { throw RelayError.invalidReceipt }
    }
}

public nonisolated enum RelayPairingStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.phonesnap.e2ee-relay.v1", kSecAttrAccount as String: "pairing"]
    }

    public static func load() throws -> RelayPairing? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw RelayError.storage }
        return try RelayPairing.decode(data)
    }

    public static func save(_ pairing: RelayPairing) throws {
        try pairing.validate()
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(pairing),
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RelayError.storage }
    }
}
