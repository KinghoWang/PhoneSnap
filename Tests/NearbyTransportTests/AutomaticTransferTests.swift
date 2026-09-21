import XCTest
@testable import NearbyTransport

final class AutomaticTransferTests: XCTestCase {
    func testDirectAvailabilityNeverCallsRelay() async throws {
        let result = try await AutomaticTransfer.send(direct: { true }, relay: { XCTFail("Must not use public relay") })
        XCTAssertEqual(result, .direct)
    }

    func testOnlyPreflightAbsenceSelectsRelay() async throws {
        let called = expectation(description: "relay once")
        called.assertForOverFulfill = true
        let result = try await AutomaticTransfer.send(direct: { false }, relay: { called.fulfill() })
        XCTAssertEqual(result, .relay)
        await fulfillment(of: [called], timeout: 1)
    }

    func testDirectFailureNeverFallsBack() async {
        do {
            _ = try await AutomaticTransfer.send(direct: { throw NearbyError.receiptUncertain }, relay: { XCTFail("Uncertain delivery must not duplicate") })
            XCTFail("Must report direct error")
        } catch { XCTAssertEqual(error.localizedDescription, NearbyError.receiptUncertain.localizedDescription) }
    }

    func testCancellationBeforeRelayDoesNotSend() async {
        let task = Task {
            try await AutomaticTransfer.send(direct: {
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            }, relay: { XCTFail("Cancelled operation must not send") })
        }
        do { _ = try await task.value; XCTFail("Must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMissingReceiverReturnsUnavailableWithoutPayload() async throws {
        let report = try await NearbySender().sendIfAvailable(Data([1]), pairing: .generate(), availabilityWindow: 0.15)
        XCTAssertNil(report)
    }

    func testInvalidWindowDoesNotSelectRelay() async throws {
        let pairing = try NearbyPairing.generate()
        do {
            _ = try await AutomaticTransfer.send(direct: {
                try await NearbySender().sendIfAvailable(Data([1]), pairing: pairing, availabilityWindow: 0) != nil
            }, relay: { XCTFail("Invalid input must not select relay") })
            XCTFail("Must reject invalid window")
        } catch { XCTAssertEqual(error.localizedDescription, NearbyError.invalidFrame.localizedDescription) }
    }

    func testEmptyImageDoesNotSelectRelay() async throws {
        let pairing = try NearbyPairing.generate()
        do {
            _ = try await AutomaticTransfer.send(direct: {
                try await NearbySender().sendIfAvailable(Data(), pairing: pairing) != nil
            }, relay: { XCTFail("Invalid image must not select relay") })
            XCTFail("Must reject empty image")
        } catch { XCTAssertTrue(error is NearbyTransferFailure) }
    }

    func testReadyReceiverSavesExactlyOnceWithoutRelay() async throws {
        let pairing = try NearbyPairing.generate()
        let payload = Data(repeating: 0x55, count: 2048)
        let saved = expectation(description: "saved once")
        saved.assertForOverFulfill = true
        let receiver = NearbyReceiver(pairing: pairing, receive: { data in
            XCTAssertEqual(data, payload)
            saved.fulfill()
            return true
        }, state: { _ in })
        receiver.start()
        defer { receiver.stop() }
        let result = try await AutomaticTransfer.send(direct: {
            let report = try await NearbySender().sendIfAvailable(payload, pairing: pairing, availabilityWindow: 3)
            XCTAssertNotNil(report)
            XCTAssertTrue(report?.diagnostics.contains("preflight.direct_committed") == true)
            return report != nil
        }, relay: { XCTFail("Ready direct connection must win") })
        XCTAssertEqual(result, .direct)
        await fulfillment(of: [saved], timeout: 1)
    }

    func testStorageRejectionAfterReadyNeverMeansUnavailable() async throws {
        let pairing = try NearbyPairing.generate()
        let receiver = NearbyReceiver(pairing: pairing, receive: { _ in false }, state: { _ in })
        receiver.start()
        defer { receiver.stop() }
        do {
            _ = try await AutomaticTransfer.send(direct: {
                try await NearbySender().sendIfAvailable(Data([1]), pairing: pairing, availabilityWindow: 3) != nil
            }, relay: { XCTFail("Storage rejection must not change transport") })
            XCTFail("Must propagate storage rejection")
        } catch { XCTAssertTrue(error is NearbyTransferFailure) }
    }
}
