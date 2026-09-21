import XCTest
@testable import PhoneSnap

final class WirelessDiagnosticTests: XCTestCase {
    func testIncompleteHeadersNeverExposeTheirContents() {
        let message = WirelessReceiver.receiveDiagnostic(headersParsed: false,
            bufferedData: Data("Authorization: Bearer synthetic-test-only".utf8), bodyBytes: 0, expectedBytes: 0)
        XCTAssertTrue(message.contains("stage=headers"))
        XCTAssertFalse(message.contains("Authorization"))
        XCTAssertFalse(message.contains("synthetic-test-only"))
    }

    func testIncompleteImageReportsCountsAndTLSIsCategorical() {
        let body = WirelessReceiver.receiveDiagnostic(headersParsed: true,
            bufferedData: Data(), bodyBytes: 128, expectedBytes: 1024)
        XCTAssertTrue(body.contains("stage=body"))
        XCTAssertTrue(body.contains("body=128 expected=1024"))
        let tls = WirelessReceiver.receiveDiagnostic(headersParsed: false,
            bufferedData: Data([0x16, 0x03, 0x01, 0x00]), bodyBytes: 0, expectedBytes: 0)
        XCTAssertTrue(tls.contains("tls=true"))
    }
}
