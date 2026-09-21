import Foundation
import Darwin

struct ScreenshotMetadata: Codable, Equatable {
    enum Source: String, Codable {
        case mac, relay, nearby, cable, http, cameraUnknown
        var title: String {
            switch self {
            case .mac: return "Mac 截图"
            case .relay: return "公网加密中转"
            case .nearby: return "附近直传（通路未确认）"
            case .cable: return "USB 有线直传"
            case .http: return "HTTP 接收（通路未确认）"
            case .cameraUnknown: return "设备收图（通路未确认）"
            }
        }
    }
    let savedAt: Date
    let source: Source
    var receiveSeconds: Double?
    var path: String? = nil
    var transferBytes: Int? = nil
    var receivedImageBytes: Int? = nil
    private static let attribute = "dev.phonesnap.screenshot-info"

    var routeTitle: String {
        guard source == .nearby else { return source.title }
        switch path {
        case "局域网 Wi-Fi（可能含已连接热点）": return "Wi-Fi／热点直传（未区分）"
        case "附近点对点 Wi-Fi（连接端点已确认）": return "附近点对点直传"
        case "Wi-Fi（实际为局域网或点对点尚未确认）": return "Wi-Fi 直传（类型未确认）"
        case "系统报告以太网类接口（不能据此判断 USB 或热点）": return "网络直传（有线类型未确认）"
        case "蜂窝网络": return "蜂窝网络直连"
        case "本机回环": return "本机回环"
        default: return source.title
        }
    }

    var durationLine: String {
        guard source != .mac else { return "" }
        guard let receiveSeconds, receiveSeconds.isFinite, receiveSeconds >= 0 else { return "接收耗时未记录" }
        return String(format: "接收 %.1f 秒", receiveSeconds)
    }

    var routeLine: String {
        source == .mac ? routeTitle : "\(routeTitle) · \(durationLine)"
    }

    var sizeExplanation: String {
        var lines = ["文件大小：Mac 保存后的 PNG，可能大于传输图片；转存不会恢复有损压缩细节。"]
        if source != .mac {
            lines.append(source == .relay
                ? "传输大小：本次收到的加密正文（含密文封包）；不含 HTTP/TLS 头、回执或重试流量。"
                : "传输大小：本次收到的图片正文；不含协议头、回执或重试流量。")
            if let receivedImageBytes, receivedImageBytes >= 0 {
                lines.append("收到的图片数据：\(receivedImageBytes) 字节（转存 PNG 前；公网链路为解密后）。")
            }
            if let transferBytes, transferBytes >= 0 { lines.append("传输正文：\(transferBytes) 字节。") }
        }
        return lines.joined(separator: "\n")
    }

    static func summary(_ metadata: Self?, bytes: Int?) -> [String] {
        func formatted(_ count: Int?) -> String? {
            guard let count, count >= 0 else { return nil }
            return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
        }
        let size = "文件 " + (formatted(bytes) ?? "大小未知")
        guard let metadata else { return ["时间未记录", "\(size) · 传输未记录", "通路未记录", "接收耗时未记录"] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(metadata.savedAt) ? "'今天' HH:mm:ss" : "MM-dd HH:mm:ss"
        let transfer = metadata.source == .mac ? "" : " · " + (formatted(metadata.transferBytes).map { "传输 \($0)" } ?? "传输未记录")
        return [formatter.string(from: metadata.savedAt), size + transfer, metadata.routeTitle, metadata.durationLine]
    }

    static func fileBytes(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    func write(to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(self), data.count <= 2048 else { return false }
        return url.withUnsafeFileSystemRepresentation { filename in
            guard let filename else { return false }
            return data.withUnsafeBytes { setxattr(filename, Self.attribute, $0.baseAddress, data.count, 0, 0) == 0 }
        }
    }

    static func read(from url: URL) -> Self? {
        url.withUnsafeFileSystemRepresentation { filename in
            guard let filename else { return nil }
            let size = getxattr(filename, attribute, nil, 0, 0, 0)
            guard size > 0, size <= 2048 else { return nil }
            var data = Data(count: size)
            let count = data.withUnsafeMutableBytes { getxattr(filename, attribute, $0.baseAddress, size, 0, 0) }
            guard count == size, let value = try? JSONDecoder().decode(Self.self, from: data),
                  value.savedAt.timeIntervalSince1970.isFinite else { return nil }
            return value
        }
    }
}

struct ScreenshotReceiveContext {
    let source: ScreenshotMetadata.Source
    var started: TimeInterval? = nil
    var path: String? = nil
    var transferBytes: Int? = nil
}
