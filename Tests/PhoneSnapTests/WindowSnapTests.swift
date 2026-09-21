import XCTest
@testable import PhoneSnap

final class WindowSnapTests: XCTestCase {
    func testHoverUsesFrontmostWindowAndClipsToDisplay() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        var state = WindowSnapSelection(bounds: bounds, windows: [
            CGRect(x: 100, y: 100, width: 300, height: 200),
            CGRect(x: -100, y: 50, width: 700, height: 500)])
        state.hover(at: CGPoint(x: 150, y: 150))
        XCTAssertEqual(state.rect, CGRect(x: 100, y: 100, width: 300, height: 200))
        XCTAssertFalse(state.committed)
        state.hover(at: CGPoint(x: 30, y: 100))
        XCTAssertEqual(state.rect, CGRect(x: 0, y: 50, width: 600, height: 500))
        state.hover(at: CGPoint(x: 750, y: 580))
        XCTAssertTrue(state.rect.isEmpty)
    }

    func testClickCommitsButDragOverridesWindowAndEscapeResets() {
        var state = WindowSnapSelection(bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                                        windows: [CGRect(x: 20, y: 30, width: 500, height: 400)])
        state.begin(at: CGPoint(x: 100, y: 100))
        state.end(at: CGPoint(x: 101, y: 100))
        XCTAssertTrue(state.committed)
        XCTAssertEqual(state.rect.width, 500)
        state.hover(at: CGPoint(x: 700, y: 500))
        XCTAssertEqual(state.rect.width, 500)
        XCTAssertTrue(state.reset())
        XCTAssertFalse(state.reset())
        state.begin(at: CGPoint(x: 100, y: 100))
        state.drag(to: CGPoint(x: 250, y: 180))
        state.end(at: CGPoint(x: 250, y: 180))
        XCTAssertEqual(state.rect, CGRect(x: 100, y: 100, width: 150, height: 80))
        XCTAssertTrue(state.committed)
    }

    func testResizeCornerAndManualFallback() {
        var state = WindowSnapSelection(bounds: CGRect(x: 0, y: 0, width: 800, height: 600), windows: [])
        state.begin(at: CGPoint(x: 100, y: 100))
        state.end(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(state.committed)
        state.begin(at: CGPoint(x: 100, y: 100))
        state.end(at: CGPoint(x: 300, y: 250))
        state.begin(at: CGPoint(x: 300, y: 250))
        state.end(at: CGPoint(x: 900, y: 700))
        XCTAssertEqual(state.rect, CGRect(x: 100, y: 100, width: 700, height: 500))
    }

    func testQuartzConversionUsesPrimaryDisplayNotCurrentDisplay() {
        XCTAssertEqual(WindowSnapSelection.appKitRect(CGRect(x: -500, y: -200, width: 400, height: 300), primaryTop: 900),
                       CGRect(x: -500, y: 800, width: 400, height: 300))
    }

    func testLeavingDisplayDuringDragDoesNotCancelManualSelection() {
        var state = WindowSnapSelection(bounds: CGRect(x: 0, y: 0, width: 800, height: 600), windows: [])
        state.begin(at: CGPoint(x: 100, y: 100))
        state.drag(to: CGPoint(x: 700, y: 300))
        state.hover(at: CGPoint(x: -1, y: -1))
        state.end(at: CGPoint(x: 900, y: 400))
        XCTAssertTrue(state.committed)
        XCTAssertEqual(state.rect, CGRect(x: 100, y: 100, width: 700, height: 300))
    }
}
