import Foundation
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

@Test func monotonicUptimesRoundTripWithKitJSON() throws {
    let capturedAt = Date(timeIntervalSince1970: 1_000)
    let screenshot = Screenshot(phoneID: "phone", epoch: 4, width: 100, height: 200,
                                nativeWidth: 200, nativeHeight: 400, capturedAt: capturedAt,
                                jpeg: Data([0xFF]), capturedUptime: 42.25)
    let screenshotData = try KitJSON.encoder().encode(screenshot)
    let decodedScreenshot = try KitJSON.decoder().decode(Screenshot.self, from: screenshotData)
    #expect(decodedScreenshot.capturedUptime == 42.25)

    let result = ActionResult(phoneID: "phone", action: .tap, startedAt: capturedAt,
                              completedAt: capturedAt.addingTimeInterval(1), epoch: 4,
                              completedUptime: 43.25)
    let resultData = try KitJSON.encoder().encode(result)
    let decodedResult = try KitJSON.decoder().decode(ActionResult.self, from: resultData)
    #expect(decodedResult.completedUptime == 43.25)
}

@Test func oldJSONDoesNotSynthesizeMonotonicUptimes() throws {
    let screenshotJSON = Data(#"{"id":"shot","phone_id":"phone","epoch":1,"width":100,"height":200,"native_width":100,"native_height":200,"captured_at":"1970-01-01T00:00:00Z","jpeg":"","orientation":"portrait"}"#.utf8)
    let screenshot = try KitJSON.decoder().decode(Screenshot.self, from: screenshotJSON)
    #expect(screenshot.capturedUptime == nil)

    let resultJSON = Data(#"{"id":"result","phone_id":"phone","action":"tap","status":"sent","started_at":"1970-01-01T00:00:00Z","completed_at":"1970-01-01T00:00:01Z","epoch":1,"message":"sent"}"#.utf8)
    let result = try KitJSON.decoder().decode(ActionResult.self, from: resultJSON)
    #expect(result.completedUptime == nil)
}
