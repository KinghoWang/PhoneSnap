import AppKit
import XCTest
@testable import PhoneSnap

@MainActor
final class CapturePresentationTests: XCTestCase {
    func testCaptureSavesBeforePreviewWithoutOpeningEditor() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = MacCapture()
        let image = NSImage(size: NSSize(width: 40, height: 40))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 40).fill()
        image.unlockFocus()
        var previewURL: URL?
        capture.onCaptured = { url in
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            previewURL = url
        }
        let hadEditor = ScreenshotEditor.shared.hasOpenEditors
        try capture.finishCapture(data: XCTUnwrap(image.tiffRepresentation), store: ImageStore(folder: folder))
        XCTAssertNotNil(previewURL)
        XCTAssertEqual(ScreenshotEditor.shared.hasOpenEditors, hadEditor)
        previewURL = nil
        XCTAssertThrowsError(try capture.finishCapture(data: Data(), store: ImageStore(folder: folder)))
        XCTAssertNil(previewURL)
    }

    func testPinsStayIndependentAndClosingDoesNotDeleteSource() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = NSImage(size: NSSize(width: 80, height: 120))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 80, height: 120).fill()
        image.unlockFocus()
        let source = try ImageStore(folder: folder).save(data: XCTUnwrap(image.tiffRepresentation))
        let thumbnail = RecentScreenshotThumbnailView(image: image, fileURL: source, size: NSSize(width: 118, height: 172))
        let pinButton = try XCTUnwrap(thumbnail.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "钉选到屏幕" })
        XCTAssertNotNil(pinButton.action)
        XCTAssertNotNil(pinButton.target)
        let presenter = PinnedImagePresenter()
        let first = try XCTUnwrap(presenter.pin(fileURL: source))
        let second = try XCTUnwrap(presenter.pin(image: image))
        defer { first.close(); second.close() }
        XCTAssertEqual(presenter.controllers.count, 2)
        XCTAssertFalse(first === second)
        XCTAssertFalse(first.image === image)
        XCTAssertEqual(first.window?.level, .floating)
        XCTAssertEqual(first.window?.hidesOnDeactivate, false)
        XCTAssertEqual(first.window?.styleMask.contains(.resizable), true)
        first.close()
        XCTAssertEqual(presenter.controllers.count, 1)
        XCTAssertTrue(presenter.controllers.first === second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testEditedPinKeepsRedactedSnapshotWhenDocumentChanges() throws {
        _ = NSApplication.shared
        let original = NSImage(size: NSSize(width: 240, height: 160))
        original.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 160).fill()
        original.unlockFocus()
        let document = GrabbitDocument(image: original)
        let editor = EditorWindowController(document: document)
        defer { document.removeWindowController(editor) }
        document.addPrivacyRegions([CGRect(x: 0, y: 0, width: 1, height: 1)], pixelated: false, color: .black)
        editor.pinEdited()
        let pinned = try XCTUnwrap(PinnedImagePresenter.shared.controllers.last)
        defer { pinned.close() }
        let mask = try XCTUnwrap(document.shapes.first)
        document.changeRedaction(id: mask.id, pixelated: false, color: .red, intensity: 50)
        let pixels = try XCTUnwrap(pinned.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let sample = try XCTUnwrap(NSBitmapImageRep(cgImage: pixels).colorAt(x: pixels.width / 2, y: pixels.height / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(sample.redComponent, 0.01)
        XCTAssertLessThan(sample.greenComponent, 0.01)
        XCTAssertLessThan(sample.blueComponent, 0.01)
        if let path = ProcessInfo.processInfo.environment["PHONESNAP_TEST_PREVIEW_PATH"] {
            let root = try XCTUnwrap(pinned.window?.contentView)
            root.setFrameSize(NSSize(width: 360, height: 278))
            root.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(root.bounds.width),
                pixelsHigh: Int(root.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill()
            root.bounds.fill()
            root.displayIgnoringOpacity(root.bounds, in: context)
            NSGraphicsContext.restoreGraphicsState()
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    func testPinPlacementAndResizeOnRealDisplay() throws {
        _ = NSApplication.shared
        try XCTSkipUnless(!NSScreen.screens.isEmpty, "测试进程无法访问屏幕；位置和缩放留待真实桌面验收")
        let image = NSImage(size: NSSize(width: 240, height: 160))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 160).fill()
        image.unlockFocus()
        let presenter = PinnedImagePresenter()
        let controller = try XCTUnwrap(presenter.pin(image: image))
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let screen = try XCTUnwrap(window.screen)
        XCTAssertTrue(screen.visibleFrame.contains(window.frame))
        let root = try XCTUnwrap(window.contentView)
        for size in [NSSize(width: 200, height: 120), NSSize(width: 360, height: 278)] {
            window.setContentSize(size)
            window.layoutIfNeeded()
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(root.bounds.height, size.height, accuracy: 1)
            XCTAssertEqual(root.bounds.width, size.width, accuracy: 1)
            let picture = try XCTUnwrap(root.subviews.compactMap { $0 as? NSImageView }.first)
            XCTAssertGreaterThan(picture.frame.height, 0)
            XCTAssertEqual(picture.imageScaling, .scaleProportionallyUpOrDown)
        }
    }
}
