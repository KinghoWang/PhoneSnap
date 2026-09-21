import XCTest
@testable import NearbyTransport

final class RelayReceiptStoreTests: XCTestCase {
    func testDeliveryRequiresSaveAndDeduplicatesAuthenticatedReplay() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let image = Data([1, 2, 3])
        let envelope = try RelayCrypto.seal(image, pairing: pairing)
        let store = RelayReceiptStore(directory: folder)
        XCTAssertThrowsError(try RelayDelivery.process(envelope, pairing: pairing, receipts: store) { _ in false })
        XCTAssertNil(try store.lookup(envelope))
        var saves = 0
        let receipt = try RelayDelivery.process(envelope, pairing: pairing, receipts: store) { received in
            XCTAssertEqual(received, image)
            saves += 1
            return true
        }
        XCTAssertNoThrow(try RelayCrypto.verify(receipt, envelope: envelope, image: image, pairing: pairing))
        XCTAssertEqual(try RelayDelivery.process(envelope, pairing: pairing, receipts: store) { _ in
            saves += 1
            return true
        }, receipt)
        XCTAssertEqual(saves, 1)
        var changed = envelope
        changed.transfer = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try RelayDelivery.process(changed, pairing: pairing, receipts: store) { _ in
            XCTFail("must authenticate before saving")
            return true
        })
    }

    func testSavedReceiptSurvivesRestartAndRejectsChangedCiphertext() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let image = Data([1, 2, 3])
        let envelope = try RelayCrypto.seal(image, pairing: pairing)
        let receipt = try RelayCrypto.receipt(envelope, image: image, pairing: pairing)
        let store = RelayReceiptStore(directory: folder)
        XCTAssertNil(try store.lookup(envelope))
        try store.save(envelope, receipt: receipt)
        let reopened = RelayReceiptStore(directory: folder)
        XCTAssertEqual(try reopened.lookup(envelope), receipt)
        var changed = envelope
        changed.ciphertext += "A"
        XCTAssertThrowsError(try reopened.lookup(changed))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: files[0].path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
