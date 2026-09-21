import XCTest
@testable import NearbyTransport

final class NearbyDiagnosticsTests: XCTestCase {
    func testTraceIsBoundedAndKeepsIdentityAndFinalEvent() {
        var trace = NearbyDiagnostics()
        let identifier = trace.identifier
        for index in 0..<150 { trace.append("event=\(index)") }
        XCTAssertLessThanOrEqual(trace.entries.count, 80)
        XCTAssertTrue(trace.text.contains(identifier))
        XCTAssertTrue(trace.text.contains("event=149"))
        XCTAssertTrue(trace.text.contains("省略"))
        XCTAssertNotEqual(identifier, NearbyDiagnostics().identifier)
    }

    func testOnlyLatestDiagnosticIsSavedAndExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("latest.log")
        try NearbyDiagnosticFile.save("old attempt", to: url)
        try NearbyDiagnosticFile.save("new attempt", to: url)
        XCTAssertEqual(try NearbyDiagnosticFile.load(from: url), "new attempt")
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertThrowsError(try NearbyDiagnosticFile.save(String(repeating: "x", count: 131073), to: url))
        XCTAssertEqual(try NearbyDiagnosticFile.load(from: url), "new attempt")
    }
}
