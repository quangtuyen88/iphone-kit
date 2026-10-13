import Foundation

enum AccessibilityJournal {
    /// A failed disk write must not create an in-memory shortcut around the next write attempt.
    static func recording(phoneID: String, original: Bool, values: [String: Bool],
                          persist: ([String: Bool]) throws -> Void) throws -> [String: Bool] {
        var updated = values
        if updated[phoneID] == nil { updated[phoneID] = original }
        try persist(updated)
        return updated
    }
}

struct CaptureLease: Sendable {
    let epoch: UInt64
    let captureID: String
    func validate(epoch currentEpoch: UInt64, captureID currentCapture: String?, generation: UInt64, currentGeneration: UInt64?) throws {
        guard epoch == currentEpoch, captureID == currentCapture, generation == currentGeneration else {
            throw KitError("CONNECTION_CHANGED", "Phone connection or screen changed during capture. Take a fresh screenshot.")
        }
    }
}


enum KeepAwakePolicy {
    static let interval: TimeInterval = 20

    static func isDue(enabled: Bool, lastActivity: Date?, lastAttempt: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        let reference = [lastActivity, lastAttempt].compactMap { $0 }.max() ?? .distantPast
        return now.timeIntervalSince(reference) >= interval
    }
}
