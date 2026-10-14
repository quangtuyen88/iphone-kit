import SwiftUI
import AppKit
import IPhoneKitCore
import IPhoneKitAgent

struct MacroView: View {
    @Bindable var runtime: AppRuntime
    let phone: PhoneInfo?
    @State private var working = false
    @State private var error: String?
    @State private var review: MacroReviewRequest?

    private struct MacroReviewRequest: Identifiable {
        let id = UUID()
        let profile: MacroProfile
        let recovery: MacroRecovery?
        let phoneEpoch: UInt64
    }

    private var workspace: MacroWorkspace { runtime.macros }

    var body: some View {
        @Bindable var workspace = workspace
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Game macros", systemImage: "repeat.circle").font(.headline)
                Spacer()
                if workspace.isBusy {
                    Button("Stop", role: .destructive) { workspace.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                        .disabled(workspace.runner.state == .stopping)
                }
            }
            if workspace.runner.state != .idle { runStatus }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Menu("Saved profiles") {
                            ForEach(workspace.profiles) { profile in
                                Button(profile.name) { workspace.selectProfile(profile.id) }
                            }
                        }.disabled(workspace.isBusy || workspace.profiles.isEmpty)
                        Spacer()
                        Button("New") { if let phone { workspace.newProfile(phone: phone) } }
                            .disabled(workspace.isBusy || phone?.status != .ready)
                    }
                    TextField("Game profile name", text: $workspace.draft.name)
                        .textFieldStyle(.roundedBorder).disabled(workspace.isBusy)
                    if workspace.draft.phoneID.isEmpty {
                        Text("Connect a phone and choose New to begin.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(workspace.draft.nativeWidth) × \(workspace.draft.nativeHeight) · portrait · local only")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    recordingControls
                    if !workspace.draft.steps.isEmpty {
                        Divider()
                        Text("Recorded steps").font(.subheadline.weight(.semibold))
                        ForEach($workspace.draft.steps) { $step in
                            MacroStepEditor(step: $step, moveUp: { move(step.id, by: -1) },
                                            moveDown: { move(step.id, by: 1) },
                                            remove: { workspace.draft.steps.removeAll { $0.id == step.id } })
                        }.disabled(workspace.isBusy || working)
                        limits
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Stop condition").font(.subheadline.weight(.semibold))
                        Button("Capture current screen as goal") {
                            perform { if let phone { try await workspace.captureStopScreen(phoneID: phone.id) } }
                        }.disabled(workspace.isBusy || working || phone?.id != workspace.draft.phoneID)
                        if let anchor = workspace.draft.stopWhen {
                            VisualAnchorEditor(title: "Stop when this screen matches", anchor: Binding(
                                get: { workspace.draft.stopWhen ?? anchor }, set: { workspace.draft.stopWhen = $0 }))
                            Button("Remove stop condition") { workspace.draft.stopWhen = nil }
                        }
                    }.disabled(workspace.isBusy)
                    HStack {
                        Button("Save profile") { perform { try workspace.save() } }
                            .disabled(workspace.isBusy || working || workspace.storageError != nil || workspace.draft.phoneID.isEmpty)
                        Spacer()
                        Button("Review & run") {
                            do {
                                try workspace.draft.validate();
                                if let phone {
                                    review = MacroReviewRequest(
                                        profile: workspace.draft,
                                        recovery: workspace.runner.recovery,
                                        phoneEpoch: phone.epoch)
                                }
                            } catch { self.error = error.localizedDescription }
                        }.buttonStyle(.borderedProminent)
                            .disabled(
                                workspace.isBusy || working || workspace.draft.steps.isEmpty
                                    || phone?.id != workspace.draft.phoneID || phone?.status != .ready
                                    || runtime.agent.state.isActive)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if let storageError = workspace.storageError { Text(storageError).font(.caption).foregroundStyle(.red) }
                    Text("Use your own game/account and follow its rules. Screen checks can miss overlays; never allow purchases, sign-in, or account changes in automatic loops. Keep the phone unlocked; keep-awake pulses pause while a macro owns input.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 4)
            }
        }.sheet(item: $review) { request in
            MacroRunReview(profile: request.profile, recovery: request.recovery) {
                let currentPhone = runtime.hub.phones.first { candidate in
                    candidate.id == request.profile.phoneID && candidate.status == .ready
                }
                guard !workspace.runner.state.isActive,
                    workspace.runner.recovery?.id == request.recovery?.id,
                    currentPhone?.epoch == request.phoneEpoch
                else {
                    throw KitError(
                        "MACRO_REVIEW_STALE", "The phone or interrupted run changed. Cancel and review again.")
                }
                try runtime.runMacro(request.profile)
            }.id(request.id)
        }
        .onChange(of: phone?.epoch) { review = nil }
        .onChange(of: workspace.runner.recovery?.id) { review = nil }
        .onChange(of: workspace.runner.state.isActive) { _, active in
            if active { review = nil }
        }
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(workspace.message).font(.caption).fixedSize(horizontal: false, vertical: true)
            if workspace.isRecording {
                if workspace.waitingForResult {
                    Button("Capture result") { perform { try await workspace.captureResult() } }
                        .buttonStyle(.borderedProminent).disabled(working || workspace.recordingAction)
                }
                HStack {
                    if workspace.recordingAction || working { ProgressView().controlSize(.small) }
                    Button("Finish recording") { workspace.finishRecording() }
                        .disabled(workspace.recordingAction || workspace.waitingForResult || working)
                }
                Text("Use the gesture picker and phone preview. Home, typing, and other clients are locked while recording.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Button { perform { if let phone { try workspace.beginRecording(phone: phone) } } } label: {
                    Label(workspace.draft.steps.isEmpty ? "Record gestures" : "Record more gestures", systemImage: "record.circle")
                }.disabled(workspace.runner.state.isActive || runtime.agent.state.isActive || working || phone?.status != .ready || phone?.id != workspace.draft.phoneID || workspace.draft.steps.count >= 20)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private var limits: some View {
        @Bindable var workspace = workspace
        return VStack(alignment: .leading, spacing: 8) {
            Text("Session limits").font(.subheadline.weight(.semibold))
            Stepper("Loops: \(workspace.draft.repetitions)", value: $workspace.draft.repetitions, in: 1...20)
            Stepper("Maximum actions: \(workspace.draft.maximumActions)", value: $workspace.draft.maximumActions, in: 1...100)
            HStack {
                Text("Time limit (seconds)")
                TextField("Seconds", value: $workspace.draft.maximumSeconds, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 65)
            }
            Text("5–600 seconds, including waits and approvals. A new run always requires fresh approval.")
                .font(.caption2).foregroundStyle(.secondary)
        }.font(.caption).disabled(workspace.isBusy)
    }

    private var runStatus: some View {
        let runner = workspace.runner
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if runner.state.isActive { ProgressView().controlSize(.small) }
                Text(runner.state.rawValue.capitalized).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(runner.actionCount) actions").font(.caption.monospacedDigit())
            }
            if let recovery = runner.recovery, runner.state != .stopping {
                recoverySummary(recovery)
            } else {
                Text(runner.message).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            diagnostics
            if let proposal = runner.proposal {
                if let image = NSImage(data: proposal.screenshot.jpeg) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 145)
                }
                Text(CommandPresentation.text(proposal.command)).font(.caption.monospaced())
                HStack {
                    Button("Reject") { runner.decide(proposalID: proposal.id, allow: false) }
                    Button("Approve action") { runner.decide(proposalID: proposal.id, allow: true) }
                        .buttonStyle(.borderedProminent)
                }
                Text("The screen is checked again after approval.").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func recoverySummary(_ recovery: MacroRecovery) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Run interrupted", systemImage: "exclamationmark.triangle").font(.caption.weight(.semibold))
            Text(recovery.reason.message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Text("Last verified: \(MacroStepPresentation.text(recovery.lastVerifiedStep)) · interrupted: \(MacroStepPresentation.text(recovery.interruptedStep))")
                .font(.caption2.monospaced()).fixedSize(horizontal: false, vertical: true)
            Text(recovery.outcome.message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Text("This describes only the interrupted command. Inspect the phone yourself; nothing is resumed, skipped, or retried. A new run starts at step 1 and may repeat earlier effects.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var diagnostics: some View {
        let runner = workspace.runner
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kept in memory only. Contains no photos, screen text, or device identifiers.")
                    .font(.caption2).foregroundStyle(.secondary)
                ScrollView {
                    Text(runner.diagnosticReport).font(.caption2.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120)
                Button("Copy diagnostics") { runtime.copy(runner.diagnosticReport) }
                    .controlSize(.small).disabled(runner.diagnostics.isEmpty)
            }.padding(.top, 4)
        } label: {
            Text("Diagnostics (\(runner.diagnostics.count) events)").font(.caption)
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = workspace.draft.steps.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard workspace.draft.steps.indices.contains(destination) else { return }
        workspace.draft.steps.swapAt(index, destination)
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }
}

private struct MacroStepEditor: View {
    @Binding var step: MacroStep
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Step name", text: $step.name).textFieldStyle(.roundedBorder)
                Text("\(step.gesture.action.rawValue) · x \(step.gesture.start.x, format: .number.precision(.fractionLength(3))) · y \(step.gesture.start.y, format: .number.precision(.fractionLength(3)))")
                    .font(.caption.monospaced())
                Toggle("Require individual approval", isOn: $step.requiresApproval)
                    .font(.caption)
                if !step.requiresApproval {
                    Text("Only allow automatic execution for reviewed gameplay actions.").font(.caption2).foregroundStyle(.orange)
                }
                HStack {
                    Text("Delay (s)")
                    TextField("Delay", value: $step.delaySeconds, format: .number).frame(width: 48)
                    Text("Wait (s)")
                    TextField("Timeout", value: $step.timeoutSeconds, format: .number).frame(width: 48)
                }.font(.caption).textFieldStyle(.roundedBorder)
                VisualAnchorEditor(title: "Before: required screen", anchor: $step.before)
                VisualAnchorEditor(title: "After: expected result", anchor: $step.after)
                HStack {
                    Button(action: moveUp) { Image(systemName: "arrow.up") }.help("Move step up")
                    Button(action: moveDown) { Image(systemName: "arrow.down") }.help("Move step down")
                    Spacer()
                    Button("Remove step", role: .destructive, action: remove)
                }.controlSize(.small)
            }.padding(.vertical, 8)
        } label: {
            Label(step.name, systemImage: step.requiresApproval ? "hand.raised" : "play.circle")
                .font(.caption.weight(.medium)).lineLimit(2)
        }
    }
}

private struct VisualAnchorEditor: View {
    let title: String
    @Binding var anchor: VisualAnchor

    var body: some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 8) {
                if let image = NSImage(data: anchor.image) {
                    GeometryReader { geometry in
                        let scale = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                        Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                            .overlay(alignment: .topLeading) {
                                Rectangle().stroke(.blue, lineWidth: 2)
                                    .frame(width: size.width * anchor.region.width, height: size.height * anchor.region.height)
                                    .offset(x: size.width * anchor.region.x, y: size.height * anchor.region.y)
                            }
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 4).onEnded { value in
                                let x1 = min(1, max(0, value.startLocation.x / size.width))
                                let y1 = min(1, max(0, value.startLocation.y / size.height))
                                let x2 = min(1, max(0, value.location.x / size.width))
                                let y2 = min(1, max(0, value.location.y / size.height))
                                guard abs(x1 - x2) >= 0.05, abs(y1 - y2) >= 0.05 else { return }
                                anchor.region = MacroRegion(x: min(x1, x2), y: min(y1, y2), width: abs(x1 - x2), height: abs(y1 - y2))
                            })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(height: 210)
                }
                HStack {
                    Text("Drag on the image to choose a guard region.").font(.caption2)
                    Button("Full screen") { anchor.region = .full }.controlSize(.mini)
                }
                TextField("Optional required text (local OCR)", text: $anchor.expectedText)
                    .textFieldStyle(.roundedBorder)
                Text("The region is the target crop (and OCR crop when text is required). Before each input the full screen is also compared with the recorded context, so a dialog or banner outside the crop pauses the run. Animations, timers, or background changes can pause it too; this is not a guarantee that every popup is detected. Flat regions are rejected. Avoid the floating AssistiveTouch button.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.vertical, 6)
        }.font(.caption)
    }
}

private enum MacroStepPresentation {
    static func text(_ step: MacroStepProgress?) -> String {
        guard let step else { return "none" }
        return "loop \(step.iteration) · step \(step.stepIndex) · \(step.action.rawValue)"
    }
}

private struct MacroRunReview: View {
    let profile: MacroProfile
    let recovery: MacroRecovery?
    let run: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var inspected = false
    @State private var error: String?

    private var canRun: Bool { acknowledged && (recovery == nil || inspected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Approve a bounded game session", systemImage: "checkmark.shield").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(CommandPresentation.escaped(profile.name)).font(.headline)
                    Text("\(profile.steps.count) steps · \(profile.repetitions) loops · at most \(profile.maximumActions) actions or \(Int(profile.maximumSeconds)) seconds.")
                    Text("Pinned to the recorded phone at \(profile.nativeWidth) × \(profile.nativeHeight). Other input is blocked during playback. Each step must match its recorded target crop and, before any input, the recorded full-screen context; afterwards the expected result must appear. Animations or background changes can pause the run.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let recovery {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("The previous run was interrupted", systemImage: "exclamationmark.triangle").font(.callout.weight(.semibold))
                            Text(recovery.reason.message).font(.caption)
                            Text("Last verified: \(MacroStepPresentation.text(recovery.lastVerifiedStep)) · interrupted: \(MacroStepPresentation.text(recovery.interruptedStep))")
                                .font(.caption.monospaced())
                            Text(recovery.outcome.message).font(.caption)
                            Text("This describes only the interrupted command. A new run starts at step 1 and may repeat effects the earlier run already caused; nothing is resumed, skipped, or retried.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(profile.steps.enumerated()), id: \.element.id) { index, step in
                            Text("\(index + 1). \(CommandPresentation.escaped(step.name)) · \(step.gesture.action.rawValue) · \(step.requiresApproval ? "ask each time" : "automatic")")
                                .font(.callout)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("I reviewed every step. Automatic steps are gameplay only, not purchases or account changes.", isOn: $acknowledged)
                    if recovery != nil {
                        Toggle("I inspected the phone after the interrupted run", isOn: $inspected)
                    }
                    Text("Screen recognition is not a guarantee against overlays or a last-moment screen change. Stop with ⌘. and inspect any uncertain outcome. No failed action is automatically retried.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 450)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Approve & run") {
                    do { try run(); dismiss() } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(!canRun)
            }
        }.padding(26).frame(width: 530)
    }
}
