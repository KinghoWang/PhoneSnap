import XCTest
@testable import NearbyTransport

final class RelayIntegrationTests: XCTestCase {
    func testNativeEncryptionThroughRealLoopbackRelayAndSavedReceipt() async throws {
        try await runTransfer(binary: false)
    }

    func testBinaryEncryptionThroughRealLoopbackRelayAndSavedReceipt() async throws {
        try await runTransfer(binary: true)
    }

    private func runTransfer(binary: Bool) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let serverFile = root.appendingPathComponent("relay/server.mjs")
        let pairing = try RelayPairing.generate(baseURL: "https://snap.example.com")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--input-type=module", "-e", """
        import {createRelay} from '\(serverFile.absoluteString)';
        import {readFileSync} from 'node:fs';
        const server = createRelay(JSON.parse(readFileSync(0,'utf8')), {pollMS:20,uploadMS:3000});
        server.listen(0,'127.0.0.1',()=>console.log(server.address().port));
        setTimeout(()=>{server.closeAllConnections();server.close();},10000).unref();
        """]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        input.fileHandleForWriting.write(try pairing.serverConfiguration())
        try input.fileHandleForWriting.close()
        let line = String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        guard let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            XCTFail("loopback relay did not start")
            return
        }
        let base = "http://127.0.0.1:\(port)/v1/\(pairing.channel)"
        let diagnosticsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: diagnosticsDirectory) }
        let trace = RelayDiagnostics(origin: .shortcut, directory: diagnosticsDirectory)
        func request(_ path: String, token: String, body: Data? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: base + path)!)
            request.httpMethod = body == nil ? "GET" : "POST"
            request.httpBody = body
            request.timeoutInterval = 5
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if binary {
                request.setValue(RelayWire.contentType, forHTTPHeaderField: "Accept")
                if body != nil && !path.hasSuffix("/receipt") {
                    request.setValue(RelayWire.contentType, forHTTPHeaderField: "Content-Type")
                }
            }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request, delegate: RelayNoRedirect(trace: trace, operation: .send))
            if path == "/next", (response as! HTTPURLResponse).statusCode == 200 {
                XCTAssertEqual(response.mimeType, binary ? RelayWire.contentType : "application/json")
            }
            return ((response as! HTTPURLResponse).statusCode, data)
        }
        let online = try await request("/next", token: pairing.receiveToken!)
        XCTAssertEqual(online.0, 204)
        let image = Data("Synthetic test only, not a user screenshot".utf8)
        let envelope = try RelayCrypto.seal(image, pairing: pairing)
        let body = try binary ? RelayWire.encode(envelope) : JSONEncoder().encode(envelope)
        XCTAssertNil(body.range(of: image))
        let upload = Task { try await request("/transfers/\(envelope.transfer)", token: pairing.uploadToken, body: body) }
        var delivered: RelayEnvelope?
        for _ in 0..<20 {
            let next = try await request("/next", token: pairing.receiveToken!)
            if next.0 == 200 {
                delivered = try binary ? RelayWire.decode(next.1) : JSONDecoder().decode(RelayEnvelope.self, from: next.1)
                break
            }
        }
        let received = try XCTUnwrap(delivered)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipts = RelayReceiptStore(directory: folder.appendingPathComponent("receipts"))
        let receipt = try RelayDelivery.process(received, pairing: pairing, receipts: receipts) { bytes in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try bytes.write(to: folder.appendingPathComponent("synthetic.bin"), options: .atomic)
                return true
            } catch { return false }
        }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("synthetic.bin")), image)
        let ack = try await request("/transfers/\(envelope.transfer)/receipt", token: pairing.receiveToken!,
                                    body: JSONEncoder().encode(RelaySavedResponse(receipt: receipt)))
        XCTAssertEqual(ack.0, 200)
        let sent = try await upload.value
        XCTAssertEqual(sent.0, 200)
        let result = try JSONDecoder().decode(RelaySavedResponse.self, from: sent.1)
        XCTAssertNoThrow(try RelayCrypto.verify(result.receipt, envelope: envelope, image: image, pairing: pairing))
        XCTAssertTrue(trace.text.contains("serverWait operation=send"))
        XCTAssertTrue(trace.text.contains("download operation=send"))
        for secret in [pairing.secret, pairing.uploadToken, pairing.receiveToken!, base, "Synthetic test only"] {
            XCTAssertFalse(trace.text.contains(secret))
        }
    }
}
