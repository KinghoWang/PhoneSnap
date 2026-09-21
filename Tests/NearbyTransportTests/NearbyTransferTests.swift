import XCTest
import Network
@testable import NearbyTransport

final class NearbyTransferTests: XCTestCase {
    func testUnusableLocalConnectionFallsBackBeforeSendingExactlyOnce() async throws {
        let pairing = try NearbyPairing.generate()
        let payload = Data(repeating: 0xA5, count: 1024)
        let saved = expectation(description: "single receiver save")
        saved.assertForOverFulfill = true
        let receiver = NearbyReceiver(pairing: pairing, receive: { _ in
            XCTFail("Context receiver must not fall back to the legacy callback")
            return false
        }, state: { _ in }, receiveWithContext: { data, started, path in
            XCTAssertEqual(data, payload)
            XCTAssertLessThanOrEqual(started, ProcessInfo.processInfo.systemUptime)
            XCTAssertFalse(path.isEmpty)
            saved.fulfill()
            return true
        })
        receiver.start()
        defer { receiver.stop() }
        var attempts = 0
        let sender = NearbySender(timeout: 5, makeConnection: { endpoint, parameters in
            attempts += 1
            let target: NWEndpoint = attempts == 1 ? .hostPort(host: "127.0.0.1", port: .any) : endpoint
            return NWConnection(to: target, using: parameters)
        })
        let report = try await sender.send(payload, pairing: pairing)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(report.route, "附近发现（发送前重选，允许点对点）")
        XCTAssertTrue(report.diagnostics.contains("route.reselect"))
        XCTAssertTrue(report.diagnostics.contains("attempt=2"))
        XCTAssertTrue(report.diagnostics.contains("attempt=1 peer_allowed=false"))
        XCTAssertEqual(report.diagnostics.components(separatedBy: "payload.enqueue").count - 1, 1)
        await fulfillment(of: [saved], timeout: 1)
    }
    func testDiscoveryTimeoutRetainsStageWithoutLeakingPairing() async throws {
        let pairing = try NearbyPairing.generate()
        do {
            try await NearbySender(timeout: 0.1).send(Data([1]), pairing: pairing)
            XCTFail("Missing receiver must not succeed")
        } catch let failure as NearbyTransferFailure {
            XCTAssertEqual(failure.localizedDescription, NearbyError.timeout.localizedDescription)
            XCTAssertTrue(failure.details.contains("发现 Mac"))
            XCTAssertTrue(failure.details.contains("尚未发送图片"))
            XCTAssertFalse(failure.details.contains(pairing.serviceName))
            XCTAssertFalse(failure.details.contains(pairing.secret.base64EncodedString()))
            XCTAssertTrue(failure.diagnostics.contains("finish.failure"))
            XCTAssertFalse(failure.diagnostics.contains("payload.enqueue"))
            XCTAssertFalse(failure.diagnostics.contains(pairing.serviceName))
            XCTAssertFalse(failure.diagnostics.contains(pairing.secret.base64EncodedString()))
        }
    }
    func testEncryptedDiscoveryTransferAndReceipt() async throws {
        let pairing = try NearbyPairing.generate()
        let payload = Data(repeating: 0xA5, count: 3_000_000)
        let saved = expectation(description: "receiver gets original bytes")
        let receiver = NearbyReceiver(pairing: pairing, receive: { data in
            XCTAssertEqual(data, payload)
            saved.fulfill()
            return true
        }, state: { _ in })
        receiver.start()
        defer { receiver.stop() }
        let report = try await NearbySender().send(payload, pairing: pairing)
        XCTAssertGreaterThanOrEqual(report.discoverySeconds, 0)
        XCTAssertGreaterThanOrEqual(report.connectionSeconds, 0)
        XCTAssertGreaterThanOrEqual(report.deliverySeconds, 0)
        XCTAssertEqual(report.totalSeconds, report.discoverySeconds + report.connectionSeconds + report.deliverySeconds, accuracy: 0.001)
        XCTAssertFalse(report.path.isEmpty)
        XCTAssertTrue(report.diagnostics.contains("receipt.accepted"))
        XCTAssertTrue(report.diagnostics.contains("finish.success"))
        XCTAssertFalse(report.diagnostics.contains(pairing.serviceName))
        XCTAssertEqual(report.route, "局域网（含已连接热点）")
        await fulfillment(of: [saved], timeout: 2)
    }

    func testStorageRejectionIsNotSuccess() async throws {
        let pairing = try NearbyPairing.generate()
        let receiver = NearbyReceiver(pairing: pairing, receive: { _ in false }, state: { _ in })
        receiver.start()
        defer { receiver.stop() }
        do {
            try await NearbySender().send(Data([1]), pairing: pairing)
            XCTFail("Must wait for successful storage receipt")
        } catch {
            XCTAssertEqual(error.localizedDescription, NearbyError.rejected.localizedDescription)
            let failure = try XCTUnwrap(error as? NearbyTransferFailure)
            XCTAssertTrue(failure.details.contains("保存确认"))
            XCTAssertTrue(failure.details.contains("不自动重发"))
        }
    }

    func testWrongSecretNeverDelivers() async throws {
        let pairing = try NearbyPairing.generate()
        let wrong = NearbyPairing(version: 1, serviceName: pairing.serviceName, secret: try NearbyPairing.generate().secret)
        let receiver = NearbyReceiver(pairing: pairing, receive: { _ in
            XCTFail("Unauthenticated sender must not deliver")
            return true
        }, state: { _ in })
        receiver.start()
        defer { receiver.stop() }
        do {
            try await NearbySender().send(Data([1]), pairing: wrong)
            XCTFail("Wrong key must fail")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testCancellationCompletesWithoutReceiver() async throws {
        let pairing = try NearbyPairing.generate()
        let task = Task { try await NearbySender().send(Data([1]), pairing: pairing) }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled send must not succeed") } catch {}
    }
}
