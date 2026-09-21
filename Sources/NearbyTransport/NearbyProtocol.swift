import Foundation
import Security
import Network

public nonisolated enum NearbyError: LocalizedError {
    case invalidPairing, invalidFrame, timeout, rejected, disconnected, cancelled
    case invalidReceipt, receiptUncertain
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidPairing: return "配对文件无效，请从 Mac 重新导出。"
        case .invalidFrame: return "图片为空或超过 32 MB，无法发送。"
        case .timeout: return "附近传输超时。请确认 Mac 已开启附近接收、两端 Wi-Fi 已开启，并靠近重试。"
        case .rejected: return "Mac 未能保存图片，未确认收件。"
        case .disconnected: return "连接中断，未确认收件。"
        case .cancelled: return "已取消传输。"
        case .invalidReceipt: return "Mac 回执格式或发送编号不匹配，未确认收件。"
        case .receiptUncertain: return "Mac 收件状态尚不确定；为避免重复保存，未自动重发。请先查看 Mac 最近截图。"
        case .keychain: return "无法访问安全配对信息，请解锁设备后重试。"
        }
    }
}

public nonisolated struct NearbyPairing: Codable, Equatable, Sendable {
    public let version: Int
    public let serviceName: String
    public let secret: Data
    public static let serviceType = "_phonesnap._tcp"

    public static func generate() throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw NearbyError.keychain(status) }
        return Self(version: 1, serviceName: UUID().uuidString.lowercased(), secret: Data(bytes))
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 1, UUID(uuidString: value.serviceName) != nil,
              value.secret.count == 32 else { throw NearbyError.invalidPairing }
        return value
    }

    public func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = secret.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(serviceName.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        return parameters
    }
}

public nonisolated enum NearbyFrame {
    public static let maximumBytes = 32 * 1024 * 1024

    public static func header(byteCount: Int) throws -> Data {
        guard (1...maximumBytes).contains(byteCount) else { throw NearbyError.invalidFrame }
        var length = UInt32(byteCount).bigEndian
        return Data("PSN1".utf8) + withUnsafeBytes(of: &length) { Data($0) }
    }

    public static func decodeHeader(_ data: Data) throws -> Int {
        guard data.count == 8, data.prefix(4) == Data("PSN1".utf8) else { throw NearbyError.invalidFrame }
        let length = data.suffix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard (1...maximumBytes).contains(length) else { throw NearbyError.invalidFrame }
        return length
    }
}

public nonisolated enum NearbyPairingStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.phonesnap.nearby.v1",
         kSecAttrAccount as String: "paired-mac"]
    }

    public static func load() throws -> NearbyPairing? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NearbyError.keychain(status) }
        return try NearbyPairing.decode(data)
    }

    public static func save(_ pairing: NearbyPairing) throws {
        let data = try JSONEncoder().encode(pairing)
        _ = try NearbyPairing.decode(data)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NearbyError.keychain(status) }
    }

    public static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NearbyError.keychain(status) }
    }
}
