import Foundation
import Observation
import IPhoneKitCore
import IPhoneKitAgent

@Observable @MainActor
final class MacroWorkspace {
    let runner: MacroSession
    private(set) var profiles: [MacroProfile] = []
    var draft = MacroProfile(name: "New game profile", phoneID: "", nativeWidth: 0, nativeHeight: 0)
    private(set) var recordingPhoneID: String?
    private(set) var recordingAction = false
    private(set) var waitingForResult = false
    private(set) var message = "Create a profile for a portrait game. Everything stays on this Mac."
    private(set) var storageError: String?

    @ObservationIgnored private let controller: any ExclusivePhoneControlling
    @ObservationIgnored private let store: MacroStore
    @ObservationIgnored private let matcher = LocalVisualMatcher()
    @ObservationIgnored private var recordingToken: UUID?
    @ObservationIgnored private var input: PhoneInputLease?
    @ObservationIgnored private var recordedPhone: PhoneInfo?
    @ObservationIgnored private var pending: Pending?

    private struct Pending {
        let gesture: MacroGesture
        let before: VisualAnchor
        let completedAt: Date
    }

    var isRecording: Bool { recordingToken != nil }
    var isBusy: Bool { isRecording || runner.state.isActive }

    init(controller: any ExclusivePhoneControlling, store: MacroStore = MacroStore()) {
        self.controller = controller
        self.store = store
        runner = MacroSession(controller: controller)
        do {
            profiles = try store.load()
            if let first = profiles.first { draft = first }
        } catch {
            storageError = error.localizedDescription
            message = "Saved profiles could not be loaded. The existing file will not be overwritten."
        }
    }

    func newProfile(phone: PhoneInfo) {
        guard !isBusy else { return }
        draft = MacroProfile(name: "My game", phoneID: phone.id, nativeWidth: phone.width, nativeHeight: phone.height)
        message = "Open a portrait game, then record one short action at a time."
    }

    func selectProfile(_ id: UUID) {
        guard !isBusy, let profile = profiles.first(where: { $0.id == id }) else { return }
        draft = profile
    }

    func save() throws {
        guard storageError == nil else { throw KitError("MACRO_STORAGE", "Resolve the saved-profile read error before saving. The original file is preserved.") }
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == draft.id }) { updated[index] = draft }
        else { updated.append(draft) }
        try store.save(updated)
        profiles = updated
        message = "Profile saved locally. Screenshots are included; avoid recording private screens."
    }

    func beginRecording(phone: PhoneInfo) throws {
        guard !isBusy else { throw KitError("MACRO_BUSY", "Stop the current recording or run first.") }
        guard draft.phoneID == phone.id, phone.status == .ready,
              phone.width == draft.nativeWidth, phone.height == draft.nativeHeight,
              phone.width > 0, phone.width < phone.height else {
            throw KitError("MACRO_PHONE_CHANGED", "Create or select a profile for this phone in portrait orientation.")
        }
        guard draft.steps.count < 20 else { throw KitError("MACRO_STEP_LIMIT", "A profile can contain at most 20 steps.") }
        input = try controller.acquireInput(phoneID: phone.id)
        recordedPhone = phone
        recordingToken = UUID()
        recordingPhoneID = phone.id
        pending = nil
        waitingForResult = false
        message = "Recording. Tap or drag on the phone preview, then capture the visible result."
    }

    func finishRecording() {
        guard !recordingAction, !waitingForResult else { return }
        input?.release()
        clearRecording()
        message = "Recording finished. Review guards, approvals, and limits; save before running."
    }

    func stop() {
        runner.stop()
        input?.cancel()
        input?.release()
        clearRecording()
        message = "Stopped. Any unfinished recorded step was discarded; completed steps remain."
    }

    private func clearRecording() {
        recordingToken = nil
        recordingPhoneID = nil
        recordedPhone = nil
        input = nil
        pending = nil
        recordingAction = false
        waitingForResult = false
    }

    private func checkRecording(_ token: UUID) throws {
        try Task.checkCancellation()
        guard recordingToken == token, let pinned = recordedPhone else { throw CancellationError() }
        guard let phone = controller.phones.first(where: { $0.id == pinned.id }),
              phone.status == .ready, phone.epoch == pinned.epoch, phone.captureID == pinned.captureID,
              phone.width == pinned.width, phone.height == pinned.height else {
            throw KitError("MACRO_CONNECTION_CHANGED", "The recorded phone or connection changed. Stop and inspect the phone.")
        }
    }

    private func frame(after: Date, token: UUID) async throws -> Screenshot {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            try checkRecording(token)
            guard let pinned = recordedPhone else { throw CancellationError() }
            let shot = try await controller.screenshot(phoneID: pinned.id, longEdge: 900)
            try checkRecording(token)
            guard shot.phoneID == pinned.id, shot.epoch == pinned.epoch,
                  shot.nativeWidth == pinned.width, shot.nativeHeight == pinned.height else {
                throw KitError("MACRO_FRAME_CHANGED", "Captured screen does not match the recorded phone.")
            }
            let age = Date().timeIntervalSince(shot.capturedAt)
            if shot.capturedAt > after, age >= -0.5, age <= 1 { return shot }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw KitError("MACRO_STALE_FRAME", "No fresh frame arrived. Stop and inspect the phone; input was not replayed.")
    }

    func record(_ command: PhoneCommand, screenshot: Screenshot) async throws {
        guard let token = recordingToken, let input, !recordingAction, pending == nil else {
            throw KitError("MACRO_RECORDING_BUSY", "Capture the result of the previous action first.")
        }
        guard draft.steps.count < 20 else { throw KitError("MACRO_STEP_LIMIT", "A profile can contain at most 20 steps.") }
        try checkRecording(token)
        guard screenshot.phoneID == recordingPhoneID, screenshot.epoch == recordedPhone?.epoch,
              Date().timeIntervalSince(screenshot.capturedAt) <= 2 else {
            throw KitError("MACRO_STALE_FRAME", "Wait for the preview to refresh before recording a gesture.")
        }
        let gesture = try MacroGesture(command: command, screenshot: screenshot)
        recordingAction = true
        defer { if recordingToken == token { recordingAction = false } }
        do {
            let before = try await frame(after: Date(), token: token)
            let previewGuard = try VisualAnchor(screenshot: screenshot)
            let unchanged = try await matcher.matches(previewGuard, screenshot: before)
            try checkRecording(token)
            guard unchanged, Date().timeIntervalSince(before.capturedAt) <= 1 else {
                throw KitError("MACRO_SCREEN_CHANGED", "The preview changed before the gesture. No input sent; inspect and try again.")
            }
            let anchor = try VisualAnchor(screenshot: before)
            var liveCommand = try gesture.command(for: before)
            liveCommand.deadline = Date().addingTimeInterval(30)
            let result = try await input.execute(liveCommand)
            try checkRecording(token)
            guard result.phoneID == before.phoneID, result.epoch == before.epoch,
                  ["sent", "simulated"].contains(result.status) else {
                throw KitError("MACRO_UNCERTAIN", "Input outcome is uncertain. Stop and inspect; it will not be recorded or replayed.")
            }
            pending = Pending(gesture: gesture, before: anchor, completedAt: result.completedAt)
            waitingForResult = true
            message = "Wait for the intended result on the phone, then click Capture result. No more input until then."
        } catch {
            if recordingToken == token {
                input.cancel()
                input.release()
                clearRecording()
                message = error.localizedDescription
            }
            throw error
        }
    }

    func captureResult() async throws {
        guard let token = recordingToken, let pending, !recordingAction else { return }
        recordingAction = true
        defer { if recordingToken == token { recordingAction = false } }
        let shot = try await frame(after: max(pending.completedAt, Date()), token: token)
        let stillBefore = try await matcher.matches(pending.before, screenshot: shot)
        try checkRecording(token)
        guard !stillBefore else {
            throw KitError("MACRO_NO_VISIBLE_RESULT", "The result still matches the starting screen. Wait for a visible change, or stop this recording.")
        }
        let after = try VisualAnchor(screenshot: shot)
        _ = try await matcher.matches(after, screenshot: shot)
        try checkRecording(token)
        draft.steps.append(MacroStep(name: "Step \(draft.steps.count + 1) · \(pending.gesture.action.rawValue)",
                                     gesture: pending.gesture, before: pending.before, after: after))
        self.pending = nil
        waitingForResult = false
        message = "Step recorded. Record another gesture or finish; individual approval is on by default."
    }

    func captureStopScreen(phoneID: String) async throws {
        guard !isBusy, draft.phoneID == phoneID else { throw KitError("MACRO_BUSY", "Stop first and select the recorded phone.") }
        let profileID = draft.id
        let shot = try await controller.screenshot(phoneID: phoneID, longEdge: 900)
        guard !isBusy, draft.id == profileID, shot.phoneID == phoneID,
              shot.nativeWidth == draft.nativeWidth, shot.nativeHeight == draft.nativeHeight,
              abs(Date().timeIntervalSince(shot.capturedAt)) <= 1 else {
            throw KitError("MACRO_FRAME_CHANGED", "Profile or phone screen changed while capturing the stop screen.")
        }
        let anchor = try VisualAnchor(screenshot: shot)
        _ = try await matcher.matches(anchor, screenshot: shot)
        guard !isBusy, draft.id == profileID else { return }
        draft.stopWhen = anchor
        message = "Stop screen captured. Playback stops when this screen is recognized."
    }
}
