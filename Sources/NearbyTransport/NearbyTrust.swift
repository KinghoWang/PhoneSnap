import Foundation
import Security
import Darwin

public nonisolated enum NearbyPairingFile {
    public static func write(_ pairing: NearbyPairing, to url: URL) throws {
        let data = try JSONEncoder().encode(pairing)
        _ = try NearbyPairing.decode(data)
        let staging = url.deletingLastPathComponent().appendingPathComponent(".phonesnap-pairing-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        guard rename(staging.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

public nonisolated struct NearbyTrustedDevice: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let pairing: NearbyPairing
    public let legacyShared: Bool
    public var id: String { pairing.serviceName }

    public static func create(name: String) throws -> Self {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 50, !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw NearbyError.invalidPairing
        }
        return Self(name: trimmed, pairing: try .generate(), legacyShared: false)
    }

    static func restore(data: Data?, legacy: NearbyPairing?) throws -> [Self] {
        guard let data else {
            return legacy.map { [Self(name: "旧版共享授权", pairing: $0, legacyShared: true)] } ?? []
        }
        guard data.count <= 65536 else { throw NearbyError.invalidPairing }
        let devices = try JSONDecoder().decode([Self].self, from: data)
        _ = try encode(devices)
        return devices
    }

    static func encode(_ devices: [Self]) throws -> Data {
        guard devices.count <= 8, Set(devices.map(\.id)).count == devices.count else { throw NearbyError.invalidPairing }
        for device in devices {
            guard !device.name.isEmpty, device.name.count <= 50,
                  !device.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw NearbyError.invalidPairing }
            _ = try NearbyPairing.decode(JSONEncoder().encode(device.pairing))
        }
        return try JSONEncoder().encode(devices)
    }
}

public nonisolated enum NearbyTrustedDeviceStore {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "dev.phonesnap.nearby.v1",
                                              kSecAttrAccount as String: "authorized-phones"]

    public static func load() throws -> [NearbyTrustedDevice] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return try NearbyTrustedDevice.restore(data: nil, legacy: NearbyPairingStore.load()) }
        guard status == errSecSuccess, let data = result as? Data else { throw NearbyError.keychain(status) }
        return try NearbyTrustedDevice.restore(data: data, legacy: nil)
    }

    public static func save(_ devices: [NearbyTrustedDevice]) throws {
        let data = try NearbyTrustedDevice.encode(devices)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NearbyError.keychain(status) }
    }
}
