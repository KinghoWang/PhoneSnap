import XCTest
import ImageIO
import UniformTypeIdentifiers
import CoreText
@testable import NearbyTransport

final class RelayImagePreparationTests: XCTestCase {
    func testOpaqueAlphaCompressesButOneTransparentPixelDoesNot() throws {
        let opaque = try fixture(alpha: true, alphaValue: 255)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(opaque as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertTrue([CGImageAlphaInfo.last, .first, .premultipliedLast, .premultipliedFirst].contains(decoded.alphaInfo))
        let result = try RelayImagePreparation.prepare(opaque, mode: .fast)
        XCTAssertTrue(result.compressed)
        XCTAssertLessThan(result.data.count, opaque.count)
        XCTAssertEqual(result.reason, .compressed)
        let transparent = try fixture(alpha: true, alphaValue: 255, transparentPixel: true)
        let kept = try RelayImagePreparation.prepare(transparent, mode: .fast)
        XCTAssertEqual(kept.data, transparent)
        XCTAssertEqual(kept.reason, .transparentPixels)
    }

    func testRetainedImagesHaveSpecificReasons() throws {
        let data = try fixture()
        XCTAssertEqual(try RelayImagePreparation.prepare(data, mode: .original).reason, .originalMode)
        XCTAssertEqual(try RelayImagePreparation.prepare(Data([1]), mode: .fast).reason, .smallImage)
        XCTAssertEqual(try RelayImagePreparation.prepare(Data(repeating: 0, count: 300_000), mode: .fast).reason, .unreadableImage)
    }

    func testMultipleFramesAreKeptWithReason() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try fixture() as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = try RelayImagePreparation.prepare(data as Data, mode: .fast)
        XCTAssertEqual(result.reason, .multipleFrames)
        XCTAssertEqual(result.data, data as Data)
    }
    func testDefaultOriginalAndSavedModeSurvivesNewReader() throws {
        let suite = "PhoneSnapQualityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(RelayImageMode.load(defaults: defaults), .original)
        defaults.set(RelayImageMode.fast.rawValue, forKey: RelayImageMode.defaultsKey)
        XCTAssertEqual(RelayImageMode.load(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))), .fast)
        defaults.set("invalid", forKey: RelayImageMode.defaultsKey)
        XCTAssertEqual(RelayImageMode.load(defaults: defaults), .original)
    }

    func testOriginalModeAndSmallFastImagesAreByteIdentical() throws {
        let image = try fixture()
        XCTAssertEqual(try RelayImagePreparation.prepare(image, mode: .original).data, image)
        let small = try fixture(width: 20, height: 20)
        XCTAssertEqual(try RelayImagePreparation.prepare(small, mode: .fast).data, small)
    }

    func testFastPreservesDimensionsOrientationAndAuthenticatedReceipt() throws {
        let input = try fixture(orientation: 6)
        let result = try RelayImagePreparation.prepare(input, mode: .fast)
        XCTAssertTrue(result.compressed)
        XCTAssertLessThan(result.data.count, input.count)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1280)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 720)
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let envelope = try RelayCrypto.seal(result.data, pairing: pairing)
        let received = try RelayWire.decode(RelayWire.encode(envelope))
        let opened = try RelayCrypto.open(received, pairing: pairing)
        XCTAssertEqual(opened, result.data)
        let receipt = try RelayCrypto.receipt(received, image: opened, pairing: pairing)
        XCTAssertNoThrow(try RelayCrypto.verify(receipt, envelope: envelope, image: result.data, pairing: pairing))
        XCTAssertThrowsError(try RelayCrypto.verify(receipt, envelope: envelope, image: input, pairing: pairing))
        print("FAST_SYNTHETIC_BYTES input=\(input.count) output=\(result.data.count)")
        if let directory = ProcessInfo.processInfo.environment["PHONESNAP_QUALITY_PREVIEW"] {
            let upright = try fixture()
            let prepared = try RelayImagePreparation.prepare(upright, mode: .fast)
            try upright.write(to: URL(fileURLWithPath: directory).appendingPathComponent("original.png"))
            try prepared.data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("fast.jpg"))
        }
    }

    func testTransparencyAndLimitsPreserveSafety() throws {
        let alpha = try fixture(alpha: true)
        XCTAssertEqual(try RelayImagePreparation.prepare(alpha, mode: .fast).data, alpha)
        XCTAssertThrowsError(try RelayImagePreparation.prepare(Data(), mode: .fast))
        XCTAssertThrowsError(try RelayImagePreparation.prepare(Data(repeating: 0, count: RelayCrypto.maxImageBytes + 1), mode: .fast))
        let invalid = Data(repeating: 10, count: 300_000)
        XCTAssertEqual(try RelayImagePreparation.prepare(invalid, mode: .fast).data, invalid)
    }

    func testTextPreviewAndAlreadyCompactJPEG() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try fixture() as CFData, nil))
        let background = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(background, in: CGRect(x: 0, y: 0, width: 1280, height: 720))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 80, y: 80, width: 1120, height: 560))
        for size in [12, 16, 24, 36] {
            let text = NSAttributedString(string: "PhoneSnap 截图文字 · 原像素尺寸 1234567890", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, CGFloat(size), nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 100, y: 100 + size * 12)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        let image = try XCTUnwrap(context.makeImage())
        let original = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(original, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = try RelayImagePreparation.prepare(original as Data, mode: .fast)
        XCTAssertTrue(result.compressed)
        let compact = NSMutableData()
        let jpeg = try XCTUnwrap(CGImageDestinationCreateWithData(compact, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(jpeg, background, [kCGImageDestinationLossyCompressionQuality: 0.3] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(jpeg))
        XCTAssertEqual(try RelayImagePreparation.prepare(compact as Data, mode: .fast).data, compact as Data)
        if let directory = ProcessInfo.processInfo.environment["PHONESNAP_QUALITY_PREVIEW"] {
            try (original as Data).write(to: URL(fileURLWithPath: directory).appendingPathComponent("text-original.png"))
            try result.data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("text-fast.jpg"))
        }
    }

    private func fixture(width: Int = 1280, height: Int = 720, orientation: Int = 1, alpha: Bool = false, alphaValue: UInt8 = 120, transparentPixel: Bool = false) throws -> Data {
        var seed: UInt64 = 987654321
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0..<(width * height) {
            for channel in 0..<3 {
                seed = seed &* 6364136223846793005 &+ 1
                pixels[pixel * 4 + channel] = UInt8(truncatingIfNeeded: seed >> 32)
            }
            if alpha { pixels[pixel * 4 + 3] = alphaValue }
        }
        if transparentPixel { pixels[pixels.count - 1] = 254 }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let data = Data(pixels)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let bitmapInfo = CGBitmapInfo(rawValue: alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
