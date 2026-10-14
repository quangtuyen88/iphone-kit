import Foundation
import Testing

@testable import IPhoneKitCore

@MainActor private final class GuardGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiter = continuation
        }
    }

    func open() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor private final class GuardRecordingTransport: ReportTransport {
    var epoch: UInt64 = 1
    var isReady = true
    var reports: [[UInt8]] = []
    var releases = 0
    var sendAttempts = 0
    var failureAtSend: Int?

    func send(_ report: [UInt8], epoch: UInt64, deadline: Date?) async throws {
        sendAttempts += 1
        if failureAtSend == sendAttempts {
            throw KitError("SEND_FAILED", "Synthetic send failure.")
        }
        reports.append(report)
    }

    func neutralize(epoch: UInt64) {
        if self.epoch == epoch { releases += 1 }
    }
}

@MainActor private func guardedResult(action: PhoneAction = .wake) -> ActionResult {
    ActionResult(phoneID: "guarded-test", action: action, startedAt: Date(), epoch: 1)
}

@Test @MainActor func rejectedGuardSendsNothingAndDoesNotCreateDispatchEvidence() async {
    let transport = GuardRecordingTransport()
    let witness = InputDispatchWitness()
    let authorization = GuardedInput(witness: witness) {
        throw KitError("GUARD_REJECTED", "The screen changed.")
    }
    let plan = GesturePlan(reports: [TimedReport(milliseconds: 0, bytes: HIDReports.keyboard(modifiers: 2))])

    do {
        try await GestureRunner().run(
            plan, transport: transport, epoch: 1, deadline: nil, stillValid: { true }, authorization: authorization)
        Issue.record("Expected guard rejection")
    } catch {
        #expect((error as? KitError)?.code == "GUARD_REJECTED")
    }
    #expect(transport.sendAttempts == 0)
    #expect(transport.reports.isEmpty)
    #expect(transport.releases == 0)
    #expect(!witness.didBeginDispatch)
}

@Test @MainActor func cancellationWhileGuardIsSuspendedCannotDispatchAfterLateCompletion() async {
    let transport = GuardRecordingTransport()
    let witness = InputDispatchWitness()
    let gate = GuardGate()
    let authorization = GuardedInput(witness: witness) { await gate.suspend() }
    let plan = GesturePlan(reports: [TimedReport(milliseconds: 0, bytes: HIDReports.keyboard(modifiers: 2))])
    let task = Task { @MainActor in
        try await GestureRunner().run(
            plan, transport: transport, epoch: 1, deadline: nil, stillValid: { true }, authorization: authorization)
    }

    await gate.waitUntilEntered()
    task.cancel()
    gate.open()
    do {
        try await task.value
        Issue.record("Expected cancellation")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(transport.sendAttempts == 0)
    #expect(transport.releases == 0)
    #expect(!witness.didBeginDispatch)
}

@Test @MainActor func leaseRevocationWhileGuardIsSuspendedCannotDispatchAfterLateCompletion() async {
    let transport = GuardRecordingTransport()
    let witness = InputDispatchWitness()
    let gate = GuardGate()
    let plan = GesturePlan(reports: [TimedReport(milliseconds: 0, bytes: HIDReports.keyboard(modifiers: 2))])
    var cancels = 0
    let lease = PhoneInputLease(
        phoneID: "guarded-test",
        execute: { command in guardedResult(action: command.action) },
        guardedExecute: { command, authorization in
            try await GestureRunner().run(
                plan, transport: transport, epoch: 1, deadline: nil,
                stillValid: { true }, authorization: authorization)
            return guardedResult(action: command.action)
        },
        cancel: { cancels += 1 },
        release: {})
    let task = Task { @MainActor in
        try await lease.executeGuarded(PhoneCommand(action: .wake), witness: witness) { await gate.suspend() }
    }

    await gate.waitUntilEntered()
    lease.cancel()
    gate.open()
    do {
        _ = try await task.value
        Issue.record("Expected revoked guard cancellation")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(cancels == 1)
    #expect(transport.sendAttempts == 0)
    #expect(transport.releases == 0)
    #expect(!witness.didBeginDispatch)
}

@Test @MainActor func epochChangeDuringGuardIsRejectedBeforeDispatch() async throws {
    let transport = GuardRecordingTransport()
    let witness = InputDispatchWitness()
    let gate = GuardGate()
    let authorization = GuardedInput(witness: witness) { await gate.suspend() }
    let plan = GesturePlan(reports: [TimedReport(milliseconds: 0, bytes: HIDReports.keyboard())])
    let task = Task { @MainActor in
        try await GestureRunner().run(
            plan, transport: transport, epoch: 1, deadline: nil, stillValid: { true }, authorization: authorization)
    }

    await gate.waitUntilEntered()
    transport.epoch = 2
    gate.open()
    do {
        try await task.value
        Issue.record("Expected epoch rejection")
    } catch {
        #expect((error as? KitError)?.code == "CONNECTION_CHANGED")
    }
    #expect(transport.sendAttempts == 0)
    #expect(transport.releases == 0)
    #expect(!witness.didBeginDispatch)
}

@Test @MainActor func deadlineExpiryDuringGuardIsRejectedBeforeDispatch() async throws {
    let transport = GuardRecordingTransport()
    let witness = InputDispatchWitness()
    let gate = GuardGate()
    var currentTime = Date(timeIntervalSince1970: 1000)
    let deadline = currentTime.addingTimeInterval(1)
    let runner = GestureRunner(now: { currentTime })
    let authorization = GuardedInput(witness: witness) { await gate.suspend() }
    let plan = GesturePlan(reports: [TimedReport(milliseconds: 0, bytes: HIDReports.keyboard())])
    let task = Task { @MainActor in
        try await runner.run(
            plan, transport: transport, epoch: 1, deadline: deadline, stillValid: { true }, authorization: authorization)
    }

    await gate.waitUntilEntered()
    currentTime = deadline
    gate.open()
    do {
        try await task.value
        Issue.record("Expected deadline rejection")
    } catch {
        #expect((error as? KitError)?.code == "DEADLINE_EXCEEDED")
    }
    #expect(transport.sendAttempts == 0)
    #expect(transport.reports.isEmpty)
    #expect(transport.releases == 0)
    #expect(!witness.didBeginDispatch)
}

@Test @MainActor func guardRunsAfterFirstScheduledDelay() async throws {
    let transport = GuardRecordingTransport()
    let witness = InputDispatchWitness()
    var delayCompleted = false
    var validations = 0
    let runner = GestureRunner(sleep: { _ in delayCompleted = true })
    let authorization = GuardedInput(witness: witness) {
        #expect(delayCompleted)
        validations += 1
    }
    let plan = GesturePlan(reports: [TimedReport(milliseconds: 25, bytes: HIDReports.keyboard())])

    try await runner.run(
        plan, transport: transport, epoch: 1, deadline: nil, stillValid: { true }, authorization: authorization)
    #expect(validations == 1)
    #expect(transport.reports.count == 1)
    #expect(witness.didBeginDispatch)
}

@Test @MainActor func guardAuthorizesOnceForMultiReportGesture() async throws {
    let transport = GuardRecordingTransport()
    let witness = InputDispatchWitness()
    var validations = 0
    let authorization = GuardedInput(witness: witness) { validations += 1 }
    let reports = [HIDReports.keyboard(modifiers: 2), HIDReports.keyboard(), HIDReports.consumer(0x0223)]
    let plan = GesturePlan(reports: reports.map { report in TimedReport(milliseconds: 0, bytes: report) })

    try await GestureRunner().run(
        plan, transport: transport, epoch: 1, deadline: nil, stillValid: { true }, authorization: authorization)
    #expect(validations == 1)
    #expect(transport.reports == reports)
    #expect(transport.releases == 0)
    #expect(witness.didBeginDispatch)
}

@Test @MainActor func secondReportSendFailureKeepsDispatchEvidenceAndNeutralizes() async {
    let transport = GuardRecordingTransport()
    transport.failureAtSend = 2
    let witness = InputDispatchWitness()
    let authorization = GuardedInput(witness: witness) {}
    let reports = [HIDReports.keyboard(modifiers: 2), HIDReports.keyboard()]
    let plan = GesturePlan(reports: reports.map { report in TimedReport(milliseconds: 0, bytes: report) })

    do {
        try await GestureRunner().run(
            plan, transport: transport, epoch: 1, deadline: nil, stillValid: { true }, authorization: authorization)
        Issue.record("Expected second send failure")
    } catch {
        #expect((error as? KitError)?.code == "SEND_FAILED")
    }
    #expect(transport.reports == [reports[0]])
    #expect(transport.sendAttempts == 2)
    #expect(transport.releases == 1)
    #expect(witness.didBeginDispatch)
}

@Test @MainActor func secondReportPrecheckFailureKeepsDispatchEvidenceAndNeutralizes() async {
    let transport = GuardRecordingTransport()
    let witness = InputDispatchWitness()
    var valid = true
    let runner = GestureRunner(sleep: { _ in valid = false })
    let authorization = GuardedInput(witness: witness) {}
    let plan = GesturePlan(reports: [
        TimedReport(milliseconds: 0, bytes: HIDReports.keyboard(modifiers: 2)),
        TimedReport(milliseconds: 1, bytes: HIDReports.keyboard()),
    ])

    do {
        try await runner.run(
            plan, transport: transport, epoch: 1, deadline: nil,
            stillValid: { valid }, authorization: authorization)
        Issue.record("Expected second-report validity rejection")
    } catch {
        #expect((error as? KitError)?.code == "CONNECTION_CHANGED")
    }
    #expect(transport.reports.count == 1)
    #expect(transport.sendAttempts == 1)
    #expect(transport.releases == 1)
    #expect(witness.didBeginDispatch)
}

@Test @MainActor func oldEpochFailureNeverQueuesStaleNeutralization() async {
    let transport = GuardRecordingTransport()
    let witness = InputDispatchWitness()
    let runner = GestureRunner(sleep: { _ in transport.epoch = 2 })
    let authorization = GuardedInput(witness: witness) {}
    let plan = GesturePlan(reports: [
        TimedReport(milliseconds: 0, bytes: HIDReports.keyboard(modifiers: 2)),
        TimedReport(milliseconds: 1, bytes: HIDReports.keyboard()),
    ])

    do {
        try await runner.run(
            plan, transport: transport, epoch: 1, deadline: nil, stillValid: { true }, authorization: authorization)
        Issue.record("Expected old-epoch rejection")
    } catch {
        #expect((error as? KitError)?.code == "CONNECTION_CHANGED")
    }
    #expect(transport.reports.count == 1)
    #expect(transport.releases == 0)
    #expect(witness.didBeginDispatch)
}

@Test @MainActor func legacyLeaseRejectsGuardedExecutionWithoutExecuting() async {
    var executions = 0
    var validations = 0
    let lease = PhoneInputLease(
        phoneID: "legacy",
        execute: { command in
            executions += 1
            return guardedResult(action: command.action)
        },
        cancel: {},
        release: {})
    let witness = InputDispatchWitness()

    #expect(!lease.supportsGuardedExecution)
    #expect(lease.isDrained)
    do {
        _ = try await lease.executeGuarded(PhoneCommand(action: .wake), witness: witness) { validations += 1 }
        Issue.record("Expected unsupported guarded execution")
    } catch {
        #expect((error as? KitError)?.code == "GUARDED_INPUT_UNSUPPORTED")
    }
    #expect(executions == 0)
    #expect(validations == 0)
    #expect(!witness.didBeginDispatch)
}

@Test @MainActor func cancelledAndReleasedLeasesRejectAllExecutionEntryPoints() async {
    var executions = 0
    var guardedExecutions = 0

    func makeLease() -> PhoneInputLease {
        PhoneInputLease(
            phoneID: "terminal",
            execute: { command in
                executions += 1
                return guardedResult(action: command.action)
            },
            guardedExecute: { command, _ in
                guardedExecutions += 1
                return guardedResult(action: command.action)
            },
            isDrained: { false },
            cancel: {},
            release: {})
    }

    let cancelled = makeLease()
    #expect(cancelled.supportsGuardedExecution)
    #expect(!cancelled.isDrained)
    cancelled.cancel()
    do {
        _ = try await cancelled.execute(PhoneCommand(action: .wake))
        Issue.record("Expected cancelled lease rejection")
    } catch {
        #expect((error as? KitError)?.code == "INPUT_LEASE_INVALID")
    }
    do {
        _ = try await cancelled.executeGuarded(
            PhoneCommand(action: .wake), witness: InputDispatchWitness(), validate: {})
        Issue.record("Expected cancelled guarded lease rejection")
    } catch {
        #expect((error as? KitError)?.code == "INPUT_LEASE_INVALID")
    }

    let released = makeLease()
    released.release()
    do {
        _ = try await released.execute(PhoneCommand(action: .wake))
        Issue.record("Expected released lease rejection")
    } catch {
        #expect((error as? KitError)?.code == "INPUT_LEASE_INVALID")
    }
    do {
        _ = try await released.executeGuarded(
            PhoneCommand(action: .wake), witness: InputDispatchWitness(), validate: {})
        Issue.record("Expected released guarded lease rejection")
    } catch {
        #expect((error as? KitError)?.code == "INPUT_LEASE_INVALID")
    }
    #expect(executions == 0)
    #expect(guardedExecutions == 0)
}
