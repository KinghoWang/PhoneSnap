import AppKit
import XCTest
@testable import PhoneSnap

@MainActor
final class ScreenshotReturnCopyTests: XCTestCase {
    private func image() throws -> NSImage {
        _ = NSApplication.shared
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: NSSize(width: 400, height: 300))
    }

    private func enter(keyCode: UInt16 = 36, modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: keyCode == 76 ? "\u{3}" : "\r",
            charactersIgnoringModifiers: keyCode == 76 ? "\u{3}" : "\r", isARepeat: repeating, keyCode: keyCode))
    }

    func testReturnAndKeypadEnterCopyCommittedRegionAtOriginalSize() throws {
        let view = RegionSelectionView(image: try image(), frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            screenOrigin: NSPoint(x: -400, y: 200))
        view.setSelection(NSRect(x: 30, y: 40, width: 120, height: 80))
        var copies = 0
        view.onAction = { action, selected, frame in
            XCTAssertEqual(action, .copy)
            XCTAssertEqual(selected?.size, NSSize(width: 120, height: 80))
            XCTAssertEqual(selected?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 240)
            XCTAssertEqual(frame, NSRect(x: -370, y: 240, width: 120, height: 80))
            copies += 1
        }
        view.keyDown(with: try enter())
        view.keyDown(with: try enter(keyCode: 76, modifiers: .numericPad))
        XCTAssertEqual(copies, 2)
    }

    func testReturnDoesNotCopyUncommittedWindowHoverOrEmptyRegion() throws {
        let view = RegionSelectionView(image: try image(), frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            windowFrames: [CGRect(x: 20, y: 20, width: 200, height: 100)])
        view.onAction = { _, _, _ in XCTFail("No confirmed capture to copy") }
        view.keyDown(with: try enter())
        view.preview(at: CGPoint(x: 80, y: 50))
        view.keyDown(with: try enter())
        view.setSelection(CGRect(x: 20, y: 20, width: 1, height: 1))
        view.keyDown(with: try enter())
    }

    func testReturnDoesNotRepeatOrUseModifiedShortcutForRegion() throws {
        let view = RegionSelectionView(image: try image(), frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.setSelection(NSRect(x: 30, y: 40, width: 120, height: 80))
        view.onAction = { _, _, _ in XCTFail("Only a fresh unmodified return copies") }
        view.keyDown(with: try enter(repeating: true))
        for flags: NSEvent.ModifierFlags in [.command, .shift, .option, .control] {
            view.keyDown(with: try enter(modifiers: flags))
        }
    }

    func testLatestThumbnailAcceptsFocusAndReturnCopiesOnlyOnce() throws {
        let view = ThumbnailView(frame: NSRect(x: 0, y: 0, width: 400, height: 334), image: try image(),
            fileURL: URL(fileURLWithPath: "/synthetic/capture.png"), barHeight: 34)
        var copies = 0
        view.onCopy = { copies += 1 }
        view.onOpen = { XCTFail("Return must not open editor or Preview") }
        XCTAssertTrue(view.acceptsFirstResponder)
        view.keyDown(with: try enter())
        view.keyDown(with: try enter(keyCode: 76, modifiers: .numericPad))
        view.keyDown(with: try enter(repeating: true))
        view.keyDown(with: try enter(modifiers: .command))
        XCTAssertEqual(copies, 2)
    }

    func testRecentStripReturnCopiesAndDoesNotTriggerDeleteOrSelectAll() throws {
        let view = RecentScreenshotSelectionView(frame: .zero)
        var copies = 0
        view.onCopy = { copies += 1 }
        view.onDelete = { XCTFail("Return must never delete") }
        view.onSelectAll = { XCTFail("Return must not change selection") }
        view.keyDown(with: try enter())
        view.keyDown(with: try enter(keyCode: 76, modifiers: .numericPad))
        view.keyDown(with: try enter(repeating: true))
        for flags: NSEvent.ModifierFlags in [.command, .shift, .option, .control] {
            view.keyDown(with: try enter(modifiers: flags))
        }
        XCTAssertEqual(copies, 2)
    }

    func testRecentCopyTargetsSingleSelectionOrLatestButNotAmbiguousSelection() {
        let newest = URL(fileURLWithPath: "/synthetic/newest.png")
        let older = URL(fileURLWithPath: "/synthetic/older.png")
        let ordered = [newest, older]
        var selection = RecentScreenshotSelection()
        XCTAssertNil(selection.copyTarget(in: []))
        XCTAssertEqual(selection.copyTarget(in: ordered), newest)
        selection.click(older, ordered: ordered, modifiers: [])
        XCTAssertEqual(selection.copyTarget(in: ordered), older)
        XCTAssertNil(selection.copyTarget(in: [newest]))
        selection.click(newest, ordered: ordered, modifiers: .command)
        XCTAssertNil(selection.copyTarget(in: ordered))
    }

    func testLatestPreviewFocusesOnlyWhenCaptureExplicitlyRequestsIt() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHONESNAP_INTERACTIVE_FOCUS_TESTS"] == "1",
                          "系统焦点需交互式测试宿主；设置 PHONESNAP_INTERACTIVE_FOCUS_TESTS=1 显式验收")
        _ = NSApplication.shared
        try XCTSkipUnless(!NSScreen.screens.isEmpty, "截图预览焦点需真实桌面验收")
        let controller = ThumbnailWindowController(image: try image(),
            fileURL: URL(fileURLWithPath: "/synthetic/\(UUID().uuidString).png"), onDismissed: { _ in })
        defer { controller.dismissImmediately() }
        let previousKey = NSApp.keyWindow
        controller.show()
        XCTAssertTrue(NSApp.keyWindow === previousKey)
        controller.show(activate: true)
        let panel = try XCTUnwrap(NSApp.keyWindow as? ThumbnailPanel)
        XCTAssertTrue(panel.firstResponder === panel.contentView)
        XCTAssertTrue(panel.firstResponder is ThumbnailView)
    }

    func testRecentPreviewFocusesSelectionViewOnlyWhenExplicitlyRequested() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHONESNAP_INTERACTIVE_FOCUS_TESTS"] == "1",
                          "系统焦点需交互式测试宿主；设置 PHONESNAP_INTERACTIVE_FOCUS_TESTS=1 显式验收")
        _ = NSApplication.shared
        try XCTSkipUnless(!NSScreen.screens.isEmpty, "截图预览焦点需真实桌面验收")
        let controller = RecentScreenshotsPanelController(fileURLs: [], onClosed: { _ in })
        let previousKey = NSApp.keyWindow
        controller.show()
        XCTAssertTrue(NSApp.keyWindow === previousKey)
        controller.show(activate: true)
        let panel = try XCTUnwrap(NSApp.keyWindow as? RecentScreenshotsPanel)
        defer { panel.close() }
        XCTAssertTrue(panel.firstResponder is RecentScreenshotSelectionView)
    }
}
