import Foundation
import Testing

@testable import IPhoneKitCore

private let start = Date(timeIntervalSince1970: 1_000)

/// `#expect` cannot call mutating members, so each check reads the decision first.
private func due(_ flow: inout TrustWorkflow, at seconds: TimeInterval) -> Bool {
    flow.attemptDue(now: start.addingTimeInterval(seconds))
}

@Test func trustFailuresAreClassifiedFromLockdownCodes() {
    for value: UInt32 in [0xE800_001A, 0xE800_001B, 0xE800_001C, 0xE800_0025, 0xE800_005C, 0xE800_00E2] {
        #expect(LockdownCode.needsTrust(LockdownCode.code(value)))
    }
    #expect(!LockdownCode.needsTrust(0))
    #expect(!LockdownCode.needsTrust(LockdownCode.code(0xE800_000B)), "Not connected is not a trust problem")
    #expect(LockdownCode.hex(LockdownCode.dialogPending) == "0xE8000096")
}

@Test func lockedPhoneRetriesUntilUnlockedThenPollsTheTrustPrompt() {
    var flow = TrustWorkflow()
    let first = due(&flow, at: 0)
    #expect(first, "The first refused session asks right away")
    flow.record(LockdownCode.passcodeProtected, now: start)
    #expect(flow.problem == .locked && flow.problem?.isActive == true)
    let early = due(&flow, at: 4.9)
    let retry = due(&flow, at: 5)
    #expect(!early && retry)
    flow.record(LockdownCode.dialogPending, now: start.addingTimeInterval(5))
    #expect(flow.problem == .awaitingUser && flow.problem?.isActive == true)
    let beforePoll = due(&flow, at: 7.9)
    let poll = due(&flow, at: 8)
    #expect(!beforePoll && poll, "Pairing completes only on a request made after the user accepts")
    flow.record(0, now: start.addingTimeInterval(8))
    #expect(flow.problem == nil)
}

@Test func denialAndPolicyLatchUntilAnExplicitRequest() {
    var flow = TrustWorkflow()
    _ = due(&flow, at: 0)
    flow.record(LockdownCode.userDenied, now: start)
    #expect(flow.problem == .denied && flow.problem?.canRetry == true)
    let later = due(&flow, at: 3_600)
    #expect(!later, "Don't Trust is never re-asked on its own")
    flow = .restarted(now: start.addingTimeInterval(3_600))
    let restarted = due(&flow, at: 3_600)
    #expect(flow.problem == nil && restarted)
    flow.record(LockdownCode.prohibitedByPolicy, now: start.addingTimeInterval(3_600))
    let blocked = due(&flow, at: 7_200)
    #expect(flow.problem == .blocked && flow.problem?.canRetry == false && !blocked)
}

@Test func unansweredPromptExpiresAfterTheWindow() {
    var flow = TrustWorkflow()
    _ = due(&flow, at: 0)
    flow.record(LockdownCode.dialogPending, now: start)
    let inside = due(&flow, at: TrustWorkflow.window - 1)
    let after = due(&flow, at: TrustWorkflow.window)
    #expect(inside && !after)
    #expect(flow.problem == .expired && flow.problem?.canRetry == true && flow.problem?.isActive == false)
}

@Test func timeSpentLockedDoesNotUseUpTheTrustWindow() {
    var flow = TrustWorkflow()
    for minute in 0..<60 {
        let seconds = TimeInterval(minute * 60)
        let asked = due(&flow, at: seconds)
        #expect(asked, "A locked phone is retried for as long as it stays locked")
        flow.record(LockdownCode.passcodeProtected, now: start.addingTimeInterval(seconds))
    }
    flow.record(LockdownCode.dialogPending, now: start.addingTimeInterval(3_600))
    let inside = due(&flow, at: 3_600 + TrustWorkflow.window - 1)
    let after = due(&flow, at: 3_600 + TrustWorkflow.window)
    #expect(inside && !after, "The window starts once the prompt is shown")
}

@Test func lockedSessionsWaitWithoutBreakingLatches() {
    var fresh = TrustWorkflow()
    fresh.observeLocked(LockdownCode.deviceLocked, now: start)
    #expect(fresh.problem == .locked)
    var denied = TrustWorkflow()
    _ = due(&denied, at: 0)
    denied.record(LockdownCode.userDenied, now: start)
    denied.observeLocked(LockdownCode.passcodeProtected, now: start.addingTimeInterval(10))
    let reasked = due(&denied, at: 20)
    #expect(denied.problem == .denied && !reasked, "Locking after Don't Trust must not re-arm the prompt")
}

@Test func lockedProbeAfterPairingKeepsWaitingInsteadOfFailing() {
    var flow = TrustWorkflow()
    _ = due(&flow, at: 0)
    flow.record(0, now: start)
    flow.recordRefusalAfterPairing(LockdownCode.passcodeProtected, now: start)
    let retry = due(&flow, at: TrustWorkflow.lockedInterval)
    #expect(flow.problem == .locked && retry, "A rebooted, still-locked phone is not a failed pairing")
}

@Test func unexpectedErrorsRetryWhileTerminalStatesStop() {
    var flow = TrustWorkflow()
    _ = due(&flow, at: 0)
    flow.record(LockdownCode.code(0xE800_0068), now: start)
    let retry = due(&flow, at: 5)
    #expect(flow.problem == .failed && retry)
    flow.recordRefusalAfterPairing(LockdownCode.invalidHostID, now: start.addingTimeInterval(5))
    let afterSession = due(&flow, at: 10)
    #expect(flow.problem == .sessionFailed && flow.lastCode == LockdownCode.invalidHostID)
    #expect(!afterSession && flow.problem?.canRetry == true, "Only an explicit request tries again")
    var missing = TrustWorkflow()
    missing.markUnavailable()
    let unavailable = due(&missing, at: 0)
    #expect(!unavailable && missing.problem?.canRetry == false)
}

@Test func trustCopyNamesTheNextStep() { #expect(TrustProblem.awaitingUser.message().contains("tap Trust"))
#expect(TrustProblem.locked.message().hasPrefix("Unlock"))
#expect(TrustProblem.failed.message(code: "0xE8000068").contains("(0xE8000068)"))
#expect(!TrustProblem.sessionFailed.message().contains("()"))
let all: [TrustProblem] = [.locked, .awaitingUser, .denied, .blocked, .expired, .failed, .sessionFailed, .unavailable]
#expect(Set(all.map { $0.message() }).count == all.count)
 }

@Test func pairingRejectionDoesNotAttributeATapToTheUser() {
    let message = TrustProblem.denied.message(code: "0xE8000095")
    #expect(TrustProblem.denied.rawValue == "denied")
    #expect(message.contains("0xE8000095"))
    #expect(!message.contains("You tapped"))
    #expect(message.contains("reconnect"))
}

@Test func trustStateIsAdditiveOnTheWire() throws {
    let info = PhoneInfo(id: "p", name: "iPhone", status: .needsTrust, trust: .awaitingUser, trustErrorCode: "0xE8000096")
    let json = String(decoding: try KitJSON.encoder().encode(info), as: UTF8.self)
    #expect(json.contains(#""trust":"awaiting_user""#))
    #expect(json.contains(#""trust_error_code":"0xE8000096""#))
    #expect(try KitJSON.decoder().decode(PhoneInfo.self, from: Data(json.utf8)) == info)
    let legacy = #"{"id":"p","name":"iPhone","model":"iPhone","system_version":"","status":"ready","message":"","width":0,"height":0,"epoch":0,"keep_awake":false}"#
    #expect(try KitJSON.decoder().decode(PhoneInfo.self, from: Data(legacy.utf8)).trust == nil)
}

@Test func phonesRememberedBeforeTrustTrackingStillDecode() throws {
    let legacy = #"{"id":"u","name":"iPhone","model":"iPhone14,7","systemVersion":"27.0","bluetoothAddress":"02:00:00:00:00:01","trusted":true,"assistiveTouch":true,"available":false}"#
    let phone = try JSONDecoder().decode(USBPhone.self, from: Data(legacy.utf8))
    #expect(phone.trusted && phone.trustProblem == nil && phone.trustCode == nil)
    let untrusted = USBPhone(id: "u", name: "iPhone", model: "iPhone14,7", systemVersion: "27.0", bluetoothAddress: nil,
                             trusted: false, assistiveTouch: nil, available: true, trustProblem: .denied, trustCode: LockdownCode.userDenied)
    #expect(untrusted.settingAvailable(false).trustProblem == .denied, "Availability changes keep the trust step")
}
