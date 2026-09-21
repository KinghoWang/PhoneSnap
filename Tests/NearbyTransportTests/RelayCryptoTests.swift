import XCTest
@testable import NearbyTransport

final class RelayCryptoTests: XCTestCase {
    func testSelfHostedEndpointInput() throws {
        let pairing = try RelayPairing.generate(baseURL: "  https://snap.example.com/\n")
        XCTAssertEqual(pairing.baseURL, "https://snap.example.com")
        for invalid in ["", "http://snap.example.com", "https://user:password@snap.example.com",
                        "https://snap.example.com/path/", "https://snap.example.com?token=example",
                        "https://snap.example.com#secret", "https://snap.example.com:8787"] {
            XCTAssertThrowsError(try RelayPairing.generate(baseURL: invalid))
        }
    }

    func testRoundtripAndAuthenticatedReceipt() throws {
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let data = Data("synthetic screenshot".utf8)
        let envelope = try RelayCrypto.seal(data, pairing: pairing, now: 1000)
        XCTAssertEqual(try RelayCrypto.open(envelope, pairing: pairing, now: 1001), data)
        let receipt = try RelayCrypto.receipt(envelope, image: data, pairing: pairing)
        XCTAssertNoThrow(try RelayCrypto.verify(receipt, envelope: envelope, image: data, pairing: pairing))
        XCTAssertThrowsError(try RelayCrypto.verify(receipt, envelope: envelope, image: Data([4]), pairing: pairing))
        XCTAssertThrowsError(try RelayCrypto.open(envelope, pairing: pairing, now: 1091))
        XCTAssertThrowsError(try RelayCrypto.open(envelope, pairing: pairing, now: 900))
    }

    func testTamperingWrongKeyAndNonceUniqueness() throws {
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let image = Data([1, 2, 3])
        var envelope = try RelayCrypto.seal(image, pairing: pairing)
        let second = try RelayCrypto.seal(image, pairing: pairing)
        XCTAssertNotEqual(envelope.ciphertext, second.ciphertext)
        var wrong = pairing
        wrong.secret = Data(repeating: 0, count: 32).base64EncodedString()
        XCTAssertThrowsError(try RelayCrypto.open(envelope, pairing: wrong))
        var changed = envelope
        changed.transfer = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try RelayCrypto.open(changed, pairing: pairing))
        changed = envelope
        changed.expires += 1
        XCTAssertThrowsError(try RelayCrypto.open(changed, pairing: pairing))
        changed = envelope
        changed.channel = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try RelayCrypto.open(changed, pairing: pairing))
        var bytes = Data(base64Encoded: envelope.ciphertext)!
        bytes[bytes.count - 1] ^= 1
        envelope.ciphertext = bytes.base64EncodedString()
        XCTAssertThrowsError(try RelayCrypto.open(envelope, pairing: pairing))
        XCTAssertThrowsError(try RelayCrypto.verify("forged", envelope: second, image: image, pairing: pairing))
    }

    func testPairingExportsSeparateServerAndPhoneSecrets() throws {
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let server = String(data: try pairing.serverConfiguration(), encoding: .utf8)!
        XCTAssertFalse(server.contains(pairing.secret))
        let phone = try JSONDecoder().decode(RelayPairing.self, from: pairing.phoneConfiguration())
        XCTAssertNil(phone.receiveToken)
        XCTAssertEqual(phone.secret, pairing.secret)
        XCTAssertThrowsError(try RelayPairing.generate(baseURL: "http://snap.example.com"))
        XCTAssertThrowsError(try RelayPairing.generate(baseURL: "https://user:pass@snap.example.com"))
        XCTAssertThrowsError(try RelayPairing.generate(baseURL: "https://snap.example.com/path"))
    }
}
