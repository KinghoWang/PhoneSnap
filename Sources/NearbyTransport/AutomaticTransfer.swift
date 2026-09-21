import Foundation

public nonisolated enum AutomaticTransfer {
    public enum Route: Sendable { case direct, relay }

    public static func send(direct: @Sendable () async throws -> Bool,
                            relay: @Sendable () async throws -> Void) async throws -> Route {
        try Task.checkCancellation()
        let delivered = try await direct()
        try Task.checkCancellation()
        if delivered { return .direct }
        try await relay()
        return .relay
    }
}
