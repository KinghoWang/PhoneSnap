import XCTest
import AppKit
@testable import PhoneSnap

final class ScreenshotMetadataTests: XCTestCase {
    func testTransferAndFileBytesAreIndependentAndOldMetadataStaysUnknown() throws {
        let value = ScreenshotMetadata(savedAt: Date(), source: .relay, receiveSeconds: 1.4, transferBytes: 657017)
        let summary = ScreenshotMetadata.summary(value, bytes: 4_000_000).joined(separator: "\n")
        XCTAssertTrue(summary.contains("文件 4 MB"))
        XCTAssertTrue(summary.contains("传输 657 KB"))
        XCTAssertTrue(summary.contains("公网加密"))
        let old = Data(#"{"savedAt":0,"source":"relay","receiveSeconds":1.4}"#.utf8)
        let decoded = try JSONDecoder().decode(ScreenshotMetadata.self, from: old)
        XCTAssertNil(decoded.transferBytes)
        XCTAssertTrue(ScreenshotMetadata.summary(decoded, bytes: 4_000_000).joined().contains("传输未记录"))
        XCTAssertFalse(ScreenshotMetadata.summary(ScreenshotMetadata(savedAt: Date(), source: .mac, receiveSeconds: nil), bytes: 20).joined().contains("传输"))
    }

    func testRouteTitlesNeverInferHotspotOrCableFromWiFiOrEthernet() {
        let now = Date()
        XCTAssertEqual(ScreenshotMetadata(savedAt: now, source: .relay, receiveSeconds: nil, path: "USB").routeTitle, "公网加密中转")
        XCTAssertEqual(ScreenshotMetadata(savedAt: now, source: .cable, receiveSeconds: nil).routeTitle, "USB 有线直传")
        XCTAssertEqual(ScreenshotMetadata(savedAt: now, source: .nearby, receiveSeconds: nil, path: "局域网 Wi-Fi（可能含已连接热点）").routeTitle, "Wi-Fi／热点直传（未区分）")
        XCTAssertEqual(ScreenshotMetadata(savedAt: now, source: .nearby, receiveSeconds: nil, path: "附近点对点 Wi-Fi（连接端点已确认）").routeTitle, "附近点对点直传")
        XCTAssertTrue(ScreenshotMetadata(savedAt: now, source: .nearby, receiveSeconds: nil, path: "系统报告以太网类接口（不能据此判断 USB 或热点）").routeTitle.contains("类型未确认"))
        XCTAssertTrue(ScreenshotMetadata(savedAt: now, source: .nearby, receiveSeconds: nil).routeTitle.contains("未确认"))
    }

    @MainActor func testCardShowsSummaryAndFullTooltip() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 300, height: 400).fill()
        ("无隐私测试图" as NSString).draw(at: CGPoint(x: 35, y: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: NSSize(width: 300, height: 400))
        let file = folder.appendingPathComponent("synthetic-image.png")
        try Data(repeating: 0, count: 1200).write(to: file)
        XCTAssertTrue(ScreenshotMetadata(savedAt: Date(), source: .relay, receiveSeconds: 1.2, transferBytes: 657017).write(to: file))
        let view = RecentScreenshotThumbnailView(image: image, fileURL: file, size: NSSize(width: 200, height: 230))
        view.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("公网加密") })
        XCTAssertTrue(label.stringValue.contains("1.2 秒"))
        XCTAssertTrue(label.stringValue.contains("传输 657 KB"))
        XCTAssertEqual(label.maximumNumberOfLines, 4)
        XCTAssertTrue(view.bounds.contains(label.frame))
        XCTAssertTrue(view.toolTip?.contains("synthetic-image.png") == true)
        XCTAssertTrue(view.toolTip?.contains("300 × 400 像素") == true)
        XCTAssertTrue(view.toolTip?.contains("不含空闲等图") == true)
        if let path = ProcessInfo.processInfo.environment["PHONESNAP_METADATA_PREVIEW"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }
    func testMetadataSurvivesReloadAndMoveAndUsesActualFileSize() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("image.png")
        try Data(repeating: 0, count: 1234).write(to: file)
        let value = ScreenshotMetadata(savedAt: Date(timeIntervalSince1970: 123), source: .relay, receiveSeconds: 1.2)
        XCTAssertTrue(value.write(to: file))
        let moved = folder.appendingPathComponent("renamed.png")
        try FileManager.default.moveItem(at: file, to: moved)
        XCTAssertEqual(ScreenshotMetadata.read(from: moved), value)
        XCTAssertEqual(ScreenshotMetadata.fileBytes(moved), 1234)
        XCTAssertTrue(value.routeLine.contains("1.2"))
        XCTAssertFalse(ScreenshotMetadata(savedAt: Date(), source: .mac, receiveSeconds: 20).routeLine.contains("20"))
    }

    func testUnknownAndInvalidTimingNeverBecomesZeroOrFakeReceiptTime() throws {
        XCTAssertNil(ScreenshotMetadata.read(from: URL(fileURLWithPath: "/missing-image")))
        XCTAssertEqual(ScreenshotMetadata.summary(nil, bytes: nil).first, "时间未记录")
        XCTAssertTrue(ScreenshotMetadata.summary(nil, bytes: 20).contains("通路未记录"))
        XCTAssertTrue(ScreenshotMetadata(savedAt: Date(), source: .nearby, receiveSeconds: -1).routeLine.contains("未记录"))
        XCTAssertTrue(ScreenshotMetadata(savedAt: Date(), source: .relay, receiveSeconds: .infinity).routeLine.contains("未记录"))
    }
}
