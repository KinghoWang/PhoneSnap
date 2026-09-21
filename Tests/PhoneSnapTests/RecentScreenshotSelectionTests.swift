import XCTest
import AppKit
@testable import PhoneSnap

final class RecentScreenshotSelectionTests: XCTestCase {
    private let files = (0..<4).map { URL(fileURLWithPath: "/synthetic/\($0).png") }

    func testCommandToggleAndShiftRange() {
        var selection = RecentScreenshotSelection()
        selection.click(files[0], ordered: files, modifiers: [])
        selection.click(files[2], ordered: files, modifiers: .shift)
        XCTAssertEqual(selection.selected, Set(files.prefix(3)))
        selection.click(files[1], ordered: files, modifiers: .command)
        XCTAssertEqual(selection.selected, Set([files[0], files[2]]))
        selection.retain(Set([files[2]]))
        XCTAssertEqual(selection.selected, Set([files[2]]))
    }

    func testReverseMarqueeAndAdditiveSelection() {
        var selection = RecentScreenshotSelection()
        selection.click(files[3], ordered: files, modifiers: [])
        selection.beginMarquee(additive: true)
        let frames = Dictionary(uniqueKeysWithValues: files.enumerated().map { index, url in
            (url, CGRect(x: index * 100, y: 0, width: 90, height: 90))
        })
        selection.marquee(from: CGPoint(x: 195, y: 95), to: CGPoint(x: 0, y: 0), frames: frames)
        XCTAssertEqual(selection.selected, Set([files[0], files[1], files[3]]))
        selection.beginMarquee(additive: false)
        selection.marquee(from: CGPoint(x: 500, y: 100), to: CGPoint(x: 550, y: 150), frames: frames)
        XCTAssertTrue(selection.selected.isEmpty)
    }

    func testBatchTrashKeepsFailuresAndDoesNotProcessDuplicates() {
        var attempted: [URL] = []
        let result = RecentScreenshotDeletion.perform([files[0], files[1], files[0]]) { url in
            attempted.append(url)
            if url == self.files[1] { throw CocoaError(.fileWriteNoPermission) }
        }
        XCTAssertEqual(attempted, [files[0], files[1]])
        XCTAssertEqual(result.removed, [files[0]])
        XCTAssertEqual(result.failed, [files[1]])
    }

    @MainActor
    func testBlankStackReceivesMarqueeButThumbnailKeepsMouseEvents() {
        let document = RecentScreenshotSelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let stack = NSStackView(frame: document.bounds)
        document.addSubview(stack)
        let tile = NSView(frame: NSRect(x: 20, y: 20, width: 80, height: 80))
        stack.addSubview(tile)
        XCTAssertTrue(document.hitTest(NSPoint(x: 200, y: 150)) === document)
        XCTAssertTrue(document.hitTest(NSPoint(x: 40, y: 40)) === tile)
        XCTAssertFalse(document.mouseDownCanMoveWindow)
        XCTAssertTrue(document.acceptsFirstMouse(for: nil))
    }

    @MainActor
    func testSelectionKeyboardActions() throws {
        let document = RecentScreenshotSelectionView(frame: .zero)
        var deleted = false
        var selectedAll = false
        var cleared = false
        document.onDelete = { deleted = true }
        document.onSelectAll = { selectedAll = true }
        document.onBegin = { cleared = $0.isEmpty }
        func event(_ keyCode: UInt16, _ text: String, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode))
        }
        XCTAssertTrue(document.performKeyEquivalent(with: try event(0, "a", .command)))
        document.keyDown(with: try event(51, ""))
        document.keyDown(with: try event(53, ""))
        XCTAssertTrue(selectedAll)
        XCTAssertTrue(deleted)
        XCTAssertTrue(cleared)
    }
}
