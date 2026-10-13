import Foundation
import Testing
import IPhoneKitCore
@testable import IPhoneKitAgent

@MainActor private final class SpyPhone: PhoneControlling {
    var phones = [PhoneInfo(id: "a", name: "Test phone", status: .ready, width: 390, height: 844, epoch: 1), PhoneInfo(id: "b", name: "Other phone", status: .ready, epoch: 1)]
    var captures: [CaptureInfo] = []
    var events: [DiagnosticEvent] = []
    var permissionStatus: [String: String] = [:]
    var isDemo = true
    var executions: [(String, PhoneCommand)] = []
    var cancelled: [String] = []
    var screenshotIDs: [String] = []
    var executeError: KitError?
    func start() async {}
    func stop() async {}
    func prepare(phoneID: String) async throws {}
    func bindCapture(phoneID: String, captureID: String) throws {}
    func cancel(phoneID: String) { cancelled.append(phoneID) }
    func screenshot(phoneID: String, longEdge: Int) async throws -> Screenshot {
        let id = UUID().uuidString
        screenshotIDs.append(id)
        return Screenshot(id: id, phoneID: phoneID, epoch: phones.first(where: { $0.id == phoneID })!.epoch, width: 621, height: 1344,
                          nativeWidth: 1170, nativeHeight: 2532, capturedAt: Date(), jpeg: Data([1]))
    }
    func execute(phoneID: String, command: PhoneCommand) async throws -> ActionResult {
        executions.append((phoneID, command))
        if let executeError { throw executeError }
        return ActionResult(phoneID: phoneID, action: command.action, startedAt: Date(), epoch: 1)
    }
}

private actor SequencePlanner: VisionPlanning {
    var steps: [AgentStep]
    var calls = 0
    init(_ steps: [AgentStep]) { self.steps = steps }
    func nextStep(goal: String, screenshot: Screenshot, history: [AgentHistoryItem]) async throws -> AgentStep {
        calls += 1
        return steps.isEmpty ? .done("done") : steps.removeFirst()
    }
}

private actor GatedPlanner: VisionPlanning {
    var waiter: CheckedContinuation<AgentStep, Never>?
    func nextStep(goal: String, screenshot: Screenshot, history: [AgentHistoryItem]) async throws -> AgentStep {
        await withCheckedContinuation { waiter = $0 }
    }
    func resolve(_ value: AgentStep) { let pending = waiter; waiter = nil; pending?.resume(returning: value) }
    var waiting: Bool { waiter != nil }
}

@MainActor private func waitFor(_ condition: () -> Bool) async throws {
    let limit = ContinuousClock.now + .seconds(2)
    while !condition() {
        guard ContinuousClock.now < limit else { throw KitError("TEST_TIMEOUT", "State did not settle.") }
        await Task.yield()
    }
}

@Test @MainActor func everyMutationRequiresExactApproval() async throws {
    let phone = SpyPhone()
    let planner = SequencePlanner([.action(PhoneCommand(action: .tap, x: 10, y: 20), reason: "tap"), .done("verified")])
    let session = AgentSession(controller: phone)
    #expect(await planner.calls == 0)
    try session.start(goal: "task", phoneID: "a", planner: planner)
    try await waitFor { session.state == .awaitingApproval }
    #expect(phone.executions.isEmpty)
    let proposal = try #require(session.proposal)
    session.decide(proposalID: UUID(), allow: true)
    #expect(phone.executions.isEmpty)
    session.decide(proposalID: proposal.id, allow: true)
    try await waitFor { session.state == .completed }
    #expect(phone.executions.count == 1)
    #expect(phone.executions[0].0 == "a")
    #expect(phone.executions[0].1.screenshotID == proposal.screenshot.id)
    #expect(phone.executions[0].1.idempotencyKey != nil)
    #expect(phone.screenshotIDs.count == 2)
}

@Test @MainActor func stopDuringApprovalCannotActLater() async throws {
    let phone = SpyPhone()
    let session = AgentSession(controller: phone)
    try session.start(goal: "task", phoneID: "a", planner: SequencePlanner([.action(PhoneCommand(action: .tap, x: 1, y: 1), reason: "tap")]))
    try await waitFor { session.state == .awaitingApproval }
    let id = try #require(session.proposal?.id)
    session.stop()
    session.decide(proposalID: id, allow: true)
    await Task.yield()
    #expect(phone.executions.isEmpty)
    #expect(phone.cancelled == ["a"])
    #expect(session.state == .stopped)
}

@Test @MainActor func lateModelReplyCannotCancelOrMutateNewRun() async throws {
    let phone = SpyPhone()
    let oldPlanner = GatedPlanner()
    let session = AgentSession(controller: phone)
    try session.start(goal: "first", phoneID: "a", planner: oldPlanner)
    let limit = ContinuousClock.now + .seconds(2)
    while !(await oldPlanner.waiting), ContinuousClock.now < limit { await Task.yield() }
    session.stop()
    try session.start(goal: "second", phoneID: "b", planner: SequencePlanner([.action(PhoneCommand(action: .pressHome), reason: "home"), .done("done")]))
    try await waitFor { session.state == .awaitingApproval }
    let newProposal = try #require(session.proposal)
    await oldPlanner.resolve(.action(PhoneCommand(action: .tap, x: 1, y: 1), reason: "stale"))
    await Task.yield()
    #expect(session.proposal?.id == newProposal.id)
    #expect(phone.cancelled == ["a"])
    session.decide(proposalID: newProposal.id, allow: true)
    try await waitFor { session.state == .completed }
    #expect(phone.executions.map { $0.0 } == ["b"])
}

@Test @MainActor func changedEpochDuringApprovalFailsClosed() async throws {
    let phone = SpyPhone()
    let session = AgentSession(controller: phone)
    try session.start(goal: "task", phoneID: "a", planner: SequencePlanner([.action(PhoneCommand(action: .tap, x: 1, y: 1), reason: "tap")]))
    try await waitFor { session.state == .awaitingApproval }
    let id = try #require(session.proposal?.id)
    phone.phones[0].epoch = 2
    session.decide(proposalID: id, allow: true)
    try await waitFor { session.state == .failed }
    #expect(phone.executions.isEmpty)
}

@Test @MainActor func expiredApprovalNeverSendsEvenKeyboardInput() async throws {
    let phone = SpyPhone()
    var clock = Date()
    let session = AgentSession(controller: phone, now: { clock })
    try session.start(goal: "task", phoneID: "a", planner: SequencePlanner([.action(PhoneCommand(action: .pressHome), reason: "home")]))
    try await waitFor { session.state == .awaitingApproval }
    let proposal = try #require(session.proposal)
    #expect(proposal.command.deadline == nil)
    clock = proposal.screenshot.capturedAt.addingTimeInterval(61)
    session.decide(proposalID: proposal.id, allow: true)
    try await waitFor { session.state == .failed }
    #expect(phone.executions.isEmpty)
    #expect(session.messages.last?.text.contains("expired") == true)
}

@Test @MainActor func uncertainActionIsNeverReplayed() async throws {
    let phone = SpyPhone()
    phone.executeError = KitError("ACTION_INTERRUPTED", "Uncertain delivery.")
    let planner = SequencePlanner([.action(PhoneCommand(action: .pressHome), reason: "home")])
    let session = AgentSession(controller: phone)
    try session.start(goal: "task", phoneID: "a", planner: planner)
    try await waitFor { session.state == .awaitingApproval }
    session.decide(proposalID: try #require(session.proposal?.id), allow: true)
    try await waitFor { session.state == .failed }
    #expect(phone.executions.count == 1)
    #expect(await planner.calls == 1)
}

@Test @MainActor func stepBudgetAndAskDoNotExecuteExtraInput() async throws {
    let phone = SpyPhone()
    let planner = SequencePlanner([.action(PhoneCommand(action: .pressHome), reason: "home"), .action(PhoneCommand(action: .pressHome), reason: "again")])
    let session = AgentSession(controller: phone, maximumSteps: 1)
    try session.start(goal: "task", phoneID: "a", planner: planner)
    try await waitFor { session.state == .awaitingApproval }
    session.decide(proposalID: try #require(session.proposal?.id), allow: true)
    try await waitFor { session.state == .needsInput }
    #expect(await planner.calls == 1)
    #expect(phone.executions.count == 1)
    try session.start(goal: "question", phoneID: "a", planner: SequencePlanner([.ask("Need help")]))
    try await waitFor { session.state == .needsInput }
    #expect(phone.executions.count == 1)
}
