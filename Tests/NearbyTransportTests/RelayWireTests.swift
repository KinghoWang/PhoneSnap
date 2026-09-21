import XCTest
@testable import NearbyTransport

final class RelayWireTests: XCTestCase {
    func testSwiftNodeInteroperability() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let image = Data(repeating: 97, count: 3922693)
        let envelope = try RelayCrypto.seal(image, pairing: pairing)
        let wire = try RelayWire.encode(envelope)
        let input = directory.appendingPathComponent("input.bin")
        let output = directory.appendingPathComponent("output.bin")
        try wire.write(to: input)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", package.appendingPathComponent("relay/wire-roundtrip.mjs").path, input.path, output.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let decoded = try RelayWire.decode(Data(contentsOf: output))
        XCTAssertEqual(decoded.fingerprint, envelope.fingerprint)
        XCTAssertEqual(try RelayCrypto.open(decoded, pairing: pairing), image)
        let receipt = try RelayCrypto.receipt(decoded, image: image, pairing: pairing)
        XCTAssertNoThrow(try RelayCrypto.verify(receipt, envelope: envelope, image: image, pairing: pairing))
        print("BINARY_FIXTURE_BYTES=\(wire.count) image=\(image.count)")
    }

    func testBinaryRoundTripKeepsImageAndReceiptWithoutBase64OnWire() throws {
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let image = Data(repeating: 97, count: 3922693)
        let envelope = try RelayCrypto.seal(image, pairing: pairing)
        let wire = try RelayWire.encode(envelope)
        XCTAssertLessThan(wire.count, image.count + 600)
        XCTAssertNil(wire.range(of: Data(envelope.ciphertext.utf8)))
        let decoded = try RelayWire.decode(wire)
        XCTAssertEqual(decoded.fingerprint, envelope.fingerprint)
        XCTAssertEqual(try RelayCrypto.open(decoded, pairing: pairing), image)
        let receipt = try RelayCrypto.receipt(decoded, image: image, pairing: pairing)
        XCTAssertNoThrow(try RelayCrypto.verify(receipt, envelope: envelope, image: image, pairing: pairing))
    }

    func testMalformedFramesAndTamperedCiphertextFailClosed() throws {
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let envelope = try RelayCrypto.seal(Data([1, 2, 3]), pairing: pairing)
        let wire = try RelayWire.encode(envelope)
        for size in [0, 4, 7, 8, wire.count - 30] {
            XCTAssertThrowsError(try RelayWire.decode(Data(wire.prefix(size))))
        }
        var badMagic = wire; badMagic[0] = 0
        XCTAssertThrowsError(try RelayWire.decode(badMagic))
        var badSize = wire; badSize[4] = 255
        XCTAssertThrowsError(try RelayWire.decode(badSize))
        var tampered = wire; tampered[tampered.count - 1] ^= 1
        let changed = try RelayWire.decode(tampered)
        XCTAssertThrowsError(try RelayCrypto.open(changed, pairing: pairing))
        var invalid = envelope; invalid.transfer = "not-a-uuid"
        XCTAssertThrowsError(try RelayWire.encode(invalid))
    }

    func testMaximumImageAndUnknownMetadata() throws {
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let envelope = try RelayCrypto.seal(Data(repeating: 42, count: RelayCrypto.maxImageBytes), pairing: pairing)
        let wire = try RelayWire.encode(envelope)
        XCTAssertLessThanOrEqual(wire.count, RelayWire.maxBytes)
        XCTAssertEqual(try RelayWire.decode(wire).fingerprint, envelope.fingerprint)
        XCTAssertThrowsError(try RelayWire.decode(Data(repeating: 0, count: RelayWire.maxBytes + 1)))
        let metadata: [String: Any] = ["version": 1, "channel": envelope.channel, "transfer": envelope.transfer,
                                      "expires": envelope.expires, "extra": "rejected"]
        let header = try JSONSerialization.data(withJSONObject: metadata)
        var frame = Data("PSB1".utf8)
        var length = UInt32(header.count).bigEndian
        frame.append(withUnsafeBytes(of: &length) { Data($0) })
        frame.append(header)
        frame.append(Data(base64Encoded: envelope.ciphertext)!)
        XCTAssertThrowsError(try RelayWire.decode(frame))
    }
}
