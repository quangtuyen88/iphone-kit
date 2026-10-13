import Foundation
import Observation
import IPhoneKitCore

public enum AgentRunState: String, Sendable {
    case idle, thinking, awaitingApproval, executing, completed, stopped, needsInput, failed
    public var isActive: Bool { self == .thinking || self == .awaitingApproval || self == .executing }
}

public struct ChatEntry: Identifiable, Sendable {
    public enum Role: String, Sendable { case user, assistant, activity }
    public let id = UUID()
    public let role: Role
    public let text: String
    public init(role: Role, text: String) { self.role = role; self.text = text }
}

public struct AgentProposal: Identifiable, Sendable {
    public let id = UUID()
    public let phoneID: String
    public let screenshot: Screenshot
    public let command: PhoneCommand
    public let reason: String
}

@Observable @MainActor
public final class AgentSession {
    public private(set) var state = AgentRunState.idle
    public private(set) var messages: [ChatEntry] = []
    public private(set) var proposal: AgentProposal?
    public private(set) var activePhoneID: String?
    public private(set) var stepCount = 0
    @ObservationIgnored private let controller: any PhoneControlling
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var planner: (any VisionPlanning)?
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?
    private let maximumSteps: Int

    @ObservationIgnored private let now: @MainActor () -> Date

public init(controller: any PhoneControlling, maximumSteps: Int = 20, now: @escaping @MainActor () -> Date = { Date() }) {
        self.controller = controller
        self.maximumSteps = max(1, min(20, maximumSteps))
        self.now = now
    }

    public func start(goal: String, phoneID: String, planner: any VisionPlanning) throws {
        guard !state.isActive else { throw KitError("AGENT_BUSY", "Stop the current task before starting another.") }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, goal.utf8.count <= 4096 else { throw KitError("INVALID_TASK", "Enter a task of 1–4096 UTF-8 bytes.") }
        guard controller.phones.contains(where: { $0.id == phoneID && $0.status == .ready }) else {
            throw KitError("PHONE_NOT_READY", "Enable control for the selected phone before starting a task.")
        }
        let run = UUID()
        token = run
        activePhoneID = phoneID
        self.planner = planner
        stepCount = 0
        proposal = nil
        state = .thinking
        append(.user, goal)
        worker = Task { [weak self] in await self?.run(goal: goal, phoneID: phoneID, planner: planner, token: run) }
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
        let phoneID = activePhoneID
        token = nil
        worker?.cancel()
        worker = nil
        planner?.cancel()
        planner = nil
        let waiter = approval
        approval = nil
        proposal = nil
        activePhoneID = nil
        waiter?.resume(returning: false)
        if let phoneID { controller.cancel(phoneID: phoneID) }
        state = .stopped
        append(.activity, "Stopped. Pending phone actions cancelled and held inputs released.")
    }

    public func clearMessages() {
        guard !state.isActive else { return }
        messages.removeAll()
        state = .idle
    }

    private func ensureCurrent(_ run: UUID) throws {
        try Task.checkCancellation()
        guard token == run else { throw CancellationError() }
    }

    private func freshScreenshot(phoneID: String, after: Date?, run: UUID) async throws -> Screenshot {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            try ensureCurrent(run)
            guard controller.phones.contains(where: { $0.id == phoneID && $0.status == .ready }) else {
                throw KitError("PHONE_NOT_READY", "The pinned phone is no longer ready. This task will not move to another phone.")
            }
            let screenshot = try await controller.screenshot(phoneID: phoneID, longEdge: 1344)
            try ensureCurrent(run)
            if after.map({ screenshot.capturedAt > $0 }) ?? true { return screenshot }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        throw KitError("SCREEN_NOT_UPDATED", "No post-action screen frame arrived. Inspect the phone; the action was not replayed.")
    }

    private func run(goal: String, phoneID: String, planner: any VisionPlanning, token run: UUID) async {
        defer {
            planner.cancel()
            if token == run {
                token = nil
                worker = nil
                self.planner = nil
                activePhoneID = nil
                let waiter = approval
                approval = nil
                proposal = nil
                waiter?.resume(returning: false)
            }
        }
        var history: [AgentHistoryItem] = []
        var after: Date?
        do {
            for index in 0..<maximumSteps {
                try ensureCurrent(run)
                state = .thinking
                stepCount = index + 1
                let screenshot = try await freshScreenshot(phoneID: phoneID, after: after, run: run)
                let step = try await planner.nextStep(goal: goal, screenshot: screenshot, history: history)
                try ensureCurrent(run)
                guard controller.phones.contains(where: { $0.id == phoneID && $0.status == .ready && $0.epoch == screenshot.epoch }) else {
                    throw KitError("CONNECTION_CHANGED", "The pinned phone changed while the model was thinking. No proposed action was sent.")
                }
                switch step {
                case .done(let message):
                    append(.assistant, message)
                    state = .completed
                    return
                case .ask(let message):
                    append(.assistant, message)
                    state = .needsInput
                    return
                case .action(var command, let reason):
                    command.screenshotID = command.action.usesCoordinates ? screenshot.id : nil
                    command.idempotencyKey = UUID().uuidString
                    command.deadline = nil
                    try command.validate(for: screenshot)
                    let pending = AgentProposal(phoneID: phoneID, screenshot: screenshot, command: command, reason: reason)
                    proposal = pending
                    state = .awaitingApproval
                    append(.assistant, reason)
                    let approved = await withCheckedContinuation { approval = $0 }
                    try ensureCurrent(run)
                    guard approved else {
                        controller.cancel(phoneID: phoneID)
                        state = .stopped
                        append(.activity, "Action rejected. Task stopped.")
                        return
                    }
                    guard controller.phones.contains(where: { $0.id == phoneID && $0.status == .ready && $0.epoch == screenshot.epoch }) else {
                        throw KitError("CONNECTION_CHANGED", "Phone connection changed during approval. Take a new screenshot and start again.")
                    }
                    guard now().timeIntervalSince(screenshot.capturedAt) <= 60 else {
                                            throw KitError("APPROVAL_EXPIRED", "The approved screenshot expired. Take a fresh screenshot and start again; no input was sent.")
                                        }
                                        command.deadline = now().addingTimeInterval(60)
                                        state = .executing
                    let result = try await controller.execute(phoneID: phoneID, command: command)
                    try ensureCurrent(run)
                    after = result.completedAt
                    history.append(AgentHistoryItem(action: CommandPresentation.text(command), outcome: "Input \(result.status). Verify in the next screenshot."))
                    append(.activity, "\(command.action.rawValue) \(result.status). Checking the next screen frame.")
                }
            }
            state = .needsInput
            append(.assistant, "Stopped at the \(maximumSteps)-step limit. Inspect the phone before continuing.")
        } catch is CancellationError {
            if token == run { state = .stopped; append(.activity, "Task cancelled.") }
        } catch {
            if token == run {
                controller.cancel(phoneID: phoneID)
                state = .failed
                let message = (error as? KitError)?.message ?? "The model request failed or timed out. No action was automatically retried."
                append(.assistant, message)
            }
        }
    }

    private func append(_ role: ChatEntry.Role, _ text: String) {
        messages.append(ChatEntry(role: role, text: String(text.prefix(4096))))
        if messages.count > 100 { messages.removeFirst(messages.count - 100) }
    }
}
