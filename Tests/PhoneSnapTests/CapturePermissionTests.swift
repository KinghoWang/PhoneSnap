import AppKit
import XCTest
@testable import PhoneSnap

@MainActor
final class CapturePermissionTests: XCTestCase {
    func testGuideOffersActionsForCurrentBundle() throws {
        _ = NSApplication.shared
        let guide = CapturePermissionGuide(checkAccess: { false })
        defer { guide.close() }
        let content = try XCTUnwrap(guide.window?.contentView)
        let buttons = descendants(of: content).compactMap { $0 as? NSButton }.filter { !$0.title.isEmpty }
        XCTAssertEqual(buttons.map(\.title), ["打开权限设置", "在 Finder 中显示本应用", "重新检查权限"])
        XCTAssertTrue(buttons.allSatisfy { $0.target === guide && $0.action != nil })
        XCTAssertEqual(guide.applicationURL, Bundle.main.bundleURL)
        XCTAssertEqual(CapturePermissionGuide.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func testRecheckReportsCurrentStateWithoutRequestingOrCapturing() {
        _ = NSApplication.shared
        var granted = false
        var checks = 0
        let guide = CapturePermissionGuide(checkAccess: { checks += 1; return granted })
        defer { guide.close() }
        guide.recheckPermission()
        XCTAssertTrue(guide.statusLabel.stringValue.contains("尚未检测到权限"))
        granted = true
        guide.recheckPermission()
        XCTAssertTrue(guide.statusLabel.stringValue.contains("权限已生效"))
        XCTAssertEqual(checks, 2)
        granted = false
        guide.recheckPermission()
        XCTAssertTrue(guide.statusLabel.stringValue.contains("退出并重新打开"))
    }

    func testGuideRemainsAvailableBesideSystemSettings() throws {
        _ = NSApplication.shared
        let guide = CapturePermissionGuide(checkAccess: { false })
        defer { guide.close() }
        let panel = try XCTUnwrap(guide.window as? NSPanel)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.isMovableByWindowBackground)
    }

    func testDragSourceExportsOnlyTheCurrentApplicationFileURL() throws {
        _ = NSApplication.shared
        let guide = CapturePermissionGuide(checkAccess: { false })
        defer { guide.close() }
        let content = try XCTUnwrap(guide.window?.contentView)
        let source = try XCTUnwrap(descendants(of: content).first { $0 is NSDraggingSource })
        let writer = try XCTUnwrap(source as? NSPasteboardWriting)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertEqual(writer.writableTypes(for: pasteboard), [.fileURL])
        let encodedURL = try XCTUnwrap(writer.pasteboardPropertyList(forType: .fileURL) as? String)
        let applicationURL = try XCTUnwrap(URL(string: encodedURL))
        XCTAssertTrue(applicationURL.isFileURL)
        XCTAssertEqual(applicationURL, Bundle.main.bundleURL)
        XCTAssertNil(writer.pasteboardPropertyList(forType: .string))
        XCTAssertTrue(pasteboard.writeObjects([writer]))
        let receivedURLs = pasteboard.readObjects(forClasses: [NSURL.self],
                                                  options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(receivedURLs, [Bundle.main.bundleURL])
        XCTAssertFalse(source.mouseDownCanMoveWindow)
        XCTAssertTrue(source.acceptsFirstMouse(for: nil))
    }

    func testCloseControlDismissesGuideWithoutAnotherPermissionCheck() throws {
        _ = NSApplication.shared
        var checks = 0
        let guide = CapturePermissionGuide(checkAccess: { checks += 1; return false })
        defer { guide.close() }
        guide.present()
        let content = try XCTUnwrap(guide.window?.contentView)
        let closeButton = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSButton }
            .first { $0.keyEquivalent == "\u{1b}" })
        let previousChecks = checks
        closeButton.performClick(nil)
        XCTAssertEqual(guide.window?.isVisible, false)
        XCTAssertEqual(checks, previousChecks)
    }

    func testReturningToApplicationAutomaticallyRechecksVisibleGuide() {
        _ = NSApplication.shared
        var granted = false
        var checks = 0
        let guide = CapturePermissionGuide(checkAccess: { checks += 1; return granted })
        defer { guide.close() }
        guide.present()
        let previousChecks = checks
        granted = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(checks, previousChecks + 1)
        XCTAssertTrue(guide.statusLabel.stringValue.contains("权限已生效"))
    }

    func testReturningToCardRechecksWithoutTreatingAnUnchangedDenialAsSuccess() throws {
        _ = NSApplication.shared
        var checks = 0
        let guide = CapturePermissionGuide(checkAccess: { checks += 1; return false })
        defer { guide.close() }
        guide.present()
        let previousChecks = checks
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification,
                                        object: try XCTUnwrap(guide.window))
        XCTAssertEqual(checks, previousChecks + 1)
        XCTAssertTrue(guide.statusLabel.stringValue.contains("尚未检测到权限"))
    }

    func testClosedGuideDoesNotKeepRecheckingAndReopeningDoesNotDuplicateObservers() {
        _ = NSApplication.shared
        var checks = 0
        let guide = CapturePermissionGuide(checkAccess: { checks += 1; return false })
        defer { guide.close() }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(checks, 0)
        guide.present()
        guide.close()
        let closedChecks = checks
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(checks, closedChecks)
        guide.present()
        guide.present()
        let reopenedChecks = checks
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(checks, reopenedChecks + 1)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
