import Testing
@testable import IPhoneKitCore

@Test func journalWriteFailureCannotBeBypassedOnRetry() {
    var values: [String: Bool] = [:]
    var attempts = 0
    for _ in 0..<2 {
        do {
            values = try AccessibilityJournal.recording(phoneID: "phone", original: false, values: values) { _ in
                attempts += 1
                throw KitError("DISK_FULL", "Disk full.")
            }
            Issue.record("A failed write must prevent mutation.")
        } catch { #expect((error as? KitError)?.code == "DISK_FULL") }
        #expect(values.isEmpty)
    }
    #expect(attempts == 2)
}

@Test func captureCannotBorrowANewerConnectionEpoch() throws {
    let lease = CaptureLease(epoch: 3, captureID: "screen")
    try lease.validate(epoch: 3, captureID: "screen", generation: 1, currentGeneration: 1)
    #expect(throws: KitError.self) { try lease.validate(epoch: 4, captureID: "screen", generation: 1, currentGeneration: 1) }
    #expect(throws: KitError.self) { try lease.validate(epoch: 3, captureID: "other", generation: 1, currentGeneration: 1) }
    #expect(throws: KitError.self) { try lease.validate(epoch: 3, captureID: "screen", generation: 1, currentGeneration: 2) }
}
