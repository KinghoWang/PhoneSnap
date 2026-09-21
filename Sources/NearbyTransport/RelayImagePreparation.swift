import Foundation
import ImageIO
import UniformTypeIdentifiers

public nonisolated enum RelayImageMode: String, Sendable {
    case original, fast
    public static let defaultsKey = "PhoneSnap.relayImageMode"

    public static func load(defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .original
    }
}

public nonisolated enum RelayImagePreparation {
    public enum Reason: String, Sendable {
        case compressed, originalMode, smallImage, unreadableImage, multipleFrames, pixelLimit
        case decodeFailed, transparentPixels, unsupportedAlphaDepth, alphaInspectionFailed
        case encoderUnavailable, encodeFailed, notSmaller
    }

    public struct Result: Sendable {
        public let data: Data
        public let reason: Reason
        public var compressed: Bool { reason == .compressed }
    }

    public static func prepare(_ data: Data, mode: RelayImageMode) throws -> Result {
        guard !data.isEmpty, data.count <= RelayCrypto.maxImageBytes else { throw RelayError.invalidEnvelope }
        func original(_ reason: Reason) -> Result { Result(data: data, reason: reason) }
        guard mode == .fast else { return original(.originalMode) }
        guard data.count > 256 * 1024 else { return original(.smallImage) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return original(.unreadableImage) }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { return original(.unreadableImage) }
        guard frameCount == 1 else { return original(.multipleFrames) }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return original(.unreadableImage) }
        guard width > 0, height > 0, width <= 32_000, height <= 32_000,
              Int64(width) * Int64(height) <= 24_000_000 else { return original(.pixelLimit) }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return original(.decodeFailed) }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: break
        default:
            guard image.bitsPerComponent <= 8 else { return original(.unsupportedAlphaDepth) }
            guard let opaque = isOpaque(image) else { return original(.alphaInspectionFailed) }
            guard opaque else { return original(.transparentPixels) }
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return original(.encoderUnavailable) }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.82,
            kCGImagePropertyOrientation: properties[kCGImagePropertyOrientation] as? Int ?? 1
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return original(.encodeFailed) }
        guard output.length < data.count else { return original(.notSmaller) }
        return Result(data: output as Data, reason: .compressed)
    }

    private static func isOpaque(_ image: CGImage) -> Bool? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            for offset in stride(from: 3, to: buffer.count, by: 4) {
                if buffer[offset] != 255 { return false }
            }
            return true
        }
    }
}
