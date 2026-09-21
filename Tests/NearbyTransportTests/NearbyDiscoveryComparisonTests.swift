import XCTest
import Network
@testable import NearbyTransport

final class NearbyDiscoveryComparisonTests: XCTestCase {
    func testAppCancellationReportsBothDiscoveryModesWithoutSending() async throws {
        let failure = try await cancelledDiscovery(origin: .app)
        XCTAssertTrue(failure.diagnostics.contains("PhoneSnap 诊断 v3"))
        XCTAssertTrue(failure.diagnostics.contains("discovery.name_only.local.start observing_only=true"))
        XCTAssertTrue(failure.diagnostics.contains("discovery.name_only.nearby.start observing_only=true"))
        XCTAssertTrue(failure.diagnostics.contains("discovery.summary"))
        for label in ["txt.local", "txt.nearby", "name_only.local", "name_only.nearby"] {
            XCTAssertTrue(failure.diagnostics.contains("\(label){updates="))
        }
        XCTAssertTrue(failure.diagnostics.split(separator: "\n").last?.contains("finish.failure") == true)
    }

    func testShortcutDoesNotStartComparisonBrowsers() async throws {
        let failure = try await cancelledDiscovery(origin: .shortcut)
        XCTAssertFalse(failure.diagnostics.contains("discovery.name_only."))
        XCTAssertTrue(failure.diagnostics.contains("txt.local{updates="))
        XCTAssertTrue(failure.diagnostics.contains("txt.nearby{updates="))
    }

    func testNameOnlyProbeRecognizesThePairedServiceWithoutUploading() async throws {
        try await observeNameOnlyService(matching: true)
    }

    func testNameOnlyProbeDistinguishesOtherServicesFromNoResults() async throws {
        try await observeNameOnlyService(matching: false)
    }

    func testAppComparisonPreservesReliableProtocolAndSavesOnlyOnce() async throws {
        let pairing = try NearbyPairing.generate()
        let payload = Data([41, 42, 43])
        let saved = expectation(description: "one authenticated save")
        saved.assertForOverFulfill = true
        let receiver = NearbyReceiver(pairing: pairing, receive: { data in
            XCTAssertEqual(data, payload)
            saved.fulfill()
            return true
        }, state: { _ in })
        receiver.start()
        defer { receiver.stop() }
        let report = try await NearbySender(origin: .app).send(payload, pairing: pairing)
        XCTAssertTrue(report.diagnostics.contains("discovery.name_only.local.start"))
        XCTAssertTrue(report.diagnostics.contains("discovery.summary"))
        XCTAssertTrue(report.diagnostics.contains("protocol.selected v=2"))
        XCTAssertFalse(report.diagnostics.contains("protocol.selected v=1"))
        XCTAssertEqual(report.diagnostics.components(separatedBy: "payload.enqueue").count - 1, 1)
        XCTAssertTrue(report.diagnostics.contains("receipt.accepted"))
        await fulfillment(of: [saved], timeout: 1)
    }

    private func cancelledDiscovery(origin: NearbySendOrigin) async throws -> NearbyTransferFailure {
        let pairing = try NearbyPairing.generate()
        let began = expectation(description: "sender began")
        let sender = NearbySender(origin: origin) { _, text in
            if text.split(separator: "\n").last?.contains("transfer.begin") == true { began.fulfill() }
        }
        let transfer = Task { try await sender.send(Data([1]), pairing: pairing) }
        await fulfillment(of: [began], timeout: 2)
        sender.cancel()
        do {
            _ = try await transfer.value
            XCTFail("Cancellation must not succeed")
            throw NearbyError.rejected
        } catch let failure as NearbyTransferFailure {
            XCTAssertFalse(failure.diagnostics.contains("payload.enqueue"))
            XCTAssertFalse(failure.diagnostics.contains(pairing.serviceName))
            XCTAssertFalse(failure.diagnostics.contains(pairing.secret.base64EncodedString()))
            return failure
        }
    }

    private func observeNameOnlyService(matching: Bool) async throws {
        let advertisedPairing = try NearbyPairing.generate()
        let senderPairing = matching ? advertisedPairing : try NearbyPairing.generate()
        let queue = DispatchQueue(label: "test.phonesnap.discovery.observer")
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: advertisedPairing.serviceName, type: NearbyPairing.serviceType)
        let ready = expectation(description: "synthetic listener ready")
        let observed = expectation(description: "name-only result with matching count")
        let resources = DiscoveryTestResources()
        listener.newConnectionHandler = { resources.accept($0) }
        listener.stateUpdateHandler = { state in
            if state == .ready { ready.fulfill() }
        }
        listener.start(queue: queue)
        defer {
            listener.cancel()
            resources.cancelConnections()
        }
        await fulfillment(of: [ready], timeout: 2)
        let sender = NearbySender(origin: .app) { _, text in
            guard let entry = text.split(separator: "\n").last,
                  entry.contains("discovery.name_only.local.results"),
                  let totalField = entry.split(separator: " ").first(where: { $0.hasPrefix("total=") }),
                  let total = Int(totalField.dropFirst("total=".count)), total > 0,
                  entry.contains(" matched=\(matching ? 1 : 0) ") else { return }
            resources.fulfillOnce(observed)
        }
        let transfer = Task { try await sender.send(Data([1]), pairing: senderPairing) }
        await fulfillment(of: [observed], timeout: 3)
        sender.cancel()
        do {
            _ = try await transfer.value
            XCTFail("An observation alone must not upload an image")
        } catch let failure as NearbyTransferFailure {
            XCTAssertFalse(failure.diagnostics.contains("payload.enqueue"))
            XCTAssertFalse(failure.diagnostics.contains(advertisedPairing.serviceName))
            XCTAssertFalse(failure.diagnostics.contains(senderPairing.serviceName))
            XCTAssertFalse(failure.diagnostics.contains(senderPairing.secret.base64EncodedString()))
        }
    }
}

private final class DiscoveryTestResources: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var fulfilled = false
    private var stopped = false

    func accept(_ connection: NWConnection) {
        lock.lock()
        if stopped {
            lock.unlock()
            connection.cancel()
        } else {
            connections.append(connection)
            lock.unlock()
        }
    }

    func fulfillOnce(_ expectation: XCTestExpectation) {
        lock.lock()
        let shouldFulfill = !fulfilled
        fulfilled = true
        lock.unlock()
        if shouldFulfill { expectation.fulfill() }
    }

    func cancelConnections() {
        lock.lock()
        stopped = true
        let active = connections
        connections.removeAll()
        lock.unlock()
        for connection in active { connection.cancel() }
    }
}
