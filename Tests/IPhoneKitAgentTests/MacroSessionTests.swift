import AppKit
import Foundation
import Testing
import IPhoneKitCore
@testable import IPhoneKitAgent

@MainActor
private func generatedJPEG(token: String) -> Data {
    let width = 80
    let height = 160
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        preconditionFailure("Could not create the deterministic JPEG fixture.")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    let bytes = Array(token.utf8)
    for row in 0..<20 {
        for column in 0..<10 {
            let offset = (row * 10 + column) % max(bytes.count, 1)
            let seed = bytes.isEmpty ? 0 : Int(bytes[offset])
            let red = CGFloat((seed + row * 17 + column * 3) % 255) / 255
            let green = CGFloat((seed + row * 5 + column * 29) % 255) / 255
            let blue = CGFloat((seed + row * 31 + column * 7) % 255) / 255
            context.setFillColor(NSColor(red: red, green: green, blue: blue, alpha: 1).cgColor)
            context.fill(CGRect(x: column * 8, y: row * 8, width: 8, height: 8))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
        preconditionFailure("Could not encode the deterministic JPEG fixture.")
    }
    return data
}

@MainActor
private final class FakeMacroPhone: ExclusivePhoneControlling {
    let phoneID = "macro-phone"
    let baselineDate = Date(timeIntervalSince1970: 1_700_000_000)
    let baselineUptime: TimeInterval = 1_000
    var availablePhones: [PhoneInfo]
    var captures: [CaptureInfo] = []
    var events: [DiagnosticEvent] = []
    var permissionStatus: [String: String] = [:]
    var isDemo = true

    var now: Date
    var uptime: TimeInterval = 1_000
    var fallbackToken = "wrong" { didSet { currentImage = nil } }
    private var frameNumber = 0
    private var imageCache: [String: Data] = [:]
    private var currentImage: Data?
    private var insideGuard = false
    private var activeExecutions = 0
    var pendingTransportWrites = 0
    var supportsGuarded = true
    var advanceClockOnCapture = true
    var repeatGuardTimestamp = false
    var guardFrames: [Screenshot] = []
    private(set) var queuedScreenshots: [Screenshot] = []
    private(set) var screenshotRequests = 0
    var blockScreenshots = false
    private var screenshotWaiters: [CheckedContinuation<Screenshot, Never>] = []

    private(set) var commands: [PhoneCommand] = []
    private(set) var cancelCount = 0
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    var executeFailure: KitError?
    var beforeExecute: (@MainActor () -> Void)?
    var afterDispatch: (@MainActor () -> Void)?
    var nextStatus = "sent"
    var blockExecution = false
    private var executeWaiters: [(PhoneCommand, CheckedContinuation<ActionResult, Never>)] = []

    init() {
        availablePhones = [PhoneInfo(id: phoneID, name: "Macro fixture", status: .ready,
                                    width: 390, height: 844, captureID: "capture-1", epoch: 1)]
        now = baselineDate
    }

    var phones: [PhoneInfo] { availablePhones }
    var screenshotWaiterCount: Int { screenshotWaiters.count }
    var executeWaiterCount: Int { executeWaiters.count }

    func start() async {}
    func stop() async {}
    func prepare(phoneID: String) async throws {}
    func bindCapture(phoneID: String, captureID: String) throws {}
    func execute(phoneID: String, command: PhoneCommand) async throws -> ActionResult {
        prepareExecution()
        return try await executeLease(command)
    }
    func cancel(phoneID: String) { cancelCount += 1 }

    private func prepareExecution() {
        let hook = beforeExecute
        beforeExecute = nil
        hook?()
    }

    func acquireInput(phoneID: String) throws -> PhoneInputLease {
        guard availablePhones.contains(where: { phone in phone.id == phoneID && phone.status == .ready }) else {
            throw KitError("TEST_NO_PHONE", "The fixture phone is unavailable.")
        }
        acquireCount += 1
        var guarded: (@MainActor (PhoneCommand, GuardedInput) async throws -> ActionResult)?
        if supportsGuarded {
            guarded = { [weak self] command, authorization in
                guard let self else { throw KitError("TEST_LEASE_GONE", "The fixture lease disappeared.") }
                activeExecutions += 1
                defer { activeExecutions -= 1; insideGuard = false }
                prepareExecution()
                insideGuard = true
                try await authorization.authorize()
                insideGuard = false
                try Task.checkCancellation()
                try authorization.witness.beginDispatch()
                afterDispatch?()
                return try await executeLease(command)
            }
        }
        return PhoneInputLease(
            phoneID: phoneID,
            execute: { [weak self] command in
                guard let self else { throw KitError("TEST_LEASE_GONE", "The fixture lease disappeared.") }
                prepareExecution()
                return try await executeLease(command)
            },
            guardedExecute: guarded,
            isDrained: { [weak self] in
                guard let self else { return true }
                return activeExecutions == 0 && pendingTransportWrites == 0
            },
            cancel: { [weak self] in self?.cancelCount += 1 },
            release: { [weak self] in self?.releaseCount += 1 }
        )
    }

    func screenshot(phoneID: String, longEdge: Int) async throws -> Screenshot {
        screenshotRequests += 1
        if blockScreenshots {
            return await withCheckedContinuation { continuation in screenshotWaiters.append(continuation) }
        }
        if insideGuard {
            if !guardFrames.isEmpty { return deliver(guardFrames.removeFirst()) }
            frameNumber += 1
            let image = currentImage ?? jpeg(token: fallbackToken)
            let delta = repeatGuardTimestamp ? 0 : 0.001
            return deliver(frame(jpeg: image, id: "gate-\(frameNumber)", date: now.addingTimeInterval(delta),
                                 capturedUptime: uptime + delta))
        }
        if !queuedScreenshots.isEmpty { return deliver(queuedScreenshots.removeFirst()) }
        return deliver(makeFrame(token: fallbackToken))
    }

    private func deliver(_ frame: Screenshot) -> Screenshot {
        if advanceClockOnCapture {
            now = max(now, frame.capturedAt)
            uptime = max(uptime, frame.capturedUptime ?? uptime)
        }
        currentImage = frame.jpeg
        return frame
    }

    func enqueue(_ screenshot: Screenshot) { queuedScreenshots.append(screenshot) }

    func releaseScreenshots(token: String) {
        let waiters = screenshotWaiters
        screenshotWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: deliver(makeFrame(token: token))) }
    }

    func releaseExecutions(status: String = "sent") {
        let waiters = executeWaiters
        executeWaiters.removeAll()
        for (command, waiter) in waiters { waiter.resume(returning: result(for: command, status: status)) }
    }

    private func jpeg(token: String) -> Data {
        let image = imageCache[token] ?? generatedJPEG(token: token)
        imageCache[token] = image
        return image
    }

    private func frame(jpeg: Data, id: String, date: Date, capturedUptime: TimeInterval?) -> Screenshot {
        let info = availablePhones.first(where: { phone in phone.id == phoneID })
        let width = info?.width ?? 390
        let height = info?.height ?? 844
        return Screenshot(id: id, phoneID: phoneID, epoch: info?.epoch ?? 1,
                          width: width, height: height, nativeWidth: width, nativeHeight: height,
                          capturedAt: date, jpeg: jpeg, capturedUptime: capturedUptime)
    }

    func makeFrame(token: String, id: String? = nil, capturedAt: Date? = nil,
                   capturedUptime: TimeInterval? = nil) -> Screenshot {
        frameNumber += 1
        let stamp = capturedUptime ?? capturedAt.map { date in baselineUptime + date.timeIntervalSince(baselineDate) }
            ?? max(baselineUptime + Double(frameNumber) / 100, uptime + 0.01)
        let date = capturedAt ?? now.addingTimeInterval(stamp - uptime)
        return frame(jpeg: jpeg(token: token), id: id ?? "frame-\(frameNumber)", date: date, capturedUptime: stamp)
    }

    private func result(for command: PhoneCommand, status: String) -> ActionResult {
        ActionResult(phoneID: phoneID, action: command.action, status: status,
                     startedAt: now, completedAt: now, epoch: availablePhones.first?.epoch ?? 1,
                     completedUptime: uptime)
    }

    private func executeLease(_ command: PhoneCommand) async throws -> ActionResult {
        commands.append(command)
        if let executeFailure { throw executeFailure }
        if blockExecution {
            return await withCheckedContinuation { continuation in executeWaiters.append((command, continuation)) }
        }
        return result(for: command, status: nextStatus)
    }
}

private actor FakeMacroMatcher: VisualMatching {
    private(set) var receivedScreenshotIDs: [String] = []
    private(set) var calls = 0
    private var suspendNext = false
        private var contextResult: Bool?

    func setContextResult(_ value: Bool?) { contextResult = value }

    func matchesContext(_ anchor: VisualAnchor, screenshot: Screenshot) async throws -> Bool {
            contextResult ?? (anchor.image == screenshot.jpeg)
        }
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    var waiting: Bool { !waiters.isEmpty }

    func suspendNextMatch() { suspendNext = true }

    func matches(_ anchor: VisualAnchor, screenshot: Screenshot) async throws -> Bool {
        calls += 1
        receivedScreenshotIDs.append(screenshot.id)
        if suspendNext {
            suspendNext = false
            return await withCheckedContinuation { waiters.append($0) }
        }
        // The expected text is a state token; image equality is the deterministic
        // token check. No OCR or real phone is involved in these runner regressions.
        return !anchor.expectedText.isEmpty && anchor.image == screenshot.jpeg
    }

    func releaseAll(_ value: Bool = false) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool,
                       timeout: Duration = .seconds(2)) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw KitError("TEST_TIMEOUT", "Macro session did not settle.")
        }
        await Task.yield()
    }
}

@MainActor
private func waitUntilAsync(_ condition: @escaping @MainActor () async -> Bool,
                            timeout: Duration = .seconds(2)) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            throw KitError("TEST_TIMEOUT", "Macro session did not settle.")
        }
        await Task.yield()
    }
}

@MainActor
private func makeStep(_ controller: FakeMacroPhone, name: String,
                      before: String, after: String,
                      requiresApproval: Bool = true,
                      timeout: Double = 0.2) throws -> MacroStep {
    let recorded = controller.makeFrame(token: before)
    let beforeAnchor = try VisualAnchor(screenshot: recorded, expectedText: before)
    let afterRecorded = controller.makeFrame(token: after)
    let afterAnchor = try VisualAnchor(screenshot: afterRecorded, expectedText: after)
    let gesture = try MacroGesture(
        command: PhoneCommand(action: .tap, x: 120, y: 300),
        screenshot: recorded
    )
    return MacroStep(name: name, gesture: gesture, before: beforeAnchor, after: afterAnchor,
                     delaySeconds: 0, timeoutSeconds: timeout, requiresApproval: requiresApproval)
}

@MainActor
private func makeProfile(_ steps: [MacroStep], maximumActions: Int = 20,
                         maximumSeconds: Double = 5) -> MacroProfile {
    MacroProfile(name: "Regression macro", phoneID: "macro-phone",
                 nativeWidth: 390, nativeHeight: 844, steps: steps,
                 repetitions: 1, maximumActions: maximumActions,
                 maximumSeconds: maximumSeconds)
}

@Test @MainActor
func approvedExecutionUsesFreshLiveFramesAndBoundedUniqueCommands() async throws {
    let controller = FakeMacroPhone()
    let matcher = FakeMacroMatcher()
    let first = try makeStep(controller, name: "First", before: "before-1", after: "after-1")
    let second = try makeStep(controller, name: "Second", before: "before-2", after: "after-2")
    let profile = makeProfile([first, second], maximumActions: 2)

    let firstProposalFrame = controller.makeFrame(token: "before-1")
    let firstLiveFrame = controller.makeFrame(token: "before-1")
    let firstAfterFrame = controller.makeFrame(token: "after-1")
    let secondProposalFrame = controller.makeFrame(token: "before-2")
    let secondLiveFrame = controller.makeFrame(token: "before-2")
    let secondAfterFrame = controller.makeFrame(token: "after-2")
    [firstProposalFrame, firstLiveFrame, firstAfterFrame,
     secondProposalFrame, secondLiveFrame, secondAfterFrame].forEach(controller.enqueue)

    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })
    try session.start(profile: profile, phoneID: controller.phoneID)
    try await waitUntil { session.state == .awaitingApproval }
    let firstProposal = try #require(session.proposal)
    #expect(firstProposal.screenshot.id == firstProposalFrame.id)
    session.decide(proposalID: firstProposal.id, allow: true)

    try await waitUntil { session.state == .awaitingApproval && session.stepIndex == 2 }
    let secondProposal = try #require(session.proposal)
    #expect(secondProposal.screenshot.id == secondProposalFrame.id)
    session.decide(proposalID: secondProposal.id, allow: true)
    try await waitUntil { session.state == .completed }

    #expect(controller.commands.count == 2)
    #expect(controller.commands[0].screenshotID == firstLiveFrame.id)
    #expect(controller.commands[1].screenshotID == secondLiveFrame.id)
    #expect(Set(controller.commands.compactMap(\.screenshotID)).count == 2)
    #expect(Set(controller.commands.compactMap(\.idempotencyKey)).count == 2)
    #expect(session.actionCount == 2)
    #expect(controller.commands.allSatisfy { $0.screenshotID != firstProposalFrame.id && $0.screenshotID != secondProposalFrame.id })
}

@Test @MainActor
func beforeMismatchTimesOutWithoutExecutingOrReplaying() async throws {
    let controller = FakeMacroPhone()
    controller.fallbackToken = "not-before"
    let matcher = FakeMacroMatcher()
    let step = try makeStep(controller, name: "Guarded", before: "expected", after: "after", requiresApproval: false)
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })

    try session.start(profile: makeProfile([step]), phoneID: controller.phoneID)
    try await waitUntil { session.state == .paused }
    #expect(controller.commands.isEmpty)
}

@Test @MainActor
func pollingUsesSeveralFreshFramesBeforeTheMatch() async throws {
    let controller = FakeMacroPhone()
    let matcher = FakeMacroMatcher()
    let step = try makeStep(controller, name: "Poll", before: "wanted", after: "done", requiresApproval: false)
    let wrongOne = controller.makeFrame(token: "wrong-1")
    let wrongTwo = controller.makeFrame(token: "wrong-2")
    let matching = controller.makeFrame(token: "wanted")
    let after = controller.makeFrame(token: "done")
    [wrongOne, wrongTwo, matching, after].forEach(controller.enqueue)
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })

    try session.start(profile: makeProfile([step]), phoneID: controller.phoneID)
    try await waitUntil { session.state == .completed }
    let ids = await matcher.receivedScreenshotIDs
    #expect(ids.prefix(3) == [wrongOne.id, wrongTwo.id, matching.id])
    #expect(Set(ids).count == ids.count)
    #expect(controller.commands.count == 1)
    #expect(controller.commands[0].screenshotID == matching.id)
}

@Test @MainActor
func uncertainInputOutcomeIsNeverReplayed() async throws {
    let controller = FakeMacroPhone()
    controller.nextStatus = "unknown"
    let matcher = FakeMacroMatcher()
    let step = try makeStep(controller, name: "Uncertain", before: "before", after: "after", requiresApproval: false)
    controller.enqueue(controller.makeFrame(token: "before"))
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })

    try session.start(profile: makeProfile([step]), phoneID: controller.phoneID)
    try await waitUntil { session.state == .paused }
    #expect(controller.commands.count == 1)
    #expect(session.actionCount == 1)
    #expect(session.message.contains("uncertain") || session.message.contains("No action"))
}

@Test @MainActor
func stopDuringScreenshotPreventsLaterInput() async throws {
    let controller = FakeMacroPhone()
    controller.blockScreenshots = true
    let matcher = FakeMacroMatcher()
    let step = try makeStep(controller, name: "Screenshot gate", before: "before", after: "after", requiresApproval: false)
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })

    try session.start(profile: makeProfile([step]), phoneID: controller.phoneID)
    try await waitUntil { controller.screenshotWaiterCount == 1 }
    session.stop()
    controller.releaseScreenshots(token: "before")
    try await waitUntil { session.state == .stopped }
    await Task.yield()
    #expect(controller.commands.isEmpty)
    #expect(controller.cancelCount > 0)
}

@Test @MainActor
func stopDuringMatchingPreventsLaterInput() async throws {
    let controller = FakeMacroPhone()
    let matcher = FakeMacroMatcher()
    await matcher.suspendNextMatch()
    let step = try makeStep(controller, name: "Matcher gate", before: "before", after: "after", requiresApproval: false)
    controller.enqueue(controller.makeFrame(token: "before"))
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })

    try session.start(profile: makeProfile([step]), phoneID: controller.phoneID)
    try await waitUntilAsync { await matcher.waiting }
    session.stop()
    await matcher.releaseAll()
    try await waitUntil { session.state == .stopped }
    #expect(controller.commands.isEmpty)
}

@Test @MainActor
func stopDuringApprovalRejectsStaleApprovalAndDoesNotApproveNewRun() async throws {
    let controller = FakeMacroPhone()
    let matcher = FakeMacroMatcher()
    let step = try makeStep(controller, name: "Approval one", before: "one", after: "one-done")
    controller.enqueue(controller.makeFrame(token: "one"))
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })
    try session.start(profile: makeProfile([step]), phoneID: controller.phoneID)
    try await waitUntil { session.state == .awaitingApproval }
    let staleID = try #require(session.proposal?.id)
    session.stop()

    try await waitUntil { session.state == .stopped }
        let replacement = try makeStep(controller, name: "Approval two", before: "two", after: "two-done")
    let replacementFrame = controller.makeFrame(token: "two")
    let replacementLive = controller.makeFrame(token: "two")
    let replacementAfter = controller.makeFrame(token: "two-done")
    [replacementFrame, replacementLive, replacementAfter].forEach(controller.enqueue)
    try session.start(profile: makeProfile([replacement]), phoneID: controller.phoneID)
    try await waitUntil { session.state == .awaitingApproval }
    let currentID = try #require(session.proposal?.id)
    session.decide(proposalID: staleID, allow: true)
    await Task.yield()
    #expect(session.proposal?.id == currentID)
    #expect(controller.commands.isEmpty)
    session.decide(proposalID: currentID, allow: true)
    try await waitUntil { session.state == .completed }
    #expect(controller.commands.count == 1)
}

@Test @MainActor func stoppingWaitsForOldWorkBeforeStartingNewRun() async throws {
    let controller = FakeMacroPhone()
    let matcher = FakeMacroMatcher()
    await matcher.suspendNextMatch()
    let oldStep = try makeStep(controller, name: "Old", before: "old", after: "old-done", requiresApproval: false)
    controller.enqueue(controller.makeFrame(token: "old"))
    let session = MacroSession(controller: controller, matcher: matcher,
                               pollInterval: .milliseconds(1), now: { controller.now }, uptime: { controller.uptime })
    try session.start(profile: makeProfile([oldStep]), phoneID: controller.phoneID)
    try await waitUntilAsync { await matcher.waiting }
    session.stop()
    let frozen = try #require(session.recovery)
    #expect(session.state == .stopping)
    #expect(frozen.outcome == .notDispatched)
    let newStep = try makeStep(controller, name: "New", before: "new", after: "new-done", requiresApproval: false)
    #expect(throws: KitError.self) { try session.start(profile: makeProfile([newStep]), phoneID: controller.phoneID) }
    await matcher.releaseAll()
    try await waitUntil { session.state == .stopped }
    #expect(session.recovery == frozen)
    #expect(controller.commands.isEmpty)
    let newBefore = controller.makeFrame(token: "new")
    let newAfter = controller.makeFrame(token: "new-done")
    [newBefore, newAfter].forEach(controller.enqueue)
    try session.start(profile: makeProfile([newStep]), phoneID: controller.phoneID)
    try await waitUntil { session.state == .completed }
    #expect(controller.commands.count == 1)
    #expect(controller.commands[0].screenshotID == newBefore.id)
    #expect(session.recovery == nil)
}

@MainActor
private func assertPinnedChange(_ change: (FakeMacroPhone) -> Void) async throws {
    let controller = FakeMacroPhone()
    let matcher = FakeMacroMatcher()
    let step = try makeStep(controller, name: "Pinned", before: "before", after: "after")
    controller.enqueue(controller.makeFrame(token: "before"))
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })
    try session.start(profile: makeProfile([step]), phoneID: controller.phoneID)
    try await waitUntil { session.state == .awaitingApproval }
    change(controller)
    session.decide(proposalID: try #require(session.proposal?.id), allow: true)
    try await waitUntil { session.state == .paused }
    #expect(controller.commands.isEmpty)
}

@Test @MainActor
func changedEpochIsRejectedBeforeInput() async throws {
    try await assertPinnedChange { controller in controller.availablePhones[0].epoch = 2 }
}

@Test @MainActor
func changedDimensionsAreRejectedBeforeInput() async throws {
    try await assertPinnedChange { controller in controller.availablePhones[0].width = 391 }
}

@Test @MainActor
func changedScreenSourceIsRejectedBeforeInput() async throws {
    try await assertPinnedChange { controller in controller.availablePhones[0].captureID = "capture-2" }
}

@Test @MainActor
func changedPhoneIdentityIsRejectedBeforeInput() async throws {
    try await assertPinnedChange { controller in
        controller.availablePhones = [PhoneInfo(id: "another-phone", name: "Replacement", status: .ready,
                                                width: 390, height: 844, captureID: "capture-1", epoch: 1)]
    }
}

@Test @MainActor
func bufferedOldFrameWithNewIDCannotVerifyAfterAction() async throws {
    let controller = FakeMacroPhone()
    controller.fallbackToken = "wrong"
    let matcher = FakeMacroMatcher()
    let step = try makeStep(controller, name: "Buffered", before: "before", after: "after", requiresApproval: false)
    let before = controller.makeFrame(token: "before")
    let staleAfter = controller.makeFrame(token: "after", capturedAt: controller.now)
    let freshWrong = controller.makeFrame(token: "wrong")
    [before, staleAfter, freshWrong].forEach(controller.enqueue)
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })

    try session.start(profile: makeProfile([step]), phoneID: controller.phoneID)
    try await waitUntil { session.state == .paused }
    #expect(staleAfter.id != freshWrong.id)
    #expect(controller.commands.count == 1)
    let ids = await matcher.receivedScreenshotIDs
    #expect(!ids.contains(staleAfter.id))
}

@Test @MainActor
func approvalRechecksTheScreenBeforeSending() async throws {
    let controller = FakeMacroPhone()
    controller.fallbackToken = "changed"
    let matcher = FakeMacroMatcher()
    let step = try makeStep(controller, name: "Recheck", before: "before", after: "after")
    let proposalFrame = controller.makeFrame(token: "before")
    let changedFrame = controller.makeFrame(token: "changed")
    [proposalFrame, changedFrame].forEach(controller.enqueue)
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })

    try session.start(profile: makeProfile([step]), phoneID: controller.phoneID)
    try await waitUntil { session.state == .awaitingApproval }
    session.decide(proposalID: try #require(session.proposal?.id), allow: true)
    try await waitUntil { session.state == .paused }
    #expect(controller.commands.isEmpty)
    #expect(await matcher.calls >= 2)
}

@Test @MainActor
func maximumActionsStopsBeforeASecondProposal() async throws {
    let controller = FakeMacroPhone()
    let matcher = FakeMacroMatcher()
    let first = try makeStep(controller, name: "Only action", before: "one", after: "one-done")
    let second = try makeStep(controller, name: "Budgeted out", before: "two", after: "two-done")
    let firstProposal = controller.makeFrame(token: "one")
    let firstLive = controller.makeFrame(token: "one")
    let firstAfter = controller.makeFrame(token: "one-done")
    [firstProposal, firstLive, firstAfter].forEach(controller.enqueue)
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })

    try session.start(profile: makeProfile([first, second], maximumActions: 1), phoneID: controller.phoneID)
    try await waitUntil { session.state == .awaitingApproval }
    session.decide(proposalID: try #require(session.proposal?.id), allow: true)
    try await waitUntil { session.state == .completed }
    #expect(controller.commands.count == 1)
    #expect(session.actionCount == 1)
    #expect(session.proposal == nil)
    #expect(session.message.contains("1-action"))
}

@Test @MainActor
func timeBudgetContinuesWhileApprovalIsPending() async throws {
    let controller = FakeMacroPhone()
    let matcher = FakeMacroMatcher()
    let step = try makeStep(controller, name: "Timed approval", before: "before", after: "after")
    controller.enqueue(controller.makeFrame(token: "before"))
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })

    try session.start(profile: makeProfile([step], maximumSeconds: 5), phoneID: controller.phoneID)
    try await waitUntil { session.state == .awaitingApproval }
    let staleID = try #require(session.proposal?.id)
    try await Task.sleep(for: .seconds(5.25))
    try await waitUntil { session.state == .paused }
    session.decide(proposalID: staleID, allow: true)
    #expect(controller.commands.isEmpty)
    #expect(session.message.contains("time limit"))
}

@Test @MainActor
func stopConditionCompletesBeforeAnyInput() async throws {
    let controller = FakeMacroPhone()
    let matcher = FakeMacroMatcher()
    let step = try makeStep(controller, name: "Should not run", before: "before", after: "after", requiresApproval: false)
    let stopFrame = controller.makeFrame(token: "stop")
    controller.enqueue(stopFrame)
    var profile = makeProfile([step])
    profile.stopWhen = try VisualAnchor(screenshot: stopFrame, expectedText: "stop")
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })

    try session.start(profile: profile, phoneID: controller.phoneID)
    try await waitUntil { session.state == .completed }
    #expect(controller.commands.isEmpty)
    #expect(session.actionCount == 0)
    #expect(session.message.contains("stop screen"))
}

@Test @MainActor func stopDuringExecutePreventsSubsequentActions() async throws {
    let controller = FakeMacroPhone()
    controller.blockExecution = true
    let matcher = FakeMacroMatcher()
    let first = try makeStep(controller, name: "In flight", before: "one", after: "one-done", requiresApproval: false)
    let second = try makeStep(controller, name: "Must not run", before: "two", after: "two-done", requiresApproval: false)
    controller.enqueue(controller.makeFrame(token: "one"))
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })

    try session.start(profile: makeProfile([first, second]), phoneID: controller.phoneID)
    try await waitUntil { controller.executeWaiterCount == 1 }
    session.stop()
    controller.releaseExecutions()
    try await waitUntil { session.state == .stopped }
    #expect(controller.commands.count == 1)
    #expect(session.actionCount == 1)

}

@Test @MainActor func changedScreenAtDispatchDoesNotSendInput() async throws {
    let controller = FakeMacroPhone()
    controller.fallbackToken = "before"
    controller.beforeExecute = {
        controller.fallbackToken = "overlay"
        controller.nextStatus = "unknown"
    }
    let matcher = FakeMacroMatcher()
    let step = try makeStep(controller, name: "Guarded dispatch", before: "before", after: "after", requiresApproval: false)
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })
    try session.start(profile: makeProfile([step]), phoneID: controller.phoneID)
    try await waitUntil { session.state == .paused }
    #expect(controller.commands.isEmpty)
    #expect(session.actionCount == 0)
}

@Test @MainActor func macroErrorsDoNotExposeRawFailureText() async throws {
    let controller = FakeMacroPhone()
    controller.fallbackToken = "before"
    let canary = "private-failure-canary@example.invalid"
    controller.executeFailure = KitError("UNRECOGNIZED_BACKEND", canary)
    let matcher = FakeMacroMatcher()
    let step = try makeStep(controller, name: "Private step", before: "before", after: "after", requiresApproval: false)
    let session = MacroSession(controller: controller, matcher: matcher, pollInterval: .milliseconds(1), now: { controller.now },
                                   uptime: { controller.uptime })
    try session.start(profile: makeProfile([step]), phoneID: controller.phoneID)
    try await waitUntil { session.state == .paused }
    #expect(!session.message.contains(canary))
}
