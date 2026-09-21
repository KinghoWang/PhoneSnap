import XCTest
@testable import NearbyTransport

final class RelayDiagnosticsTests: XCTestCase {
    func testReceivedTransferSizeIsPollBodyNotAckOrImageSize() {
        let trace = RelayDiagnostics(origin: .mac, active: false)
        XCTAssertNil(trace.receivedTransferBytes)
        trace.record(.responseBody, operation: .poll, bytes: 657017)
        XCTAssertEqual(trace.receivedTransferBytes, 657017)
        trace.record(.decryptEnd, bytes: 656848)
        trace.record(.responseBody, operation: .ack, bytes: 17)
        XCTAssertEqual(trace.receivedTransferBytes, 657017)
        trace.record(.responseBody, operation: .poll, bytes: -1)
        XCTAssertEqual(trace.receivedTransferBytes, 657017)
    }
    func testBeijingTimeAndPreparationReason() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-16T20:37:05Z"))
        let trace = RelayDiagnostics(origin: .shortcut, active: false, startedAt: instant)
        trace.record(.keptOriginal, bytes: 123, reason: .transparentPixels)
        XCTAssertTrue(trace.text.contains("started_utc=2026-09-16T20:37:05Z"))
        XCTAssertTrue(trace.text.contains("北京时间：2026-09-17 04:37:05 +08:00"))
        XCTAssertTrue(trace.text.contains("keptOriginal bytes=123 reason=transparentPixels"))
    }
    func testReceiveTimerStartsAtImageHeadersNotIdlePoll() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let trace = RelayDiagnostics(origin: .mac, directory: folder, active: false)
        trace.record(.requestBegin, operation: .poll)
        trace.record(.responseHeaders, operation: .poll, status: 204)
        XCTAssertNil(trace.receiveStartedUptime)
        let before = ProcessInfo.processInfo.systemUptime
        trace.record(.responseHeaders, operation: .poll, status: 200)
        let start = try XCTUnwrap(trace.receiveStartedUptime)
        XCTAssertGreaterThanOrEqual(start, before)
        trace.record(.responseHeaders, operation: .ack, status: 200)
        XCTAssertEqual(trace.receiveStartedUptime, start)
    }
    func testPersistenceCorrelationAndSafeFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trace = RelayDiagnostics(origin: .shortcut, directory: directory)
        trace.record(.inputReady, bytes: 123)
        trace.fail(NSError(domain: "secret-domain", code: 42, userInfo: [NSLocalizedDescriptionKey: "private-token-image-url"]))
        let text = try XCTUnwrap(RelayDiagnostics.latest(directory: directory))
        XCTAssertTrue(text.contains(trace.transfer))
        XCTAssertTrue(text.contains("inputReady"))
        XCTAssertTrue(text.contains("finishFailure"))
        XCTAssertFalse(text.contains("private-token"))
        XCTAssertFalse(text.contains("secret-domain"))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testIdlePollDoesNotWriteAndRetentionIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let poll = RelayDiagnostics(origin: .mac, directory: directory, active: false)
        poll.record(.requestBegin, operation: .poll)
        XCTAssertNil(RelayDiagnostics.latest(directory: directory))
        let transfer = UUID().uuidString.lowercased()
        poll.activate(transfer: transfer)
        XCTAssertTrue(try XCTUnwrap(RelayDiagnostics.latest(directory: directory)).contains(transfer))
        for _ in 0..<23 {
            RelayDiagnostics(origin: .app, directory: directory).record(.finishSuccess)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 20)
    }

    func testTransferIsAuthenticatedAndDiagnosticsFailureDoesNotStopCrypto() throws {
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let trace = RelayDiagnostics(origin: .app, directory: URL(fileURLWithPath: "/dev/null/diagnostics"))
        trace.record(.inputReady, bytes: 3)
        let envelope = try RelayCrypto.seal(Data([1, 2, 3]), pairing: pairing, transfer: trace.transfer)
        XCTAssertEqual(envelope.transfer, trace.transfer)
        XCTAssertEqual(try RelayCrypto.open(envelope, pairing: pairing), Data([1, 2, 3]))
        XCTAssertThrowsError(try RelayCrypto.seal(Data([1]), pairing: pairing, transfer: "not-a-uuid"))
        XCTAssertTrue(trace.text.contains("persistence_failed=true"))
    }

    func testSavedAndDuplicateStagesNeverIncludeImageOrReceipt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trace = RelayDiagnostics(origin: .mac, directory: directory.appendingPathComponent("logs"))
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let image = Data("secret-image-content".utf8)
        let envelope = try RelayCrypto.seal(image, pairing: pairing)
        trace.activate(transfer: envelope.transfer)
        let store = RelayReceiptStore(directory: directory.appendingPathComponent("receipts"))
        let receipt = try RelayDelivery.process(envelope, pairing: pairing, receipts: store, trace: trace) { _ in true }
        _ = try RelayDelivery.process(envelope, pairing: pairing, receipts: store, trace: trace) { _ in
            XCTFail("duplicate must not save again")
            return false
        }
        for event in ["decryptBegin", "decryptEnd", "saveBegin", "saveEnd", "receiptPersisted", "duplicateReceipt"] {
            XCTAssertTrue(trace.text.contains(event))
        }
        for secret in [pairing.secret, pairing.uploadToken, pairing.channel, envelope.ciphertext, receipt, "secret-image-content"] {
            XCTAssertFalse(trace.text.contains(secret))
        }
    }

    func testFailedSaveDoesNotRecordSaveSuccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trace = RelayDiagnostics(origin: .mac, directory: directory.appendingPathComponent("logs"))
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let envelope = try RelayCrypto.seal(Data([1]), pairing: pairing)
        XCTAssertThrowsError(try RelayDelivery.process(envelope, pairing: pairing,
            receipts: RelayReceiptStore(directory: directory.appendingPathComponent("receipts")), trace: trace) { _ in false }) { error in
            trace.fail(error)
        }
        XCTAssertTrue(trace.text.contains("saveBegin"))
        XCTAssertTrue(trace.text.contains("finishFailure code=10005"))
        XCTAssertFalse(trace.text.contains("saveEnd"))
        XCTAssertFalse(trace.text.contains("receiptPersisted"))
    }
}
