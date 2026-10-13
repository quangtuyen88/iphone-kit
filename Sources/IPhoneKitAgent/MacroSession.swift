import Foundation
import Observation
import IPhoneKitCore

public enum MacroRunState: String, Sendable {
    case idle, waiting, awaitingApproval, executing, verifying, completed, paused, stopped

    public var isActive: Bool {
        switch self {
        case .waiting, .awaitingApproval, .executing, .verifying: true
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

    @ObservationIgnored private let controller: any ExclusivePhoneControlling
    @ObservationIgnored private let matcher: any VisualMatching
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var lease: PhoneInputLease?
    @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?

    private struct Run {
        let id: UUID
        let phone: PhoneInfo
        let profile: MacroProfile
        let startedAt: Date
        let deadline: ContinuousClock.Instant
        let wallDeadline: Date
    }

    private struct StopConditionReached: Error {}

    public init(controller: any ExclusivePhoneControlling, matcher: any VisualMatching = LocalVisualMatcher(),
                pollInterval: Duration = .milliseconds(150), now: @escaping @MainActor () -> Date = { Date() }) {
        self.controller = controller
        self.matcher = matcher
        self.pollInterval = pollInterval
        self.now = now
    }

    /// The caller must explicitly approve this immutable profile and its limits before starting.
    public func start(profile: MacroProfile, phoneID: String) throws {
        guard !state.isActive else { throw KitError("MACRO_BUSY", "Stop the current macro first.") }
        try profile.validate()
        guard profile.phoneID == phoneID,
              let phone = controller.phones.first(where: { $0.id == phoneID && $0.status == .ready }),
              phone.width == profile.nativeWidth, phone.height == profile.nativeHeight else {
            throw KitError("MACRO_PHONE_CHANGED", "Select the recorded phone in its original portrait orientation.")
        }
        let input = try controller.acquireInput(phoneID: phoneID)
        let startedAt = now()
        let run = Run(id: UUID(), phone: phone, profile: profile, startedAt: startedAt,
                      deadline: .now + .seconds(profile.maximumSeconds),
                      wallDeadline: startedAt.addingTimeInterval(profile.maximumSeconds))
        token = run.id
        lease = input
        activePhoneID = phoneID
        actionCount = 0
        stepIndex = 0
        iteration = 0
        proposal = nil
        state = .waiting
        message = "Checking the recorded screen. Other input is locked during this run."
        watchdog = Task { [weak self] in
            do { try await Task.sleep(until: run.deadline, clock: .continuous) } catch { return }
            guard let self, token == run.id else { return }
            finishEarly(state: .paused, message: "Session time limit reached. Inspect the phone; no action was replayed.")
        }
        worker = Task { [weak self] in await self?.play(run, input: input) }
    }

    public func decide(proposalID: UUID, allow: Bool) {
        guard state == .awaitingApproval, proposal?.id == proposalID else { return }
        let waiter = approval
        approval = nil
        proposal = nil
        waiter?.resume(returning: allow)
    }

    public func stop() {
        guard token != nil else { return }
        finishEarly(state: .stopped, message: "Stopped. Inspect any in-flight action before starting a new run.")
    }

    private func finishEarly(state: MacroRunState, message: String) {
        token = nil
        worker?.cancel()
        worker = nil
        watchdog?.cancel()
        watchdog = nil
        let waiter = approval
        approval = nil
        proposal = nil
        waiter?.resume(returning: false)
        lease?.cancel()
        lease?.release()
        lease = nil
        activePhoneID = nil
        self.state = state
        self.message = message
    }

    private func check(_ run: Run) throws {
        try Task.checkCancellation()
        guard token == run.id else { throw CancellationError() }
        guard ContinuousClock.now < run.deadline else {
            throw KitError("MACRO_TIME_LIMIT", "Session time limit reached. No action was replayed.")
        }
        guard let phone = controller.phones.first(where: { $0.id == run.phone.id }),
              phone.status == .ready, phone.epoch == run.phone.epoch,
              phone.captureID == run.phone.captureID,
              phone.width == run.profile.nativeWidth, phone.height == run.profile.nativeHeight else {
            throw KitError("MACRO_CONNECTION_CHANGED", "Phone, connection, screen source, or orientation changed. Start again after inspection.")
        }
    }

    private func checkFrame(_ screenshot: Screenshot, run: Run) throws {
        guard screenshot.phoneID == run.phone.id, screenshot.epoch == run.phone.epoch,
              screenshot.nativeWidth == run.profile.nativeWidth,
              screenshot.nativeHeight == run.profile.nativeHeight else {
            throw KitError("MACRO_FRAME_CHANGED", "The frame does not belong to the approved phone and geometry.")
        }
        let age = now().timeIntervalSince(screenshot.capturedAt)
        guard age >= -0.5, age <= 1 else {
            throw KitError("MACRO_STALE_FRAME", "Screen verification expired. No further input was sent.")
        }
    }

    private func waitFor(_ anchor: VisualAnchor, after: Date, timeout: Double, run: Run) async throws -> Screenshot {
        let deadline = min(run.deadline, ContinuousClock.now + .seconds(timeout))
        var lastFrame = after
        repeat {
            try check(run)
            let screenshot = try await controller.screenshot(phoneID: run.phone.id, longEdge: 900)
            try check(run)
            guard screenshot.phoneID == run.phone.id, screenshot.epoch == run.phone.epoch,
                  screenshot.nativeWidth == run.profile.nativeWidth,
                  screenshot.nativeHeight == run.profile.nativeHeight else {
                throw KitError("MACRO_FRAME_CHANGED", "The captured phone or screen geometry changed.")
            }
            if screenshot.capturedAt > lastFrame, now().timeIntervalSince(screenshot.capturedAt) <= 1 {
                try checkFrame(screenshot, run: run)
                lastFrame = screenshot.capturedAt
                if let stop = run.profile.stopWhen {
                    let reached = try await matcher.matches(stop, screenshot: screenshot)
                    try check(run)
                    try checkFrame(screenshot, run: run)
                    if reached { throw StopConditionReached() }
                }
                let matches = try await matcher.matches(anchor, screenshot: screenshot)
                try check(run)
                try checkFrame(screenshot, run: run)
                if matches, ContinuousClock.now < deadline { return screenshot }
            }
            try await Task.sleep(for: pollInterval)
        } while ContinuousClock.now < deadline
        throw KitError("MACRO_SCREEN_TIMEOUT", "Expected screen was not verified in time. Inspect the phone; the action was not replayed.")
    }

    private func play(_ run: Run, input: PhoneInputLease) async {
        defer {
            input.release()
            if token == run.id {
                watchdog?.cancel()
                watchdog = nil
                worker = nil
                lease = nil
                token = nil
                activePhoneID = nil
                proposal = nil
            }
        }
        var after = run.startedAt
        do {
            for repetition in 0..<run.profile.repetitions {
                iteration = repetition + 1
                for (index, step) in run.profile.steps.enumerated() {
                    try check(run)
                    guard actionCount < run.profile.maximumActions else {
                        state = .completed
                        message = "Stopped at the approved \(run.profile.maximumActions)-action limit."
                        return
                    }
                    stepIndex = index + 1
                    state = .waiting
                    message = "Loop \(iteration) · step \(stepIndex): waiting for \(step.name)."
                    if step.delaySeconds > 0 { try await Task.sleep(for: .seconds(step.delaySeconds)) }
                    try check(run)
                    var frame = try await waitFor(step.before, after: after, timeout: step.timeoutSeconds, run: run)
                    if step.requiresApproval {
                        let pending = MacroProposal(stepName: step.name, screenshot: frame, command: try step.gesture.command(for: frame))
                        proposal = pending
                        state = .awaitingApproval
                        message = "Approve this individual action. The session timer is still running."
                        let allowed = await withCheckedContinuation { approval = $0 }
                        try check(run)
                        guard allowed else {
                            input.cancel()
                            state = .stopped
                            message = "Action rejected. Macro stopped."
                            return
                        }
                        state = .waiting
                        frame = try await waitFor(step.before, after: now(), timeout: step.timeoutSeconds, run: run)
                    }
                    try check(run)
                    try checkFrame(frame, run: run)
                    var command = try step.gesture.command(for: frame)
                    command.deadline = min(run.wallDeadline, now().addingTimeInterval(step.timeoutSeconds))
                    state = .executing
                    actionCount += 1
                    message = "Sending \(step.name) once."
                    let result = try await input.execute(command)
                    try check(run)
                    guard result.phoneID == run.phone.id, result.epoch == run.phone.epoch,
                          result.action == command.action, ["sent", "simulated"].contains(result.status) else {
                        throw KitError("MACRO_UNCERTAIN", "Input outcome is uncertain. Inspect the phone; no action was replayed.")
                    }
                    after = result.completedAt
                    state = .verifying
                    message = "Verifying the result of \(step.name)."
                    _ = try await waitFor(step.after, after: after, timeout: step.timeoutSeconds, run: run)
                }
            }
            state = .completed
            message = "Completed \(actionCount) actions; each result was screen-verified."
        } catch is StopConditionReached {
            if token == run.id {
                state = .completed
                message = "The recorded stop screen was detected. No further input sent."
            }
        } catch is CancellationError {
            if token == run.id {
                input.cancel()
                state = .stopped
                message = "Cancelled. Inspect the phone before running again."
            }
        } catch {
            if token == run.id {
                input.cancel()
                state = .paused
                message = (error as? KitError)?.message ?? "Screen verification or input failed. No action was replayed."
            }
        }
    }
}
