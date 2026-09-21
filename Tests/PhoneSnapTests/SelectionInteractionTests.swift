import AppKit
import XCTest
@testable import PhoneSnap

@MainActor
final class SelectionInteractionTests: XCTestCase {
    func testWindowHoverClickToolbarAndTwoStageEscape() throws {
        _ = NSApplication.shared
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: NSSize(width: 400, height: 300))
        let view = RegionSelectionView(image: image, frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            screenOrigin: CGPoint(x: -400, y: 200),
            windowFrames: [CGRect(x: -350, y: 240, width: 200, height: 100)])
        view.preview(at: CGPoint(x: 100, y: 80))
        XCTAssertNil(view.selectedImage())
        XCTAssertTrue(view.toolbar.isHidden)
        var cancelled = false
        view.onAction = { action, _, _ in cancelled = action == .cancel }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 100, y: 80),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        XCTAssertFalse(view.toolbar.isHidden)
        XCTAssertEqual(view.selectedImage()?.size, NSSize(width: 200, height: 100))
        XCTAssertEqual(view.selectedImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 400)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        XCTAssertFalse(cancelled)
        XCTAssertTrue(view.toolbar.isHidden)
        view.keyDown(with: escape)
        XCTAssertTrue(cancelled)
    }

    func testPinActionCarriesOriginalSelectionCoordinatesAcrossScreens() throws {
        _ = NSApplication.shared
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 800, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: NSSize(width: 400, height: 300))
        for origin in [NSPoint.zero, NSPoint(x: -1920, y: 100), NSPoint(x: 100, y: -1080)] {
            let view = RegionSelectionView(image: image, frame: NSRect(x: 0, y: 0, width: 400, height: 300), screenOrigin: origin)
            view.setSelection(NSRect(x: 45, y: 60, width: 120, height: 80))
            var actualFrame: NSRect?
            var actualSize: NSSize?
            view.onAction = { action, selectedImage, screenFrame in
                XCTAssertEqual(action, .pin)
                actualFrame = screenFrame
                actualSize = selectedImage?.size
            }
            let pin = try XCTUnwrap(view.toolbar.arrangedSubviews.compactMap { $0 as? NSButton }.first)
            pin.performClick(nil)
            XCTAssertEqual(actualFrame, NSRect(x: origin.x + 45, y: origin.y + 60, width: 120, height: 80))
            XCTAssertEqual(actualSize, NSSize(width: 120, height: 80))
        }
    }

    func testExplicitPinOriginIsNotCenteredOrCascadedOnDisplay() throws {
        _ = NSApplication.shared
        try XCTSkipUnless(!NSScreen.screens.isEmpty, "测试进程无法访问屏幕，原位钉图留待真实桌面验收")
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let image = NSImage(size: NSSize(width: 300, height: 180))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 300, height: 180).fill()
        image.unlockFocus()
        let origin = NSPoint(x: screen.visibleFrame.minX + 50, y: screen.visibleFrame.minY + 70)
        let presenter = PinnedImagePresenter()
        let first = try XCTUnwrap(presenter.pin(image: image, at: origin))
        let second = try XCTUnwrap(presenter.pin(image: image, at: origin))
        defer { first.close(); second.close() }
        XCTAssertEqual(first.window?.frame.origin, origin)
        XCTAssertEqual(second.window?.frame.origin, origin)
    }

    func testPinStartsAtOriginalLogicalSizeIncludingRetinaAndSmallImages() throws {
        _ = NSApplication.shared
        for size in [NSSize(width: 320, height: 1200), NSSize(width: 80, height: 60), NSSize(width: 900, height: 500)] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let pixels = try XCTUnwrap(bitmap.cgImage)
            let image = NSImage(cgImage: pixels, size: size)
            let controller = try XCTUnwrap(PinnedImageWindowController(image: image))
            defer { controller.close() }
            let root = try XCTUnwrap(controller.window?.contentView)
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(root.frame.size, size)
            let picture = try XCTUnwrap(root.subviews.compactMap { $0 as? NSImageView }.first)
            XCTAssertEqual(picture.frame.size, size)
            XCTAssertEqual(controller.image.size, size)
            XCTAssertEqual(controller.image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, pixels.width)
        }
    }

    func testSelectionIsClampedAndNormalizedInBothDragDirections() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let forward = RegionSelectionView.selection(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 500, y: 200), bounds: bounds)
        let reverse = RegionSelectionView.selection(from: CGPoint(x: 500, y: 200), to: CGPoint(x: 50, y: 40), bounds: bounds)
        XCTAssertEqual(forward, CGRect(x: 50, y: 40, width: 350, height: 160))
        XCTAssertEqual(reverse, forward)
        XCTAssertEqual(RegionSelectionAction.allCases.map(\.title), ["钉选", "编辑", "复制", "保存", "OCR 提取", "取消"])
    }

    func testSelectionCropAndToolbarStayWithinScreen() throws {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 400, height: 300))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 300).fill()
        image.unlockFocus()
        let view = RegionSelectionView(image: image, frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertNil(view.selectedImage())
        view.setSelection(CGRect(x: 100, y: 50, width: 120, height: 80))
        let crop = try XCTUnwrap(view.selectedImage())
        XCTAssertEqual(crop.size, NSSize(width: 120, height: 80))
        XCTAssertTrue(view.bounds.contains(view.toolbar.frame))
        XCTAssertFalse(view.toolbar.isHidden)
    }

    func testPinControlsOverlayAndDoubleClickClosesOnlyPin() throws {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 300, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 300, height: 200).fill()
        image.unlockFocus()
        let controller = try XCTUnwrap(PinnedImageWindowController(image: image))
        defer { controller.close() }
        XCTAssertFalse(try XCTUnwrap(controller.window).styleMask.contains(.titled))
        XCTAssertTrue(controller.actions.isHidden)
        controller.handleImageClick(count: 1)
        XCTAssertFalse(controller.actions.isHidden)
        controller.hideControls()
        XCTAssertTrue(controller.actions.isHidden)
        var closed = false
        controller.onClosed = { closed = true }
        controller.handleImageClick(count: 2)
        XCTAssertTrue(closed)
    }

    func testSyntheticSelectionPreview() throws {
        _ = NSApplication.shared
        let size = NSSize(width: 900, height: 600)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("PhoneSnap · 示例选区\n这段文字可使用 OCR 提取。" as NSString).draw(at: NSPoint(x: 150, y: 280),
            withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let view = RegionSelectionView(image: image, frame: NSRect(origin: .zero, size: size))
        view.setSelection(NSRect(x: 100, y: 240, width: 650, height: 180))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.bounds.contains(view.toolbar.frame))
        if let path = ProcessInfo.processInfo.environment["PHONESNAP_SELECTION_PREVIEW"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }
}
