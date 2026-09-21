import Foundation
import Network
import CryptoKit
import Darwin

nonisolated enum NearbyPathEvidence: Equatable {
    case unknown, peerToPeer, localWiFi, wifiUnconfirmed, ethernetReported, cellular, loopback

    static func classify(ready: Bool, scopedInterface: String? = nil, wifi: Bool = false,
                         wired: Bool = false, cellular: Bool = false, loopback: Bool = false,
                         peerAllowed: Bool = true) -> Self {
        guard ready else { return .unknown }
        if let scopedInterface, scopedInterface.hasPrefix("awdl") || scopedInterface.hasPrefix("llw") { return .peerToPeer }
        if wifi { return peerAllowed ? .wifiUnconfirmed : .localWiFi }
        if wired { return .ethernetReported }
        if cellular { return .cellular }
        if loopback { return .loopback }
        return .unknown
    }

    static func inspect(_ path: NWPath?, ready: Bool, peerAllowed: Bool) -> Self {
        guard let path, path.status == .satisfied else { return .unknown }
        var scopedInterface: String?
        if case .hostPort(let host, _) = path.remoteEndpoint,
           case .ipv6(let address) = host, address.isLinkLocal {
            scopedInterface = address.interface?.name
        }
        return classify(ready: ready, scopedInterface: scopedInterface, wifi: path.usesInterfaceType(.wifi),
                        wired: path.usesInterfaceType(.wiredEthernet), cellular: path.usesInterfaceType(.cellular),
                        loopback: path.usesInterfaceType(.loopback), peerAllowed: peerAllowed)
    }

    var title: String {
        switch self {
        case .unknown: return "实际通路未确认"
        case .peerToPeer: return "附近点对点 Wi-Fi（连接端点已确认）"
        case .localWiFi: return "局域网 Wi-Fi（可能含已连接热点）"
        case .wifiUnconfirmed: return "Wi-Fi（实际为局域网或点对点尚未确认）"
        case .ethernetReported: return "系统报告以太网类接口（不能据此判断 USB 或热点）"
        case .cellular: return "蜂窝网络"
        case .loopback: return "本机回环"
        }
    }
}

nonisolated struct NearbyOffer: Codable, Equatable, Sendable {
    let identifier: UUID
    let byteCount: Int
    let digest: Data

    init(identifier: UUID, data: Data) throws {
        _ = try NearbyFrame.header(byteCount: data.count)
        self.identifier = identifier
        byteCount = data.count
        digest = Data(SHA256.hash(data: data))
    }

    private init(identifier: UUID, byteCount: Int, digest: Data) {
        self.identifier = identifier
        self.byteCount = byteCount
        self.digest = digest
    }

    var valid: Bool { (1...NearbyFrame.maximumBytes).contains(byteCount) && digest.count == 32 }

    var encoded: Data {
        var count = UInt32(byteCount).bigEndian
        return Data("PSN2".utf8) + withUnsafeBytes(of: &count) { Data($0) }
            + Data(identifier.uuidString.utf8) + digest
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count == 76, data.prefix(4) == Data("PSN2".utf8),
              let text = String(data: data.dropFirst(8).prefix(36), encoding: .utf8),
              let identifier = UUID(uuidString: text) else { throw NearbyError.invalidReceipt }
        let count = try NearbyFrame.decodeHeader(Data("PSN1".utf8) + data.dropFirst(4).prefix(4))
        return Self(identifier: identifier, byteCount: count, digest: Data(data.suffix(32)))
    }

    func matches(_ data: Data) -> Bool { data.count == byteCount && Data(SHA256.hash(data: data)) == digest }
}

nonisolated enum NearbyReceipt: UInt8, Codable {
    case rejected = 0, saved = 1, needed = 2, uncertain = 3, conflict = 4

    func encode(_ identifier: UUID) -> Data { Data([rawValue]) + Data(identifier.uuidString.utf8) }

    static func decode(_ data: Data, expected: UUID) throws -> Self {
        guard data.count == 37, let value = data.first, let receipt = Self(rawValue: value),
              let text = String(data: data.dropFirst(), encoding: .utf8),
              UUID(uuidString: text) == expected else { throw NearbyError.invalidReceipt }
        return receipt
    }
}

public nonisolated final class NearbyReceiptStore: @unchecked Sendable {
    private struct Entry: Codable {
        let offer: NearbyOffer
        var receipt: NearbyReceipt
        let created: Date
    }

    private let url: URL?
    private let lock = NSLock()
    private var entries: [Entry] = []

    public init(url: URL? = nil) { self.url = url }

    func status(_ offer: NearbyOffer) throws -> NearbyReceipt {
        try transact { entries in (Self.lookup(offer, entries: entries), false) }
    }

    func reserve(_ offer: NearbyOffer) throws -> NearbyReceipt {
        try transact { entries in
            let status = Self.lookup(offer, entries: entries)
            guard status == .needed else { return (status, false) }
            guard entries.count < 1024 else { throw NearbyError.receiptUncertain }
            entries.append(Entry(offer: offer, receipt: .uncertain, created: Date()))
            return (.needed, true)
        }
    }

    func complete(_ offer: NearbyOffer, saved: Bool) throws {
        _ = try transact { entries in
            guard let index = entries.firstIndex(where: { $0.offer == offer }),
                  entries[index].receipt == .uncertain else { throw NearbyError.receiptUncertain }
            entries[index].receipt = saved ? .saved : .rejected
            return (entries[index].receipt, true)
        }
    }

    private static func lookup(_ offer: NearbyOffer, entries: [Entry]) -> NearbyReceipt {
        guard let entry = entries.first(where: { $0.offer.identifier == offer.identifier }) else { return .needed }
        return entry.offer == offer ? entry.receipt : .conflict
    }

    private func transact(_ action: (inout [Entry]) throws -> (NearbyReceipt, Bool)) throws -> NearbyReceipt {
        lock.lock()
        defer { lock.unlock() }
        var descriptor: Int32 = -1
        defer { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
        if let url {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            descriptor = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else { throw NearbyError.receiptUncertain }
            if FileManager.default.fileExists(atPath: url.path) {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 524288 else { throw NearbyError.receiptUncertain }
                entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
                guard entries.count <= 1024, entries.allSatisfy({ $0.offer.valid && $0.receipt != .needed && $0.receipt != .conflict }),
                      Set(entries.map { $0.offer.identifier }).count == entries.count else { throw NearbyError.receiptUncertain }
            } else { entries = [] }
        }
        entries.removeAll { Date().timeIntervalSince($0.created) > 86400 }
        let (receipt, changed) = try action(&entries)
        if changed, let url {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var destination = url
            try destination.setResourceValues(values)
            var directory = url.deletingLastPathComponent()
            try directory.setResourceValues(values)
        }
        return receipt
    }
}
