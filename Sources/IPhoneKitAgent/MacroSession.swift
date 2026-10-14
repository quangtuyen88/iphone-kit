import Foundation
import Observation
import IPhoneKitCore

public enum MacroRunState: String, Sendable {
    case idle, waiting, awaitingApproval, executing, verifying, stopping, completed, paused, stopped

    public var isActive: Bool {
        switch self {
        case .waiting, .awaitingApproval, .executing, .verifying, .stopping: true
        default: false
        }
    }
}

public struct MacroProposal: Identifiable, Sendable {
    public let id = UUID()
    public let stepName: String
    public let screenshot: Screenshot
    public let command: PhoneCommand
}

@Observable @MainActor
public final class MacroSession {
    public private(set) var state = MacroRunState.idle
    public private(set) var activePhoneID: String?
    public private(set) var actionCount = 0
    public private(set) var stepIndex = 0
    public private(set) var iteration = 0
    public private(set) var message = "Record a short sequence, then review it before running."
    public private(set) var proposal: MacroProposal?
    public private(set) var lastVerifiedStep: MacroStepProgress?
    public private(set) var recovery: MacroRecovery?
    public private(set) var diagnostics: [MacroDiagnosticEvent] = []

    @ObservationIgnored private let controller: any ExclusivePhoneControlling
    @ObservationIgnored private let matcher: any VisualMatching
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let uptime: @MainActor () -> TimeInterval
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var lease: PhoneInputLease?
    @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var currentStep: MacroStepProgress?
    @ObservationIgnored private var currentDispatch: InputDispatchWitness?
    @ObservationIgnored private var dispatchCounted = false
    @ObservationIgnored private var transportCompleted = false
    @ObservationIgnored private var lastValidationUptime: TimeInterval?
    @ObservationIgnored private var stopRequest: StopRequest?

    private struct Run {
        let id: UUID
        let phone: PhoneInfo
        let profile: MacroProfile
        let startedUptime: TimeInterval
        let deadline: ContinuousClock.Instant
        let wallDeadline: Date
    }

    private struct StopRequest {
        let runID: UUID
        let terminalState: MacroRunState
    }

    private struct StopConditionReached: Error {}

    public init(controller: any ExclusivePhoneControlling, matcher: any VisualMatching = LocalVisualMatcher(),
                pollInterval: Duration = .milliseconds(150), now: @escaping @MainActor () -> Date = { Date() },
                uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.controller = controller
        self.matcher = matcher
        self.pollInterval = pollInterval
        self.now = now
        self.uptime = uptime
    }

    public var diagnosticReport: String {
        let encoder = KitJSON.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(diagnostics), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// The caller must explicitly review this immutable profile and inspect any
    /// interrupted run. Starting again always begins at step one, never resumes.
    public func start(profile: MacroProfile, phoneID: String) throws {
        guard !state.isActive else { throw KitError("MACRO_BUSY", "Wait for the current run and pending input to settle.") }
        try profile.validate()
        guard profile.phoneID == phoneID,
              let phone = controller.phones.first(where: { value in value.id == phoneID && value.status == .ready }),
              phone.width == profile.nativeWidth, phone.height == profile.nativeHeight else {
            throw KitError("MACRO_PHONE_CHANGED", "Select the recorded phone in its original portrait orientation.")
        }
        let input = try controller.acquireInput(phoneID: phoneID)
        guard input.supportsGuardedExecution else {
            input.release()
            throw KitError("GUARDED_INPUT_UNSUPPORTED", MacroPauseReason.guardUnavailable.message)
        }
        let run = Run(id: UUID(), phone: phone, profile: profile, startedUptime: uptime(),
                      deadline: .now + .seconds(profile.maximumSeconds),
                      wallDeadline: now().addingTimeInterval(profile.maximumSeconds))
        token = run.id
        lease = input
        activePhoneID = phoneID
        actionCount = 0
        stepIndex = 0
        iteration = 0
        proposal = nil
        lastVerifiedStep = nil
        recovery = nil
        currentStep = nil
        currentDispatch = nil
        dispatchCounted = false
        transportCompleted = false
        lastValidationUptime = nil
        stopRequest = nil
        state = .waiting
        message = "Checking the recorded screen. Other input is locked during this run."
        record(.started, runID: run.id)
        watchdog = Task { [weak self] in
            do { try await Task.sleep(until: run.deadline, clock: .continuous) } catch { return }
            guard let self, token == run.id else { return }
            interrupt(runID: run.id, terminalState: .paused, reason: .timeLimit)
        }
        worker = Task { [weak self] in
            guard let self else { input.cancel(); input.release(); return }
            await play(run, input: input)
        }
    }

    public func decide(proposalID: UUID, allow: Bool) {
        guard state == .awaitingApproval, proposal?.id == proposalID else { return }
        let waiter = approval
        approval = nil
        proposal = nil
        waiter?.resume(returning: allow)
    }

    public func stop() {
        guard let token else { return }
        interrupt(runID: token, terminalState: .stopped, reason: .userStopped)
    }

    private func accountDispatch(runID: UUID) {
        guard token == runID, currentDispatch?.didBeginDispatch == true, !dispatchCounted else { return }
        actionCount += 1
        dispatchCounted = true
        record(.dispatched, runID: runID, outcome: .possiblySent)
    }

    private func interrupt(runID: UUID, terminalState: MacroRunState, reason: MacroPauseReason) {
        guard token == runID else { return }
        accountDispatch(runID: runID)
        let began = currentDispatch?.revokeAndSnapshot() ?? false
        let outcome: MacroInputOutcome = transportCompleted ? .sentButUnverified : began ? .possiblySent : .notDispatched
        recovery = MacroRecovery(id: runID, phoneID: activePhoneID ?? "", reason: reason,
                                 lastVerifiedStep: lastVerifiedStep, interruptedStep: currentStep, outcome: outcome)
        stopRequest = StopRequest(runID: runID, terminalState: terminalState)
        token = nil
        worker?.cancel()
        watchdog?.cancel()
        watchdog = nil
        let waiter = approval
        approval = nil
        proposal = nil
        waiter?.resume(returning: false)
        lease?.cancel()
        lease?.release()
        state = .stopping
        message = "Waiting for pending input and screen checks to settle…"
        record(.interrupted, runID: runID, outcome: outcome, reason: reason)
        record(.draining, runID: runID, outcome: outcome, reason: reason)
    }

    private func finishWorker(_ run: Run, input: PhoneInputLease) {
        input.release()
        if let request = stopRequest, request.runID == run.id {
            worker = nil
            lease = nil
            drainTask = Task { [weak self] in
                while !input.isDrained {
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                }
                guard let self, stopRequest?.runID == run.id else { return }
                state = request.terminalState
                activePhoneID = nil
                if let recovery {
                    message = recovery.reason.message + " " + recovery.outcome.message
                    record(.stopped, runID: run.id, outcome: recovery.outcome, reason: recovery.reason)
                }
                stopRequest = nil
                currentDispatch = nil
                drainTask = nil
            }
        } else if token == run.id {
            watchdog?.cancel()
            watchdog = nil
            worker = nil
            lease = nil
            token = nil
            activePhoneID = nil
            proposal = nil
            currentDispatch = nil
        }
    }

    private func record(_ phase: MacroDiagnosticPhase, runID: UUID,
                        outcome: MacroInputOutcome? = nil, reason: MacroPauseReason? = nil) {
        guard token == runID || stopRequest?.runID == runID else { return }
        diagnostics.append(MacroDiagnosticEvent(id: UUID(), runID: runID, timestamp: now(), phase: phase,
                                               progress: currentStep, outcome: outcome, reason: reason))
        if diagnostics.count > 100 { diagnostics.removeFirst(diagnostics.count - 100) }
    }

    private func check(_ run: Run) throws {
        try Task.checkCancellation()
        guard token == run.id else { throw CancellationError() }
        guard ContinuousClock.now < run.deadline else {
            throw KitError("MACRO_TIME_LIMIT", "Session time limit reached.")
        }
        guard let phone = controller.phones.first(where: { value in value.id == run.phone.id }),
              phone.status == .ready, phone.epoch == run.phone.epoch,
              phone.captureID == run.phone.captureID,
              phone.width == run.profile.nativeWidth, phone.height == run.profile.nativeHeight else {
            throw KitError("MACRO_CONNECTION_CHANGED", "Phone, connection, screen source, or orientation changed.")
        }
    }

    private func frameUptime(_ frame: Screenshot, run: Run) throws -> TimeInterval {
        guard frame.phoneID == run.phone.id, frame.epoch == run.phone.epoch,
              frame.nativeWidth == run.profile.nativeWidth, frame.nativeHeight == run.profile.nativeHeight else {
            throw KitError("MACRO_FRAME_CHANGED", "The captured phone or screen geometry changed.")
        }
        guard let captured = frame.capturedUptime, captured.isFinite, captured >= 0 else {
            throw KitError("MACRO_STALE_FRAME", "The capture lacks valid monotonic timing metadata.")
        }
        return captured
    }

    @discardableResult
    private func checkFrame(_ frame: Screenshot, run: Run) throws -> TimeInterval {
        let captured = try frameUptime(frame, run: run)
        let wallAge = now().timeIntervalSince(frame.capturedAt)
        let monotonicAge = uptime() - captured
        guard wallAge >= -0.5, wallAge <= 1, monotonicAge >= -0.5, monotonicAge <= 1 else {
            throw KitError("MACRO_STALE_FRAME", "Screen verification expired.")
        }
        return captured
    }

    private func nextFrame(after: TimeInterval, until deadline: ContinuousClock.Instant, run: Run) async throws -> Screenshot {
        while ContinuousClock.now < deadline {
            try check(run)
            let frame = try await controller.screenshot(phoneID: run.phone.id, longEdge: 900)
            try check(run)
            let captured = try frameUptime(frame, run: run)
            if captured > after, now().timeIntervalSince(frame.capturedAt) <= 1, uptime() - captured <= 1 {
                try checkFrame(frame, run: run)
                guard ContinuousClock.now < deadline else { break }
                return frame
            }
            try await Task.sleep(for: pollInterval)
        }
        throw KitError("MACRO_STALE_FRAME", "A newer screen did not arrive before the verification deadline.")
    }

    private func checkStopCondition(_ frame: Screenshot, run: Run) async throws {
        guard let stop = run.profile.stopWhen else { return }
        let reached = try await matcher.matches(stop, screenshot: frame)
        try check(run)
        try checkFrame(frame, run: run)
        if reached { throw StopConditionReached() }
    }

    private func matchesBefore(_ anchor: VisualAnchor, frame: Screenshot, run: Run) async throws -> Bool {
        let matches = try await matcher.matches(anchor, screenshot: frame)
        try check(run)
        try checkFrame(frame, run: run)
        guard matches else { return false }
        if anchor.region != .full || anchor.tolerance > LocalVisualMatcher.contextToleranceCap {
            let contextMatches = try await matcher.matchesContext(anchor, screenshot: frame)
            try check(run)
            try checkFrame(frame, run: run)
            guard contextMatches else {
                throw KitError("MACRO_CONTEXT_CHANGED", "The surrounding screen changed.")
            }
        }
        return true
    }

    private func waitFor(_ anchor: VisualAnchor, after: TimeInterval, timeout: Double,
                         run: Run, beforeInput: Bool = false) async throws -> Screenshot {
        let deadline = min(run.deadline, ContinuousClock.now + .seconds(timeout))
        var lastFrame = after
        while ContinuousClock.now < deadline {
            let frame = try await nextFrame(after: lastFrame, until: deadline, run: run)
            lastFrame = try checkFrame(frame, run: run)
            try await checkStopCondition(frame, run: run)
            let matches: Bool
            if beforeInput { matches = try await matchesBefore(anchor, frame: frame, run: run) }
            else { matches = try await matcher.matches(anchor, screenshot: frame) }
            try check(run)
            try checkFrame(frame, run: run)
            if matches, ContinuousClock.now < deadline { return frame }
            try await Task.sleep(for: pollInterval)
        }
        throw KitError("MACRO_SCREEN_TIMEOUT", "The expected screen was not verified in time.")
    }

    private func validateBeforeInput(
        _ step: MacroStep, firstFrame: Screenshot,
        deadline: ContinuousClock.Instant, run: Run
    ) async throws {
        try check(run)
        record(.checkingBeforeInput, runID: run.id)
        let previous = try frameUptime(firstFrame, run: run)
        let frame = try await nextFrame(after: previous, until: deadline, run: run)
        guard frame.width == firstFrame.width, frame.height == firstFrame.height else {
            throw KitError("MACRO_FRAME_CHANGED", "Screenshot pixel geometry changed before dispatch.")
        }
        try await checkStopCondition(frame, run: run)
        guard try await matchesBefore(step.before, frame: frame, run: run) else {
            throw KitError("MACRO_SCREEN_CHANGED", "The target changed before dispatch.")
        }
        try check(run)
        try checkFrame(frame, run: run)
        guard ContinuousClock.now < deadline else {
            throw KitError("MACRO_TIME_LIMIT", "The action verification time limit was reached.")
        }

        lastValidationUptime = try checkFrame(frame, run: run)
    }

    private func pauseReason(_ error: any Error) -> MacroPauseReason {
        guard let code = (error as? KitError)?.code else {
            return state == .executing ? .inputFailure : .verificationFailed
        }
        switch code {
        case "MACRO_CONNECTION_CHANGED", "MACRO_FRAME_CHANGED", "CONNECTION_CHANGED", "INPUT_LEASE_INVALID",
             "PHONE_OFFLINE", "PHONE_NOT_READY", "PHONE_ASLEEP", "BLUETOOTH_DISCONNECTED": return .connectionChanged
        case "MACRO_CONTEXT_CHANGED": return .contextChanged
        case "MACRO_STALE_FRAME", "STALE_SCREENSHOT": return .staleFrame
        case "MACRO_SCREEN_CHANGED": return .screenChanged
        case "MACRO_SCREEN_TIMEOUT": return state == .verifying ? .verificationFailed : .screenChanged
        case "MACRO_TIME_LIMIT", "DEADLINE_EXCEEDED": return .timeLimit
        case "MACRO_UNCERTAIN", "BLUETOOTH_TIMEOUT", "ACTION_INTERRUPTED": return .inputUncertain
        case "GUARDED_INPUT_UNSUPPORTED", "MACRO_CONTEXT_UNSUPPORTED": return .guardUnavailable
        default: return state == .executing ? .inputFailure : .verificationFailed
        }
    }

    private func play(_ run: Run, input: PhoneInputLease) async {
        defer { finishWorker(run, input: input) }
        var after = run.startedUptime
        do {
            try check(run)
            for repetition in 0..<run.profile.repetitions {
                try check(run)
                iteration = repetition + 1
                for (index, step) in run.profile.steps.enumerated() {
                    try check(run)
                    guard actionCount < run.profile.maximumActions else {
                        state = .completed
                        message = "Stopped at the approved \(run.profile.maximumActions)-action limit."
                        record(.completed, runID: run.id)
                        return
                    }
                    stepIndex = index + 1
                    currentStep = MacroStepProgress(iteration: iteration, stepIndex: stepIndex, action: step.gesture.action)
                    currentDispatch = nil
                    dispatchCounted = false
                    transportCompleted = false
                    lastValidationUptime = nil
                    state = .waiting
                    message = "Loop \(iteration) · step \(stepIndex): waiting for the recorded screen."
                    record(.waitingForScreen, runID: run.id)
                    if step.delaySeconds > 0 { try await Task.sleep(for: .seconds(step.delaySeconds)) }
                    try check(run)
                    var frame = try await waitFor(step.before, after: after, timeout: step.timeoutSeconds, run: run, beforeInput: true)
                    if step.requiresApproval {
                        let pending = MacroProposal(stepName: step.name, screenshot: frame, command: try step.gesture.command(for: frame))
                        proposal = pending
                        state = .awaitingApproval
                        message = "Approve this individual action. The session timer is still running."
                        record(.awaitingApproval, runID: run.id)
                        let allowed = await withCheckedContinuation { continuation in approval = continuation }
                        try check(run)
                        guard allowed else {
                            interrupt(runID: run.id, terminalState: .stopped, reason: .approvalRejected)
                            return
                        }
                        state = .waiting
                        frame = try await waitFor(step.before, after: uptime(), timeout: step.timeoutSeconds, run: run, beforeInput: true)
                    }
                    try check(run)
                    try checkFrame(frame, run: run)
                    var command = try step.gesture.command(for: frame)
                    command.deadline = min(run.wallDeadline, now().addingTimeInterval(step.timeoutSeconds))
                    let validationDeadline = min(run.deadline, ContinuousClock.now + .seconds(step.timeoutSeconds))
                    let evidence = InputDispatchWitness()
                    currentDispatch = evidence
                    state = .executing
                    message = "Checking the screen again at the input boundary."
                    let result = try await input.executeGuarded(command, witness: evidence) { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await validateBeforeInput(step, firstFrame: frame, deadline: validationDeadline, run: run)
                    }
                    try check(run)
                    accountDispatch(runID: run.id)
                    guard evidence.didBeginDispatch, result.phoneID == run.phone.id, result.epoch == run.phone.epoch,
                        result.action == command.action, ["sent", "simulated"].contains(result.status),
                        let completed = result.completedUptime, completed.isFinite,
                        let verified = lastValidationUptime, completed >= verified, completed <= uptime() + 0.5
                    else {
                        throw KitError("MACRO_UNCERTAIN", "Input outcome could not be established.")

                    }
                    transportCompleted = true
                    record(.sent, runID: run.id, outcome: .sentButUnverified)
                    after = completed
                    state = .verifying
                    message = "Verifying the result of step \(stepIndex)."
                    _ = try await waitFor(step.after, after: after, timeout: step.timeoutSeconds, run: run)
                    try check(run)
                    lastVerifiedStep = currentStep
                    record(.resultVerified, runID: run.id)
                    currentStep = nil
                    currentDispatch = nil
                    transportCompleted = false
                    lastValidationUptime = nil
                }
            }
            state = .completed
            message = "Completed \(actionCount) actions; each result was screen-verified."
            record(.completed, runID: run.id)
        } catch is StopConditionReached {
            if token == run.id {
                state = .completed
                message = "The recorded stop screen was detected. No further input requested."
                record(.completed, runID: run.id)
            }
        } catch is CancellationError {
            if token == run.id { interrupt(runID: run.id, terminalState: .stopped, reason: .userStopped) }
        } catch {
            if token == run.id { interrupt(runID: run.id, terminalState: .paused, reason: pauseReason(error)) }
        }
    }
}
