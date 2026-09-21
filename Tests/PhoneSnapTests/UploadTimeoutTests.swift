import XCTest
@testable import PhoneSnap

final class UploadTimeoutTests: XCTestCase {
    func testProgressAllowsAnUploadBeyondThirtySeconds() {
        var timeout = UploadTimeout(startedAt: 0)
        XCTAssertTrue(timeout.recordProgress(at: 20))
        XCTAssertTrue(timeout.recordProgress(at: 40))
        XCTAssertEqual(timeout.remaining(at: 45), 25)
    }

    func testStalledUploadCannotBeRevived() {
        var timeout = UploadTimeout(startedAt: 0)
        XCTAssertTrue(timeout.recordProgress(at: 10))
        XCTAssertEqual(timeout.remaining(at: 40), 0)
        XCTAssertFalse(timeout.recordProgress(at: 40))
    }

    func testContinuousProgressCannotExceedTotalLimit() {
        var timeout = UploadTimeout(startedAt: 0)
        for time in [20.0, 40.0, 60.0, 80.0, 100.0, 119.0] {
            XCTAssertTrue(timeout.recordProgress(at: time))
        }
        XCTAssertEqual(timeout.remaining(at: 119), 1)
        XCTAssertFalse(timeout.recordProgress(at: 120))
        XCTAssertEqual(timeout.remaining(at: 130), 0)
    }
}
