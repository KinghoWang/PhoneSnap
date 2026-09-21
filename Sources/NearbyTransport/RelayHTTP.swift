import Foundation

public nonisolated struct RelaySavedResponse: Codable, Sendable {
    public let receipt: String
    public init(receipt: String) { self.receipt = receipt }
}

nonisolated final class RelayNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let trace: RelayDiagnostics?
    let operation: RelayDiagnostics.Operation

    init(trace: RelayDiagnostics?, operation: RelayDiagnostics.Operation) {
        self.trace = trace
        self.operation = operation
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        for transaction in metrics.transactionMetrics {
            let phases: [(RelayDiagnostics.Event, Date?, Date?)] = [
                (.dns, transaction.domainLookupStartDate, transaction.domainLookupEndDate),
                (.connection, transaction.connectStartDate, transaction.connectEndDate),
                (.tls, transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
                (.upload, transaction.requestStartDate, transaction.requestEndDate),
                (.serverWait, transaction.requestEndDate, transaction.responseStartDate),
                (.download, transaction.responseStartDate, transaction.responseEndDate)
            ]
            for (event, start, end) in phases {
                if let start, let end { trace?.record(event, operation: operation, milliseconds: end.timeIntervalSince(start) * 1000) }
            }
            if transaction.isReusedConnection { trace?.record(.reusedConnection, operation: operation) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public nonisolated enum RelayHTTP {
    public static func request(pairing: RelayPairing, path: String, token: String,
                               body: Data? = nil, limit: Int = 8192,
                               trace: RelayDiagnostics? = nil, operation: RelayDiagnostics.Operation = .send,
                               contentType: String = "application/json") async throws -> (Int, Data, String?) {
        try pairing.validate()
        guard path.hasPrefix("/"), !path.contains("?"), !path.contains("#"),
              let url = URL(string: pairing.baseURL + "/v1/" + pairing.channel + path) else {
            throw RelayError.invalidPairing
        }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(RelayWire.contentType), application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        request.timeoutInterval = 70
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForResource = 75
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        trace?.record(.requestBegin, operation: operation, bytes: body?.count)
        let (bytes, response) = try await session.bytes(for: request, delegate: RelayNoRedirect(trace: trace, operation: operation))
        guard let http = response as? HTTPURLResponse,
              response.expectedContentLength <= Int64(limit) else { throw RelayError.tooLarge }
        var data = Data()
        trace?.record(.responseHeaders, operation: operation, status: http.statusCode)
        data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < limit else { throw RelayError.tooLarge }
            data.append(byte)
        }
        trace?.record(.responseBody, operation: operation, bytes: data.count)
        return (http.statusCode, data, http.mimeType)
    }

    public static func send(_ image: Data, pairing: RelayPairing, trace: RelayDiagnostics? = nil) async throws -> String {
        trace?.record(.encryptBegin, bytes: image.count)
        let envelope = try RelayCrypto.seal(image, pairing: pairing, transfer: trace?.transfer ?? UUID().uuidString.lowercased())
        trace?.record(.encryptEnd)
        let body = try RelayWire.encode(envelope)
        trace?.record(.wireBinary, bytes: body.count)
        trace?.record(.encodeEnd, bytes: body.count)
        let (status, data, _) = try await request(pairing: pairing, path: "/transfers/\(envelope.transfer)",
                                             token: pairing.uploadToken, body: body, trace: trace, contentType: RelayWire.contentType)
        guard status == 200 else { throw RelayError.http(status) }
        let response = try JSONDecoder().decode(RelaySavedResponse.self, from: data)
        try RelayCrypto.verify(response.receipt, envelope: envelope, image: image, pairing: pairing)
        trace?.record(.receiptVerified)
        return envelope.transfer
    }

    public static func next(pairing: RelayPairing, trace: RelayDiagnostics? = nil) async throws -> RelayEnvelope? {
        guard let token = pairing.receiveToken else { throw RelayError.invalidPairing }
        let (status, data, contentType) = try await request(pairing: pairing, path: "/next", token: token, limit: RelayCrypto.maxWireBytes, trace: trace, operation: .poll)
        if status == 204 { return nil }
        guard status == 200 else { throw RelayError.http(status) }
        let envelope: RelayEnvelope
        switch contentType {
        case RelayWire.contentType: envelope = try RelayWire.decode(data)
        case "application/json": envelope = try JSONDecoder().decode(RelayEnvelope.self, from: data)
        default: throw RelayError.invalidEnvelope
        }
        trace?.activate(transfer: envelope.transfer)
        trace?.record(contentType == RelayWire.contentType ? .wireBinary : .wireJSON, bytes: data.count)
        trace?.record(.envelopeDecoded)
        return envelope
    }

    public static func acknowledge(_ envelope: RelayEnvelope, receipt: String, pairing: RelayPairing, trace: RelayDiagnostics? = nil) async throws {
        guard let token = pairing.receiveToken else { throw RelayError.invalidPairing }
        let body = try JSONEncoder().encode(RelaySavedResponse(receipt: receipt))
        let (status, _, _) = try await request(pairing: pairing, path: "/transfers/\(envelope.transfer)/receipt", token: token, body: body, trace: trace, operation: .ack)
        guard status == 200 else { throw RelayError.http(status) }
    }
}
