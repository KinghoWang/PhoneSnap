import Foundation

struct UploadTimeout {
    private let startedAt: TimeInterval
    private var lastProgressAt: TimeInterval

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        self.lastProgressAt = startedAt
    }

    func remaining(at now: TimeInterval) -> TimeInterval {
        max(0, min(30 - (now - lastProgressAt), 120 - (now - startedAt)))
    }

    mutating func recordProgress(at now: TimeInterval) -> Bool {
        guard remaining(at: now) > 0 else { return false }
        lastProgressAt = now
        return true
    }
}
