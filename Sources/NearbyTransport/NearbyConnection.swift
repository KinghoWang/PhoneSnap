import Foundation
import Network
import OSLog

nonisolated final class NearbyConnection: @unchecked Sendable {
    let connection: NWConnection
    private var buffer = Data()

    init(_ connection: NWConnection) { self.connection = connection }

    func receive(count: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        buffer = Data()
        receiveRemaining(count: count, completion: completion)
    }

    private func receiveRemaining(count: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(count - buffer.count, 65536)) { [self] data, _, done, error in
            if let data { buffer.append(data) }
            if let error { completion(.failure(error)); return }
            if buffer.count == count { completion(.success(buffer)); return }
            if done { completion(.failure(NearbyError.disconnected)); return }
            receiveRemaining(count: count, completion: completion)
        }
    }
}

public nonisolated final class NearbyReceiver: @unchecked Sendable {
    private static let admissionLock = NSLock()
    private static var connectionCount = 0
    private static let logger = Logger(subsystem: "dev.phonesnap.nearby", category: "receive")
    private let queue = DispatchQueue(label: "dev.phonesnap.nearby.receiver")
    private var listener: NWListener?
    private var sessions: [UUID: NearbyConnection] = [:]
    private var deadlines: [UUID: DispatchWorkItem] = [:]
    private let pairing: NearbyPairing
    private let receive: (Data) -> Bool
    private let receiveWithContext: ((Data, TimeInterval, String) -> Bool)?
    private let state: (String) -> Void
    private let receipts: NearbyReceiptStore
    private var pendingOffers: [UUID: UUID] = [:]
    var replyDelivery: (NWConnection, Data, @escaping @Sendable (NWError?) -> Void) -> Void = { connection, data, completion in
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    public init(pairing: NearbyPairing, receive: @escaping (Data) -> Bool, state: @escaping (String) -> Void,
                receipts: NearbyReceiptStore = NearbyReceiptStore(),
                receiveWithContext: ((Data, TimeInterval, String) -> Bool)? = nil) {
        self.pairing = pairing
        self.receive = receive
        self.receiveWithContext = receiveWithContext
        self.state = state
        self.receipts = receipts
    }

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let listener = try NWListener(using: pairing.parameters())
                self.listener = listener
                listener.service = NWListener.Service(name: pairing.serviceName, type: NearbyPairing.serviceType, txtRecord: NWTXTRecord(["psn": "2"]))
                listener.stateUpdateHandler = { [weak self, weak listener] status in
                    guard let self, let listener, self.listener === listener else { return }
                    switch status {
                    case .ready: state("附近接收：等待 iPhone（不代表已连接）")
                    case .failed: state("附近接收：启动失败，请关闭后重试"); stop()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self, weak listener] connection in
                    guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                    self.accept(connection)
                }
                listener.start(queue: queue)
            } catch { state("附近接收：启动失败") }
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            for identifier in Array(sessions.keys) { finish(identifier) }
        }
    }

    private func finish(_ identifier: UUID) {
        deadlines.removeValue(forKey: identifier)?.cancel()
        let session = sessions.removeValue(forKey: identifier)
        pendingOffers = pendingOffers.filter { $0.value != identifier }
        if session != nil {
            Self.admissionLock.lock()
            Self.connectionCount -= 1
            Self.admissionLock.unlock()
        }
        session?.connection.stateUpdateHandler = nil
        session?.connection.cancel()
    }

    private func accept(_ connection: NWConnection) {
        Self.admissionLock.lock()
        let admitted = Self.connectionCount < 2
        if admitted { Self.connectionCount += 1 }
        Self.admissionLock.unlock()
        guard admitted else { connection.cancel(); return }
        let identifier = UUID()
        let session = NearbyConnection(connection)
        sessions[identifier] = session
        let deadline = DispatchWorkItem { [weak self] in self?.finish(identifier) }
        deadlines[identifier] = deadline
        queue.asyncAfter(deadline: .now() + 45, execute: deadline)
        connection.stateUpdateHandler = { [weak self] status in
            guard let self else { return }
            switch status {
            case .ready:
                session.receive(count: 8) { result in
                    guard self.sessions[identifier] != nil else { return }
                    guard let header = try? result.get() else { self.finish(identifier); return }
                    if header.prefix(4) == Data("PSN2".utf8) {
                        session.receive(count: 68) { result in
                            guard self.sessions[identifier] != nil else { return }
                            guard let metadata = try? result.get(), let offer = try? NearbyOffer.decode(header + metadata) else {
                                self.finish(identifier); return
                            }
                            self.acceptOffer(offer, session: session, identifier: identifier)
                        }
                        return
                    }
                    guard let count = try? NearbyFrame.decodeHeader(header) else {
                        self.finish(identifier); return
                    }
                    let started = ProcessInfo.processInfo.systemUptime
                    session.receive(count: count) { result in
                        guard self.sessions[identifier] != nil else { return }
                        guard let data = try? result.get() else { self.finish(identifier); return }
                        let accepted = self.save(data, session: session, started: started)
                        connection.send(content: Data([accepted ? 1 : 0]), completion: .contentProcessed { _ in
                            self.finish(identifier)
                        })
                    }
                }
            case .failed, .cancelled: finish(identifier)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func acceptOffer(_ offer: NearbyOffer, session: NearbyConnection, identifier: UUID) {
        var status = (try? receipts.status(offer)) ?? .uncertain
        if status == .needed, pendingOffers[offer.identifier] != nil { status = .uncertain }
        if status == .needed { pendingOffers[offer.identifier] = identifier }
        reply(status, offer: offer, session: session, identifier: identifier) {
            let started = ProcessInfo.processInfo.systemUptime
            session.receive(count: offer.byteCount) { result in
                guard self.sessions[identifier] != nil else { return }
                guard let data = try? result.get() else { self.finish(identifier); return }
                guard offer.matches(data) else {
                    self.reply(.conflict, offer: offer, session: session, identifier: identifier); return
                }
                do {
                    let reservation = try self.receipts.reserve(offer)
                    guard reservation == .needed else {
                        self.reply(reservation, offer: offer, session: session, identifier: identifier); return
                    }
                    let saved = self.save(data, session: session, started: started)
                    try self.receipts.complete(offer, saved: saved)
                    self.reply(saved ? .saved : .rejected, offer: offer, session: session, identifier: identifier)
                } catch {
                    self.reply(.uncertain, offer: offer, session: session, identifier: identifier)
                }
            }
        }
    }

    private func save(_ data: Data, session: NearbyConnection, started: TimeInterval) -> Bool {
        let path = NearbyPathEvidence.inspect(session.connection.currentPath, ready: true, peerAllowed: true).title
        return receiveWithContext?(data, started, path) ?? receive(data)
    }

    private func reply(_ receipt: NearbyReceipt, offer: NearbyOffer, session: NearbyConnection,
                       identifier: UUID, upload: (@Sendable () -> Void)? = nil) {
        let transfer = offer.identifier.uuidString
        let status = receipt.rawValue
        let path = NearbyPathEvidence.inspect(session.connection.currentPath, ready: true, peerAllowed: true).title
        Self.logger.notice("transfer=\(transfer, privacy: .public) receipt=\(status, privacy: .public) path=\(path, privacy: .public)")
        replyDelivery(session.connection, receipt.encode(offer.identifier)) { error in
            guard self.sessions[identifier] != nil else { return }
            if error == nil, receipt == .needed { upload?() }
            else { self.finish(identifier) }
        }
    }
}

nonisolated enum NearbyRouteChoice: Equatable {
    case local, nearby

    static func select(local: Bool, nearby: Bool, preferenceWindowPassed: Bool) -> Self? {
        if local { return .local }
        return nearby && preferenceWindowPassed ? .nearby : nil
    }

    static func shouldFallback(selected: Self?, localUnusable: Bool, nearbyAvailable: Bool, sending: Bool) -> Bool {
        selected == .local && localUnusable && nearbyAvailable && !sending
    }
}

public nonisolated struct NearbyTransferFailure: LocalizedError, Sendable {
    public let reason: String
    public let details: String
    public let diagnostics: String
    public var errorDescription: String? { reason }
}

public nonisolated struct NearbyTransferReport: Sendable {
    public let discoverySeconds: Double
    public let connectionSeconds: Double
    public let deliverySeconds: Double
    public let route: String
    public let path: String
    public let diagnostics: String
    public var totalSeconds: Double { discoverySeconds + connectionSeconds + deliverySeconds }
}

public nonisolated final class NearbySender: @unchecked Sendable {
    private enum PreflightError: Error { case unavailable }
    private let queue = DispatchQueue(label: "dev.phonesnap.nearby.sender")
    private var browser: NWBrowser?
    private var localBrowser: NWBrowser?
    private var comparisonBrowsers: [String: NWBrowser] = [:]
    private var discoveryObservations: [String: (updates: Int, total: Int, matched: Int)] = [:]
    private var selectionDeadline: DispatchWorkItem?
    private var localCandidate: NWEndpoint?
    private var nearbyCandidate: NWEndpoint?
    private var localSupportsReceipts = false
    private var nearbySupportsReceipts = false
    private var usingReceipts = false
    private var recoveryCount = 0
    private var offer: NearbyOffer?
    private var preferenceWindowPassed = false
    private var discoveryStarted = ContinuousClock.now
    private var connectionStarted = ContinuousClock.now
    private var connectionReady = ContinuousClock.now
    private var route = "尚未选路"
    private var path = "实际通路未确认"
    private var selectedRoute: NearbyRouteChoice?
    private var localUnusable = false
    private var sending = false
    private var connectionAttempted = false
    private var phase = "发现 Mac"
    private var phaseStarted = ContinuousClock.now
    private var localDiscoveryState = "尚未启动"
    private var nearbyDiscoveryState = "尚未启动"
    private var connectionState = "尚未连接"
    private var fallbackReason = ""
    private var failureDetails = ""
    private var diagnostics = NearbyDiagnostics()
    private var connectionNumber = 0
    private let origin: NearbySendOrigin
    private let onDiagnostic: (@Sendable (String, String) -> Void)?
    private let timeout: TimeInterval
    private let makeConnection: (NWEndpoint, NWParameters) -> NWConnection
    private var session: NearbyConnection?
    private var deadline: DispatchWorkItem?
    private var preflightDeadline: DispatchWorkItem?
    private var directCommitted = false
    private var receiptDeadline: DispatchWorkItem?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var cancelled = false
    private var started = false

    public init(origin: NearbySendOrigin = .unspecified, onDiagnostic: (@Sendable (String, String) -> Void)? = nil) {
        timeout = 35
        makeConnection = { NWConnection(to: $0, using: $1) }
        self.onDiagnostic = onDiagnostic
        self.origin = origin
    }

    init(timeout: TimeInterval, makeConnection: @escaping (NWEndpoint, NWParameters) -> NWConnection = { NWConnection(to: $0, using: $1) }) {
        self.timeout = timeout
        self.makeConnection = makeConnection
        onDiagnostic = nil
        origin = .unspecified
    }

    @discardableResult
    public func send(_ data: Data, pairing: NearbyPairing, transferID: UUID = UUID()) async throws -> NearbyTransferReport {
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NearbyTransferReport, Error>) in
                begin(data, pairing: pairing, transferID: transferID) { result in
                    switch result {
                    case .success: continuation.resume(returning: self.report())
                    case .failure(let error):
                        continuation.resume(throwing: NearbyTransferFailure(reason: error.localizedDescription, details: self.failureDetails, diagnostics: self.diagnostics.text))
                    }
                }
            }
        }, onCancel: { self.cancel() })
    }

    public func sendIfAvailable(_ data: Data, pairing: NearbyPairing, transferID: UUID = UUID(),
                                availabilityWindow: TimeInterval = 3) async throws -> NearbyTransferReport? {
        guard availabilityWindow.isFinite, availabilityWindow > 0, availabilityWindow < timeout else { throw NearbyError.invalidFrame }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NearbyTransferReport?, Error>) in
                begin(data, pairing: pairing, transferID: transferID, availabilityWindow: availabilityWindow) { result in
                    switch result {
                    case .success: continuation.resume(returning: self.report())
                    case .failure(PreflightError.unavailable): continuation.resume(returning: nil)
                    case .failure(let error):
                        continuation.resume(throwing: NearbyTransferFailure(reason: error.localizedDescription, details: self.failureDetails, diagnostics: self.diagnostics.text))
                    }
                }
            }
        }, onCancel: { self.cancel() })
    }

    func begin(_ data: Data, pairing: NearbyPairing, endpoint: NWEndpoint? = nil,
               transferID: UUID = UUID(),
               availabilityWindow: TimeInterval? = nil,
               completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            guard !started else { completion(.failure(NearbyError.rejected)); return }
            started = true
            discoveryStarted = .now
            phaseStarted = discoveryStarted
            self.completion = completion
            diagnostics = NearbyDiagnostics(identifier: transferID)
            record("transfer.begin origin=\(origin.rawValue) bytes=\(data.count) timeout=\(timeout)s")
            guard !cancelled else { finish(.failure(NearbyError.cancelled)); return }
            guard let header = try? NearbyFrame.header(byteCount: data.count) else {
                finish(.failure(NearbyError.invalidFrame)); return
            }
            offer = try? NearbyOffer(identifier: transferID, data: data)
            let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(NearbyError.timeout)) }
            self.deadline = deadline
            queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
            if let availabilityWindow {
                record("preflight.begin window=\(availabilityWindow)s image_sent=false")
                let preflight = DispatchWorkItem { [weak self] in
                    guard let self, !self.directCommitted, self.completion != nil else { return }
                    self.record("preflight.unavailable image_sent=false")
                    self.finish(.failure(PreflightError.unavailable))
                }
                preflightDeadline = preflight
                queue.asyncAfter(deadline: .now() + availabilityWindow, execute: preflight)
            }
            let payload = header + data
            if let endpoint { route = "指定端点"; connect(endpoint, pairing: pairing, payload: payload); return }
            startDiscovery(pairing: pairing, payload: payload)
        }
    }

    private func startDiscovery(pairing: NearbyPairing, payload: Data) {
        preferenceWindowPassed = false
        localSupportsReceipts = false
        nearbySupportsReceipts = false
        for local in [true, false] {
            let observationLabel = "txt." + (local ? "local" : "nearby")
            discoveryObservations[observationLabel] = (0, 0, 0)
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = !local
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: NearbyPairing.serviceType, domain: nil), using: parameters)
            if local { localBrowser = browser } else { self.browser = browser }
            browser.stateUpdateHandler = { [weak self, weak browser] status in
                guard let self, let browser, self.completion != nil,
                      (local ? self.localBrowser : self.browser) === browser else { return }
                let description: String
                switch status {
                case .ready: description = "正在发现"
                case .waiting(let error): description = "等待 " + Self.errorCode(error)
                case .failed(let error): description = "失败 " + Self.errorCode(error)
                case .cancelled: description = "已停止"
                default: description = "启动中"
                }
                if local { self.localDiscoveryState = description } else { self.nearbyDiscoveryState = description }
                self.record("discovery.\(local ? "local" : "nearby").state \(description)")
                if case .failed(let error) = status {
                    if local { self.localCandidate = nil } else { self.nearbyCandidate = nil }
                    if local, self.selectedRoute == .local {
                        self.localUnusable = true
                        self.fallbackReason = "局域网发现失败"
                    }
                    self.selectRoute(pairing: pairing, payload: payload)
                    if case .failed = self.localBrowser?.state,
                       case .failed = self.browser?.state, self.session == nil { self.finish(.failure(error)) }
                }
            }
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                guard let self, self.completion != nil else { return }
                guard let browser, (local ? self.localBrowser : self.browser) === browser else {
                    self.record("discovery.\(observationLabel).ignored reason=stale_browser total=\(results.count)")
                    return
                }
                guard !self.sending else {
                    self.record("discovery.\(observationLabel).ignored reason=sending total=\(results.count)")
                    return
                }
                let candidateResult = self.recordDiscoveryResults(results, pairing: pairing, label: observationLabel)
                let candidate = candidateResult?.endpoint
                var supportsReceipts = false
                if case .bonjour(let record) = candidateResult?.metadata { supportsReceipts = record["psn"] == "2" }
                if local { self.localSupportsReceipts = supportsReceipts } else { self.nearbySupportsReceipts = supportsReceipts }
                let interfaces = candidateResult?.interfaces.map { $0.name }.sorted().joined(separator: ",") ?? "none"
                self.record("discovery.\(local ? "local" : "nearby").candidate present=\(candidate != nil) candidate_interfaces=\(interfaces)")
                if local { self.localCandidate = candidate } else { self.nearbyCandidate = candidate }
                if !local, candidate != nil, self.localCandidate == nil {
                    self.startPreferenceWindow(pairing: pairing, payload: payload)
                }
                if local, candidate == nil, self.selectedRoute == .local {
                    self.localUnusable = true
                    self.fallbackReason = "局域网候选已消失"
                }
                self.selectRoute(pairing: pairing, payload: payload)
            }
            browser.start(queue: queue)
        }
        if origin == .app { startNameOnlyComparison(pairing: pairing) }
    }

    private func startNameOnlyComparison(pairing: NearbyPairing) {
        for local in [true, false] {
            let label = "name_only." + (local ? "local" : "nearby")
            discoveryObservations[label] = (0, 0, 0)
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = !local
            let probe = NWBrowser(for: .bonjour(type: NearbyPairing.serviceType, domain: nil), using: parameters)
            comparisonBrowsers[label] = probe
            record("discovery.\(label).start observing_only=true peer_allowed=\(!local)")
            probe.stateUpdateHandler = { [weak self, weak probe] status in
                guard let self, let probe, self.completion != nil,
                      self.comparisonBrowsers[label] === probe else { return }
                let description: String
                switch status {
                case .ready: description = "ready"
                case .waiting(let error): description = "waiting " + Self.errorCode(error)
                case .failed(let error): description = "failed " + Self.errorCode(error)
                case .cancelled: description = "cancelled"
                default: description = "starting"
                }
                self.record("discovery.\(label).state \(description)")
            }
            probe.browseResultsChangedHandler = { [weak self, weak probe] results, _ in
                guard let self, let probe, self.completion != nil,
                      self.comparisonBrowsers[label] === probe else { return }
                _ = self.recordDiscoveryResults(results, pairing: pairing, label: label)
            }
            probe.start(queue: queue)
        }
    }

    private func recordDiscoveryResults(_ results: Set<NWBrowser.Result>, pairing: NearbyPairing,
                                        label: String) -> NWBrowser.Result? {
        let matches = results.filter { result in
            if case .service(let name, _, _, _) = result.endpoint { return name == pairing.serviceName }
            return false
        }
        let interfaces = Set(matches.flatMap { $0.interfaces.map { $0.name } }).sorted().joined(separator: ",")
        let updates = (discoveryObservations[label]?.updates ?? 0) + 1
        discoveryObservations[label] = (updates, results.count, matches.count)
        record("discovery.\(label).results updates=\(updates) total=\(results.count) matched=\(matches.count) candidate_interfaces=\(interfaces.isEmpty ? "none" : interfaces)")
        return results.first(where: matches.contains)
    }

    private func recordDiscoverySummary() {
        guard !discoveryObservations.isEmpty else { return }
        let summary = discoveryObservations.keys.sorted().compactMap { label -> String? in
            guard let value = discoveryObservations[label] else { return nil }
            return "\(label){updates=\(value.updates),total=\(value.total),matched=\(value.matched)}"
        }.joined(separator: " ")
        discoveryObservations.removeAll()
        record("discovery.summary counts=latest \(summary)")
    }

    private func startPreferenceWindow(pairing: NearbyPairing, payload: Data) {
        guard selectionDeadline == nil, !preferenceWindowPassed else { return }
        record("route.preference_window first_nearby_candidate=true duration=0.2s")
        let selection = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.preferenceWindowPassed = true
            self.selectRoute(pairing: pairing, payload: payload)
        }
        selectionDeadline = selection
        queue.asyncAfter(deadline: .now() + 0.2, execute: selection)
    }

    private func selectRoute(pairing: NearbyPairing, payload: Data) {
        guard !sending, completion != nil else { return }
        if NearbyRouteChoice.shouldFallback(selected: selectedRoute, localUnusable: localUnusable,
                                           nearbyAvailable: nearbyCandidate != nil, sending: sending),
           let endpoint = nearbyCandidate {
            session?.connection.stateUpdateHandler = nil
            session?.connection.pathUpdateHandler = nil
            session?.connection.cancel()
            session = nil
            selectedRoute = .nearby
            usingReceipts = nearbySupportsReceipts
            route = "附近发现（发送前重选，允许点对点）"
            record("route.reselect reason=\(fallbackReason) sending=false")
            connect(endpoint, pairing: pairing, payload: payload)
            return
        }
        guard session == nil, completion != nil,
              let choice = NearbyRouteChoice.select(local: localCandidate != nil, nearby: nearbyCandidate != nil,
                                                     preferenceWindowPassed: preferenceWindowPassed) else { return }
        let endpoint = choice == .local ? localCandidate : nearbyCandidate
        guard let endpoint else { return }
        selectedRoute = choice
        usingReceipts = choice == .local ? localSupportsReceipts : nearbySupportsReceipts
        route = choice == .local ? "局域网（含已连接热点）" : "附近发现（允许点对点）"
        record("route.selected \(route)")
        connect(endpoint, pairing: pairing, payload: payload, includePeerToPeer: choice != .local)
    }

    public func cancel() {
        queue.async { [self] in cancelled = true; finish(.failure(NearbyError.cancelled)) }
    }

    private func connect(_ endpoint: NWEndpoint, pairing: NearbyPairing, payload: Data, includePeerToPeer: Bool = true) {
        if !connectionAttempted { connectionStarted = .now; connectionAttempted = true }
        setPhase("建立连接")
        connectionState = "准备连接"
        connectionNumber += 1
        record("connection.start attempt=\(connectionNumber) peer_allowed=\(includePeerToPeer)")
        let parameters = pairing.parameters()
        parameters.includePeerToPeer = includePeerToPeer
        let connection = makeConnection(endpoint, parameters)
        let session = NearbyConnection(connection)
        self.session = session
        connection.pathUpdateHandler = { [weak self, weak session] path in
            guard let self, let session, self.session === session, self.completion != nil else { return }
            self.record("connection.path attempt=\(self.connectionNumber) " + Self.describePath(path))
            if connection.state == .ready {
                self.path = NearbyPathEvidence.inspect(path, ready: true, peerAllowed: includePeerToPeer).title
                self.record("connection.actual_path \(self.path)")
            }
        }
        connection.stateUpdateHandler = { [weak self] status in
            guard let self, self.completion != nil, self.session === session else { return }
            switch status {
            case .ready:
                guard !self.sending else { return }
                self.directCommitted = true
                if self.preflightDeadline != nil {
                    self.preflightDeadline?.cancel()
                    self.preflightDeadline = nil
                    self.record("preflight.direct_committed relay_fallback_allowed=false")
                }
                self.sending = true
                self.stopBrowsing()
                self.connectionState = "已连接"
                self.record("connection.ready attempt=\(self.connectionNumber) " + Self.describePath(connection.currentPath))
                if self.recoveryCount == 0 { self.connectionReady = .now }
                self.path = NearbyPathEvidence.inspect(connection.currentPath, ready: true, peerAllowed: includePeerToPeer).title
                self.record("connection.actual_path \(self.path)")
                self.record("protocol.selected v=\(self.usingReceipts ? 2 : 1)")
                guard self.recoveryCount == 0 || self.usingReceipts else {
                    self.finish(.failure(NearbyError.receiptUncertain)); return
                }
                if self.usingReceipts {
                    self.checkReceipt(session, pairing: pairing, payload: payload)
                    return
                }
                self.setPhase("发送图片")
                self.record("payload.enqueue bytes=\(payload.count - 8)")
                connection.send(content: payload, completion: .contentProcessed { error in
                    guard self.completion != nil, self.session === session else { return }
                    if let error { self.record("payload.error " + Self.errorCode(error)); self.finish(.failure(error)); return }
                    self.record("payload.processed local_stack_only=true")
                    self.setPhase("等待 Mac 保存确认")
                    session.receive(count: 1) { result in
                        switch result {
                        case .success(let reply):
                            self.record(reply == Data([1]) ? "receipt.accepted Mac_saved=true" : "receipt.rejected Mac_saved=false")
                            self.finish(reply == Data([1]) ? .success(()) : .failure(NearbyError.rejected))
                        case .failure(let error): self.finish(.failure(error))
                        }
                    }
                })
            case .waiting(let error):
                self.connectionState = "等待网络路径 " + Self.errorCode(error)
                self.record("connection.waiting attempt=\(self.connectionNumber) " + Self.errorCode(error) + " " + Self.describePath(connection.currentPath))
                if self.selectedRoute == .local, !self.sending {
                    self.localUnusable = true
                    self.fallbackReason = self.connectionState
                    self.selectRoute(pairing: pairing, payload: payload)
                } else if self.sending, self.usingReceipts {
                    self.recoverOrFinish(error, session: session, pairing: pairing, payload: payload)
                }
            case .preparing:
                self.connectionState = "建立连接中"
                self.record("connection.preparing attempt=\(self.connectionNumber) " + Self.describePath(connection.currentPath))
                if self.selectedRoute == .local { self.localUnusable = self.localCandidate == nil }
            case .failed(let error):
                self.connectionState = "连接失败 " + Self.errorCode(error)
                self.record("connection.failed attempt=\(self.connectionNumber) " + Self.errorCode(error))
                if self.selectedRoute == .local, !self.sending {
                    self.localUnusable = true
                    self.fallbackReason = self.connectionState
                    self.selectRoute(pairing: pairing, payload: payload)
                } else { self.recoverOrFinish(error, session: session, pairing: pairing, payload: payload) }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func checkReceipt(_ session: NearbyConnection, pairing: NearbyPairing, payload: Data) {
        guard let offer else { finish(.failure(NearbyError.invalidFrame)); return }
        setPhase("核对 Mac 收件状态")
        record("receipt.query recovery=\(recoveryCount)")
        session.connection.send(content: offer.encoded, completion: .contentProcessed { error in
            guard self.completion != nil, self.session === session else { return }
            if let error { self.recoverOrFinish(error, session: session, pairing: pairing, payload: payload); return }
            self.readReceipt(session, offer: offer, pairing: pairing, payload: payload, canUpload: true)
        })
    }

    private func readReceipt(_ session: NearbyConnection, offer: NearbyOffer, pairing: NearbyPairing,
                             payload: Data, canUpload: Bool) {
        session.receive(count: 37) { result in
            guard self.completion != nil, self.session === session else { return }
            switch result {
            case .failure(let error): self.recoverOrFinish(error, session: session, pairing: pairing, payload: payload)
            case .success(let data):
                self.receiptDeadline?.cancel(); self.receiptDeadline = nil
                guard let receipt = try? NearbyReceipt.decode(data, expected: offer.identifier) else {
                    self.finish(.failure(NearbyError.invalidReceipt)); return
                }
                switch receipt {
                case .saved:
                    self.record("receipt.accepted Mac_saved=true already_saved=\(canUpload)")
                    self.finish(.success(()))
                case .needed where canUpload:
                    self.setPhase("发送图片")
                    self.record("payload.enqueue bytes=\(offer.byteCount)")
                    session.connection.send(content: Data(payload.dropFirst(8)), completion: .contentProcessed { error in
                        guard self.completion != nil, self.session === session else { return }
                        if let error { self.recoverOrFinish(error, session: session, pairing: pairing, payload: payload); return }
                        self.record("payload.processed local_stack_only=true")
                        self.setPhase("等待 Mac 保存确认")
                        let receiptDeadline = DispatchWorkItem { [weak self, weak session] in
                            guard let self, let session, self.completion != nil, self.session === session else { return }
                            self.record("receipt.wait_timeout checking_saved_state=true")
                            self.recoverOrFinish(NearbyError.timeout, session: session, pairing: pairing, payload: payload)
                        }
                        self.receiptDeadline = receiptDeadline
                        self.queue.asyncAfter(deadline: .now() + min(5, self.timeout / 3), execute: receiptDeadline)
                        self.readReceipt(session, offer: offer, pairing: pairing, payload: payload, canUpload: false)
                    })
                case .uncertain: self.finish(.failure(NearbyError.receiptUncertain))
                case .rejected:
                    self.record("receipt.rejected Mac_saved=false")
                    self.finish(.failure(NearbyError.rejected))
                default: self.finish(.failure(NearbyError.invalidReceipt))
                }
            }
        }
    }

    private func recoverOrFinish(_ error: Error, session: NearbyConnection, pairing: NearbyPairing, payload: Data) {
        guard completion != nil, self.session === session else { return }
        guard usingReceipts, sending, recoveryCount == 0, !cancelled else { finish(.failure(error)); return }
        recoveryCount += 1
        receiptDeadline?.cancel(); receiptDeadline = nil
        record("recovery.query attempt=1 same_transfer=true no_blind_resend=true")
        session.connection.stateUpdateHandler = nil
        session.connection.pathUpdateHandler = nil
        session.connection.cancel()
        self.session = nil
        stopBrowsing()
        selectedRoute = nil
        localUnusable = false
        sending = false
        usingReceipts = false
        path = "实际通路未确认"
        route = "重新发现（尚未选路）"
        connectionState = "尚未重新连接"
        setPhase("重新发现 Mac 并核对收件状态")
        startDiscovery(pairing: pairing, payload: payload)
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let callback = completion else { return }
        preflightDeadline?.cancel(); preflightDeadline = nil
        receiptDeadline?.cancel(); receiptDeadline = nil
        recordDiscoverySummary()
        switch result {
        case .success: record("finish.success phase=\(phase) sending=\(sending)")
        case .failure(PreflightError.unavailable): record("preflight.finished available=false image_sent=false")
        case .failure(let error):
            let reason = (error as? NWError).map(Self.errorCode) ?? ((error as? NearbyError)?.localizedDescription ?? "未分类错误")
            record("finish.failure phase=\(phase) sending=\(sending) reason=\(reason)")
        }
        if case .failure = result { failureDetails = diagnosticText() }
        completion = nil
        deadline?.cancel(); deadline = nil
        stopBrowsing()
        session?.connection.stateUpdateHandler = nil
        session?.connection.pathUpdateHandler = nil
        session?.connection.cancel(); session = nil
        callback(result)
    }

    private func stopBrowsing() {
        recordDiscoverySummary()
        if sending {
            localDiscoveryState = "已停止（连接就绪）"
            nearbyDiscoveryState = "已停止（连接就绪）"
        }
        selectionDeadline?.cancel(); selectionDeadline = nil
        for browser in [localBrowser, browser].compactMap({ $0 }) + Array(comparisonBrowsers.values) {
            browser.stateUpdateHandler = nil
            browser.browseResultsChangedHandler = nil
            browser.cancel()
        }
        localBrowser = nil; browser = nil
        comparisonBrowsers.removeAll()
        localCandidate = nil; nearbyCandidate = nil
    }

    private func report() -> NearbyTransferReport {
        func seconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: end)
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        return NearbyTransferReport(discoverySeconds: seconds(discoveryStarted, connectionStarted),
                                    connectionSeconds: seconds(connectionStarted, connectionReady),
                                    deliverySeconds: seconds(connectionReady, .now), route: route, path: path, diagnostics: diagnostics.text)
    }

    private func setPhase(_ value: String) {
        phase = value
        phaseStarted = .now
        record("phase=\(value)")
    }

    private func record(_ event: String) {
        diagnostics.append(event)
        onDiagnostic?(phase, diagnostics.text)
    }

    private static func describePath(_ path: NWPath?) -> String {
        guard let path else { return "path=unknown" }
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .requiresConnection: status = "requires_connection"
        case .unsatisfied: status = "unsatisfied"
        @unknown default: status = "unknown"
        }
        let types: [(NWInterface.InterfaceType, String)] = [(.wifi, "wifi"), (.wiredEthernet, "wired"), (.cellular, "cellular"), (.loopback, "loopback"), (.other, "other")]
        let used = types.filter { path.usesInterfaceType($0.0) }.map { $0.1 }.joined(separator: ",")
        let reason: String
        switch path.unsatisfiedReason {
        case .notAvailable: reason = "not_available"
        case .cellularDenied: reason = "cellular_denied"
        case .wifiDenied: reason = "wifi_denied"
        case .localNetworkDenied: reason = "local_network_denied"
        @unknown default: reason = "unknown"
        }
        return "path=\(status) used_types=\(used) unsatisfied_reason=\(status == "unsatisfied" ? reason : "n/a") expensive=\(path.isExpensive) constrained=\(path.isConstrained) ipv4=\(path.supportsIPv4) ipv6=\(path.supportsIPv6)"
    }

    private func diagnosticText() -> String {
        func seconds(since start: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: .now)
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let progress = sending
            ? (usingReceipts ? "已进入收件核对；Mac 未明确请求图片时不自动重发" : "旧协议已开始发送，收件未确认时不自动重发")
            : (recoveryCount > 0 ? "先核对同一发送编号，不盲目重发" : "尚未发送图片")
        return String(format: "阶段：%@（本阶段 %.1f 秒，总计 %.1f 秒）", phase, seconds(since: phaseStarted), seconds(since: discoveryStarted))
            + "\n选路：" + route + "\n接口：" + path
            + "\n局域网发现：" + localDiscoveryState + (localCandidate == nil ? "；无候选" : "；有候选")
            + "\n附近发现：" + nearbyDiscoveryState + (nearbyCandidate == nil ? "；无候选" : "；有候选")
            + "\n连接：" + connectionState
            + (fallbackReason.isEmpty ? "" : "\n重选原因：" + fallbackReason)
            + "\n" + progress
    }

    private static func errorCode(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "POSIX " + String(code.rawValue)
        case .dns(let code): return "DNS " + String(code)
        case .tls(let code): return "TLS " + String(code)
        @unknown default: return "未知网络错误"
        }
    }
}
