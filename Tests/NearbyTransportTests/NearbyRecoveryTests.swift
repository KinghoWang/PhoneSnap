import XCTest
import Network
@testable import NearbyTransport

final class NearbyRecoveryTests: XCTestCase {
    func testNewSenderUsesLegacyProtocolWhenMacHasNoCapabilityRecord() async throws {
        let pairing = try NearbyPairing.generate()
        let queue = DispatchQueue(label: "test.phonesnap.legacy")
        let listener = try NWListener(using: pairing.parameters())
        listener.service = NWListener.Service(name: pairing.serviceName, type: NearbyPairing.serviceType)
        let saved = expectation(description: "legacy receiver saved")
        var sessions: [NearbyConnection] = []
        listener.newConnectionHandler = { connection in
            let session = NearbyConnection(connection)
            sessions.append(session)
            connection.stateUpdateHandler = { state in
                guard state == .ready else { return }
                session.receive(count: 8) { result in
                    guard let header = try? result.get(), let count = try? NearbyFrame.decodeHeader(header) else {
                        XCTFail("New client sent non-legacy frame to legacy Mac"); connection.cancel(); return
                    }
                    session.receive(count: count) { result in
                        XCTAssertEqual(try? result.get(), Data([6]))
                        saved.fulfill()
                        connection.send(content: Data([1]), completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        defer {
            listener.cancel()
            queue.async { for session in sessions { session.connection.stateUpdateHandler = nil; session.connection.cancel() } }
        }
        let report = try await NearbySender(timeout: 5).send(Data([6]), pairing: pairing)
        XCTAssertTrue(report.diagnostics.contains("protocol.selected v=1"))
        XCTAssertFalse(report.diagnostics.contains("receipt.query"))
        await fulfillment(of: [saved], timeout: 1)
    }

    func testMismatchedReceiptIdentifierIsRejectedWithoutRetry() async throws {
        let pairing = try NearbyPairing.generate()
        let receiver = NearbyReceiver(pairing: pairing, receive: { _ in XCTFail("Invalid receipt must not upload"); return true }, state: { _ in })
        receiver.replyDelivery = { connection, _, completion in
            connection.send(content: NearbyReceipt.saved.encode(UUID()), completion: .contentProcessed(completion))
        }
        receiver.start()
        defer { receiver.stop() }
        do {
            try await NearbySender(timeout: 5).send(Data([1]), pairing: pairing)
            XCTFail("Mismatched receipt must not succeed")
        } catch let failure as NearbyTransferFailure {
            XCTAssertEqual(failure.reason, NearbyError.invalidReceipt.localizedDescription)
            XCTAssertFalse(failure.diagnostics.contains("recovery.query"))
            XCTAssertFalse(failure.diagnostics.contains("payload.enqueue"))
        }
    }

    func testStoppingOneAuthorizationDoesNotStopAnother() async throws {
        let first = try NearbyPairing.generate()
        let second = try NearbyPairing.generate()
        let firstReceiver = NearbyReceiver(pairing: first, receive: { _ in true }, state: { _ in })
        let secondReceiver = NearbyReceiver(pairing: second, receive: { _ in true }, state: { _ in })
        firstReceiver.start()
        secondReceiver.start()
        defer { firstReceiver.stop(); secondReceiver.stop() }
        try await NearbySender(timeout: 5).send(Data([1]), pairing: first)
        firstReceiver.stop()
        try await NearbySender(timeout: 5).send(Data([2]), pairing: second)
        do {
            try await NearbySender(timeout: 0.2).send(Data([3]), pairing: first)
            XCTFail("Stopped authorization must not deliver")
        } catch { }
    }

    func testLostSavedReceiptQueriesAgainWithoutSavingTwice() async throws {
        let pairing = try NearbyPairing.generate()
        let payload = Data(repeating: 0xA5, count: 4096)
        let saved = expectation(description: "saved exactly once")
        saved.assertForOverFulfill = true
        let receiver = NearbyReceiver(pairing: pairing, receive: { data in
            XCTAssertEqual(data, payload)
            saved.fulfill()
            return true
        }, state: { _ in })
        var dropped = false
        receiver.replyDelivery = { connection, data, completion in
            if data.first == NearbyReceipt.saved.rawValue, !dropped {
                dropped = true
            } else { connection.send(content: data, completion: .contentProcessed(completion)) }
        }
        receiver.start()
        defer { receiver.stop() }
        let report = try await NearbySender(timeout: 5).send(payload, pairing: pairing)
        XCTAssertTrue(report.diagnostics.contains("recovery.query"))
        XCTAssertTrue(report.diagnostics.contains("already_saved=true"))
        XCTAssertEqual(report.diagnostics.components(separatedBy: "payload.enqueue").count - 1, 1)
        await fulfillment(of: [saved], timeout: 1)
    }

    func testSameIdentifierDoesNotResaveButDifferentIdentifiersDo() async throws {
        let pairing = try NearbyPairing.generate()
        let payload = Data([3, 4, 5])
        let saved = expectation(description: "two distinct sends")
        saved.expectedFulfillmentCount = 2
        saved.assertForOverFulfill = true
        let receiver = NearbyReceiver(pairing: pairing, receive: { _ in saved.fulfill(); return true }, state: { _ in })
        receiver.start()
        defer { receiver.stop() }
        let identifier = UUID()
        try await NearbySender(timeout: 5).send(payload, pairing: pairing, transferID: identifier)
        let repeated = try await NearbySender(timeout: 5).send(payload, pairing: pairing, transferID: identifier)
        XCTAssertFalse(repeated.diagnostics.contains("payload.enqueue"))
        try await NearbySender(timeout: 5).send(payload, pairing: pairing)
        await fulfillment(of: [saved], timeout: 1)
    }

    func testUncertainSavedStateNeverUploadsAgain() async throws {
        let pairing = try NearbyPairing.generate()
        let payload = Data([9])
        let identifier = UUID()
        let receipts = NearbyReceiptStore()
        _ = try receipts.reserve(NearbyOffer(identifier: identifier, data: payload))
        let receiver = NearbyReceiver(pairing: pairing, receive: { _ in XCTFail("Unknown receipt must not resave"); return true },
                                      state: { _ in }, receipts: receipts)
        receiver.start()
        defer { receiver.stop() }
        do {
            try await NearbySender(timeout: 5).send(payload, pairing: pairing, transferID: identifier)
            XCTFail("Uncertain save must not report success")
        } catch let failure as NearbyTransferFailure {
            XCTAssertEqual(failure.reason, NearbyError.receiptUncertain.localizedDescription)
            XCTAssertFalse(failure.diagnostics.contains("payload.enqueue"))
        }
    }

    func testLegacySenderStillReceivesSingleByteAcknowledgement() async throws {
        let pairing = try NearbyPairing.generate()
        let receiver = NearbyReceiver(pairing: pairing, receive: { $0 == Data([7]) }, state: { _ in })
        receiver.start()
        defer { receiver.stop() }
        let sender = NearbySender(timeout: 5)
        let endpoint = NWEndpoint.service(name: pairing.serviceName, type: NearbyPairing.serviceType, domain: "local.", interface: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sender.begin(Data([7]), pairing: pairing, endpoint: endpoint) { continuation.resume(with: $0) }
        }
    }
}
