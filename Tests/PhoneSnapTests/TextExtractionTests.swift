import AppKit
import XCTest
@testable import PhoneSnap

final class TextExtractionTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor func testToolbarShowsEditableOCRSheet() async throws {
        _ = NSApplication.shared
        let image = try sample()
        let document = GrabbitDocument(image: NSImage(cgImage: image, size: NSSize(width: 700, height: 450)))
        let editor = EditorWindowController(document: document)
        let window = try XCTUnwrap(editor.window)
        editor.showWindow(nil)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "整图提取文字" })
        button.performClick(nil)
        for _ in 0..<100 where !button.isEnabled { try await Task.sleep(nanoseconds: 50_000_000) }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let sheetRoot = try XCTUnwrap(sheet.contentView)
        let text = try XCTUnwrap(descendants(sheetRoot).compactMap { $0 as? ExtractedTextView }.first)
        XCTAssertTrue(text.isEditable)
        XCTAssertTrue(text.string.contains("VISIBLE"))
        XCTAssertTrue(text.string.contains("MASKED"))
        if let directory = ProcessInfo.processInfo.environment["PHONESNAP_OCR_QA_DIR"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await Task.sleep(nanoseconds: 200_000_000)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(sheet.windowNumber), folder.appendingPathComponent("ocr-result-window.png").path]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
        window.endSheet(sheet)
        document.removeWindowController(editor)
        window.orderOut(nil)
    }

    @MainActor func testImageChangesDiscardPendingText() async throws {
        _ = NSApplication.shared
        let image = try sample()
        let document = GrabbitDocument(image: NSImage(cgImage: image, size: NSSize(width: 700, height: 450)))
        let editor = EditorWindowController(document: document)
        let window = try XCTUnwrap(editor.window)
        editor.showWindow(nil)
        let root = try XCTUnwrap(window.contentView)
        let button = try XCTUnwrap(descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "整图提取文字" })
        button.performClick(nil)
        document.addPrivacyRegions([CGRect(x: 0, y: 0, width: 1, height: 1)])
        for _ in 0..<100 where !button.isEnabled { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(button.isEnabled)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("已丢弃旧文字结果") })
        document.removeWindowController(editor)
        window.orderOut(nil)
    }

    @MainActor private func sample() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 700, height: 450, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 700, height: 450))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black]
        ("VISIBLE CONTENT" as NSString).draw(at: CGPoint(x: 30, y: 345), withAttributes: attributes)
        ("MASKED SAMPLE" as NSString).draw(at: CGPoint(x: 30, y: 90), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor func testWholeAndRegionRecognitionUseBottomOriginCoordinates() throws {
        let image = try sample()
        let full = try TextExtraction.recognize(in: image)
        XCTAssertTrue(full.contains("VISIBLE"))
        XCTAssertTrue(full.contains("MASKED"))
        let top = try TextExtraction.image(from: image, region: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        let text = try TextExtraction.recognize(in: top)
        XCTAssertEqual(top.height, 225)
        XCTAssertTrue(text.contains("VISIBLE"))
        XCTAssertFalse(text.contains("MASKED"))
        XCTAssertThrowsError(try TextExtraction.image(from: image, region: CGRect(x: 2, y: 2, width: 1, height: 1)))
        XCTAssertThrowsError(try TextExtraction.image(from: image, region: CGRect(x: 0, y: 0, width: 0, height: 0)))
    }

    @MainActor func testEditorOCRNeverReadsMaskedOriginal() throws {
        _ = NSApplication.shared
        let image = try sample()
        let document = GrabbitDocument(image: NSImage(cgImage: image, size: NSSize(width: 700, height: 450)))
        let editor = EditorWindowController(document: document)
        document.addPrivacyRegions([CGRect(x: 0, y: 0, width: 1, height: 0.5)])
        let safeSnapshot = try XCTUnwrap(editor.makeOCRSnapshot(region: nil))
        let extracted = try TextExtraction.recognize(in: safeSnapshot)
        XCTAssertTrue(extracted.contains("VISIBLE"))
        XCTAssertFalse(extracted.contains("MASKED"))
        let maskedRegion = try XCTUnwrap(editor.makeOCRSnapshot(region: CGRect(x: 0, y: 0, width: 1, height: 0.5)))
        XCTAssertTrue(try TextExtraction.recognize(in: maskedRegion).isEmpty)
        document.removeWindowController(editor)
    }

    func testLineMerging() {
        XCTAssertEqual(TextExtraction.mergingLines("第一行\r\n第二行\n\n Hello world "), "第一行 第二行 Hello world")
        XCTAssertEqual(TextExtraction.mergingLines(" \n\r\n"), "")
    }

    @MainActor func testResultCopyAndExportUseUserCorrectedText() throws {
        _ = NSApplication.shared
        let result = TextExtractionResultController(text: "识别结果\n第二行")
        result.textView.string = "人工修正后的结果\n第二行"
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(result.copyText(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "人工修正后的结果\n第二行")
        XCTAssertEqual(String(data: result.exportData(), encoding: .utf8), "人工修正后的结果\n第二行")
        result.mergeLines()
        XCTAssertEqual(result.textView.string, "人工修正后的结果 第二行")
        result.textView.undoManager?.undo()
        XCTAssertEqual(result.textView.string, "人工修正后的结果\n第二行")
    }
}
