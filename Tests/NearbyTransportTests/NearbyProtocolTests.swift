import XCTest
@testable import NearbyTransport

final class NearbyProtocolTests: XCTestCase {
    func testFallbackOnlyBeforeSendingAndOnlyWithAnAlternative() {
        XCTAssertTrue(NearbyRouteChoice.shouldFallback(selected: .local, localUnusable: true, nearbyAvailable: true, sending: false))
        XCTAssertFalse(NearbyRouteChoice.shouldFallback(selected: .local, localUnusable: true, nearbyAvailable: true, sending: true))
        XCTAssertFalse(NearbyRouteChoice.shouldFallback(selected: .local, localUnusable: false, nearbyAvailable: true, sending: false))
        XCTAssertFalse(NearbyRouteChoice.shouldFallback(selected: .local, localUnusable: true, nearbyAvailable: false, sending: false))
        XCTAssertFalse(NearbyRouteChoice.shouldFallback(selected: .nearby, localUnusable: true, nearbyAvailable: true, sending: false))
    }
    func testLocalRouteWinsWithoutWaitingForNearbyFailure() {
        XCTAssertEqual(NearbyRouteChoice.select(local: true, nearby: true, preferenceWindowPassed: false), .local)
        XCTAssertEqual(NearbyRouteChoice.select(local: true, nearby: false, preferenceWindowPassed: false), .local)
        XCTAssertNil(NearbyRouteChoice.select(local: false, nearby: true, preferenceWindowPassed: false))
        XCTAssertEqual(NearbyRouteChoice.select(local: false, nearby: true, preferenceWindowPassed: true), .nearby)
        XCTAssertNil(NearbyRouteChoice.select(local: false, nearby: false, preferenceWindowPassed: true))
    }
    func testPairingRoundTripAndRejectsMalformedSecrets() throws {
        let pairing = try NearbyPairing.generate()
        let decoded = try NearbyPairing.decode(JSONEncoder().encode(pairing))
        XCTAssertEqual(decoded, pairing)
        XCTAssertFalse(pairing.serviceName.contains(pairing.secret.base64EncodedString()))
        XCTAssertThrowsError(try NearbyPairing.decode(Data("{}".utf8)))
        let invalid = NearbyPairing(version: 1, serviceName: pairing.serviceName, secret: Data([1]))
        XCTAssertThrowsError(try NearbyPairing.decode(JSONEncoder().encode(invalid)))
    }

    func testFrameLengthBoundsAndMagic() throws {
        for count in [1, 1024, NearbyFrame.maximumBytes] {
            XCTAssertEqual(try NearbyFrame.decodeHeader(NearbyFrame.header(byteCount: count)), count)
        }
        XCTAssertThrowsError(try NearbyFrame.header(byteCount: 0))
        XCTAssertThrowsError(try NearbyFrame.header(byteCount: NearbyFrame.maximumBytes + 1))
        XCTAssertThrowsError(try NearbyFrame.decodeHeader(Data(repeating: 0, count: 8)))
        XCTAssertThrowsError(try NearbyFrame.decodeHeader(Data([1])))
    }
}
