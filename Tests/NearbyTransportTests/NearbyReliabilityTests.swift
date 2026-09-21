import XCTest
@testable import NearbyTransport

final class NearbyReliabilityTests: XCTestCase {
    func testPairingExportAtomicallyReplacesOnlyTheChosenFileWithPrivatePermissions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.phonesnappair")
        let first = try NearbyPairing.generate()
        let second = try NearbyPairing.generate()
        try NearbyPairingFile.write(first, to: url)
        try NearbyPairingFile.write(second, to: url)
        XCTAssertEqual(try NearbyPairing.decode(Data(contentsOf: url)), second)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [url.lastPathComponent])
    }
    func testPathRequiresReadyConnectionEvidence() {
        XCTAssertEqual(NearbyPathEvidence.classify(ready: false, scopedInterface: "awdl0", wifi: true), .unknown)
        XCTAssertEqual(NearbyPathEvidence.classify(ready: true, wifi: true), .wifiUnconfirmed)
        XCTAssertEqual(NearbyPathEvidence.classify(ready: true, scopedInterface: "awdl0", wifi: true), .peerToPeer)
        XCTAssertEqual(NearbyPathEvidence.classify(ready: true, scopedInterface: "llw0", wifi: true), .peerToPeer)
        XCTAssertEqual(NearbyPathEvidence.classify(ready: true, wifi: true, peerAllowed: false), .localWiFi)
        XCTAssertEqual(NearbyPathEvidence.classify(ready: true, wired: true), .ethernetReported)
        XCTAssertFalse(NearbyPathEvidence.ethernetReported.title.contains("有线网络"))
    }

    func testOfferAndReceiptKeepTheSameTransferIdentifier() throws {
        let offer = try NearbyOffer(identifier: UUID(), data: Data([1, 2, 3]))
        XCTAssertEqual(offer.encoded.count, 76)
        XCTAssertEqual(try NearbyOffer.decode(offer.encoded), offer)
        XCTAssertTrue(offer.matches(Data([1, 2, 3])))
        XCTAssertFalse(offer.matches(Data([1, 2, 4])))
        XCTAssertEqual(try NearbyReceipt.decode(NearbyReceipt.saved.encode(offer.identifier), expected: offer.identifier), .saved)
        XCTAssertThrowsError(try NearbyReceipt.decode(NearbyReceipt.saved.encode(UUID()), expected: offer.identifier))
        XCTAssertThrowsError(try NearbyOffer.decode(Data(repeating: 0, count: 76)))
        XCTAssertThrowsError(try NearbyOffer(identifier: UUID(), data: Data()))
        XCTAssertThrowsError(try NearbyFrame.decodeHeader(offer.encoded.prefix(8)))
    }

    func testSavedReceiptSurvivesRestartAndRejectsIdentifierReuse() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("receipts.json")
        let offer = try NearbyOffer(identifier: UUID(), data: Data([1, 2]))
        let store = NearbyReceiptStore(url: url)
        XCTAssertEqual(try store.status(offer), .needed)
        XCTAssertEqual(try store.reserve(offer), .needed)
        try store.complete(offer, saved: true)
        let reopened = NearbyReceiptStore(url: url)
        XCTAssertEqual(try reopened.status(offer), .saved)
        XCTAssertEqual(try reopened.reserve(offer), .saved)
        let conflicting = try NearbyOffer(identifier: offer.identifier, data: Data([3, 4]))
        XCTAssertEqual(try reopened.status(conflicting), .conflict)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testInterruptedSaveIsUncertainAndNeverAutomaticallyReaccepted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("receipts.json")
        let offer = try NearbyOffer(identifier: UUID(), data: Data([1]))
        XCTAssertEqual(try NearbyReceiptStore(url: url).reserve(offer), .needed)
        let reopened = NearbyReceiptStore(url: url)
        XCTAssertEqual(try reopened.status(offer), .uncertain)
        XCTAssertEqual(try reopened.reserve(offer), .uncertain)
    }

    func testRejectedSaveAndCorruptJournalNeverBecomeSuccess() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("receipts.json")
        let offer = try NearbyOffer(identifier: UUID(), data: Data([1]))
        let store = NearbyReceiptStore(url: url)
        _ = try store.reserve(offer)
        try store.complete(offer, saved: false)
        XCTAssertEqual(try store.status(offer), .rejected)
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try NearbyReceiptStore(url: url).status(offer))
    }

    func testIndependentStoreInstancesCannotReserveTheSameSaveTwice() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("receipts.json")
        let offer = try NearbyOffer(identifier: UUID(), data: Data([1]))
        let first = NearbyReceiptStore(url: url)
        let second = NearbyReceiptStore(url: url)
        XCTAssertEqual(try first.reserve(offer), .needed)
        XCTAssertEqual(try second.reserve(offer), .uncertain)
    }

    func testLegacyTrustMigrationAndEmptyListDoNotResurrectRevokedTrust() throws {
        let legacy = try NearbyPairing.generate()
        let migrated = try NearbyTrustedDevice.restore(data: nil, legacy: legacy)
        XCTAssertEqual(migrated.count, 1)
        XCTAssertTrue(migrated[0].legacyShared)
        XCTAssertEqual(migrated[0].pairing, legacy)
        XCTAssertTrue(try NearbyTrustedDevice.restore(data: Data("[]".utf8), legacy: legacy).isEmpty)
    }

    func testDeviceRevocationDoesNotChangeAnotherDevicesKey() throws {
        let first = try NearbyTrustedDevice.create(name: "手机一")
        let second = try NearbyTrustedDevice.create(name: "手机二")
        XCTAssertNotEqual(first.pairing.secret, second.pairing.secret)
        let remaining = [first, second].filter { $0.id != first.id }
        let restored = try NearbyTrustedDevice.restore(data: NearbyTrustedDevice.encode(remaining), legacy: nil)
        XCTAssertEqual(restored, [second])
        XCTAssertThrowsError(try NearbyTrustedDevice.encode([first, first]))
        XCTAssertThrowsError(try NearbyTrustedDevice.create(name: "\n"))
    }
}
