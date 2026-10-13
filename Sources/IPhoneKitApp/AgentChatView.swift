import SwiftUI
import AppKit
import IPhoneKitCore
import IPhoneKitAgent

@MainActor
struct AgentChatView: View {
    @Bindable var runtime: AppRuntime
    let phone: PhoneInfo?
    @State private var goal = ""
    @State private var settingsOpen = false
    @State private var consentOpen = false
    @State private var pending: PendingRun?
    private struct PendingRun {
        let goal: String
        let phoneID: String
        let configuration: ProviderConfiguration
    }
    private var session: AgentSession { runtime.agent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Agent", systemImage: "sparkles").font(.headline)
                Spacer()
                Button { settingsOpen = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).help("Model settings").accessibilityLabel("Model settings")
            }
            Text(runtime.hub.isDemo ? "Offline demo · no network or phone input" : "Your model, your phone. Approve every action.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if session.state == .thinking || session.state == .executing { ProgressView().controlSize(.small) }
                Text(status).font(.caption.weight(.medium))
                Spacer()
                if session.state.isActive { Text("\(session.stepCount)/20").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if session.messages.isEmpty { emptyChat }
                        ForEach(session.messages) { entry in ChatMessage(entry: entry).id(entry.id) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.messages.last?.id) { _, value in
                    if let value { proxy.scrollTo(value, anchor: .bottom) }
                }
            }.frame(maxHeight: .infinity)
            if let proposal = session.proposal { approvalCard(proposal) }
            if session.state.isActive {
                Button("Stop task", role: .destructive) { session.stop() }.frame(maxWidth: .infinity)
            }
            Divider()
            TextField("What should your iPhone do?", text: $goal, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
                .disabled(session.state.isActive)
            HStack {
                Button("Clear chat") { session.clearMessages() }.font(.caption).disabled(session.state.isActive)
                Spacer()
                Button(runtime.hub.isDemo ? "Run demo task" : "Run task") { requestRun() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.state.isActive || phone?.status != .ready || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Screenshots and prompts go to your configured provider only after you confirm Run. Chat is not saved when you quit.").fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $settingsOpen) { ProviderSettingsView(runtime: runtime) }
        .confirmationDialog("Send phone screenshots to this model provider?", isPresented: $consentOpen, titleVisibility: .visible, presenting: pending) { run in
            Button("Run and share screenshots") { begin(run) }
            Button("Cancel", role: .cancel) {}
        } message: { run in
            Text("Endpoint: \(run.configuration.baseURL)\nModel: \(run.configuration.model)\nThis task sends phone screenshots, your prompt, and recent actions to that endpoint. Use trusted providers and accounts.")
        }
    }

    private var status: String {
        switch session.state {
        case .idle: "Ready for a task"
        case .thinking: "Looking at the screen…"
        case .awaitingApproval: "Waiting for your approval"
        case .executing: "Sending approved input…"
        case .completed: "Task complete"
        case .stopped: "Stopped"
        case .needsInput: "Your input is needed"
        case .failed: "Task stopped with an error"
        }
    }

    private var emptyChat: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start with a small task").font(.callout.weight(.medium))
            Text(runtime.hub.isDemo ? "Try: Check the first reminder. The offline agent will ask you to approve one simulated tap." : "Try: Open Reminders and find my Groceries list. The agent looks, proposes one action, and waits for your approval.")
                .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
            Text("Stop before payments, deletion, messages, or sensitive account changes unless you intend to authorize them.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 12)
    }

    private func approvalCard(_ proposal: AgentProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approve this exact action", systemImage: "hand.raised").font(.callout.weight(.semibold))
            Text(runtime.hub.phones.first(where: { $0.id == proposal.phoneID })?.name ?? "Pinned phone").font(.caption).foregroundStyle(.secondary)
            if let image = NSImage(data: proposal.screenshot.jpeg) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 115)
                    .accessibilityLabel("Screenshot the proposed action refers to")
            }
            ScrollView { Text(CommandPresentation.text(proposal.command)).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 70)
            HStack {
                Button("Reject", role: .cancel) { session.decide(proposalID: proposal.id, allow: false) }
                Spacer()
                Button("Approve action") { session.decide(proposalID: proposal.id, allow: true) }.buttonStyle(.borderedProminent)
            }
        }.padding(12).background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func requestRun() {
        guard let phone, phone.status == .ready else { return }
        let run = PendingRun(goal: goal, phoneID: phone.id, configuration: runtime.providerConfiguration)
        if runtime.hub.isDemo { begin(run) }
        else {
            do { _ = try run.configuration.endpoint(); pending = run; consentOpen = true }
            catch { runtime.errorMessage = error.localizedDescription; settingsOpen = true }
        }
    }
    private func begin(_ run: PendingRun) {
        do { try runtime.runAgent(goal: run.goal, phoneID: run.phoneID, configuration: run.configuration); goal = "" }
        catch { runtime.errorMessage = error.localizedDescription }
    }
}

private struct ChatMessage: View {
    let entry: ChatEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.role == .user ? "You" : entry.role == .assistant ? "Agent" : "Phone")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(CommandPresentation.escaped(entry.text)).fixedSize(horizontal: false, vertical: true).font(entry.role == .activity ? .caption : .callout)
                .foregroundStyle(entry.role == .activity ? Color.secondary : .primary).textSelection(.enabled)
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(entry.role == .user ? Color.blue.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
private struct ProviderSettingsView: View {
    @Bindable var runtime: AppRuntime
    @Environment(\.dismiss) private var dismiss
    // The edit form deliberately seeds a draft once; edits never change an active run's configuration.
    @State private var baseURL: String
    @State private var model: String
    @State private var key = ""
    @State private var keyStatus = ""
    @State private var error: String?
    @State private var removeOpen = false
    init(runtime: AppRuntime) {
        self.runtime = runtime
        _baseURL = State(initialValue: runtime.providerConfiguration.baseURL)
        _model = State(initialValue: runtime.providerConfiguration.model)
    }
    private var configuration: ProviderConfiguration { ProviderConfiguration(baseURL: baseURL, model: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Model settings").font(.title2.weight(.semibold))
            Text("Use a vision-capable OpenAI-compatible Chat Completions endpoint. Saving settings does not contact the provider.")
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("Base URL") { TextField("https://api.openai.com/v1", text: $baseURL).textFieldStyle(.roundedBorder) }
            LabeledContent("Model") { TextField("gpt-4.1", text: $model).textFieldStyle(.roundedBorder) }
            LabeledContent("API key") { SecureField("Optional for local models; saved in Keychain", text: $key).textFieldStyle(.roundedBorder) }
            HStack {
                Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remove saved key", role: .destructive) { removeOpen = true }.font(.caption)
            }
            Text("Keys are scoped to the endpoint's scheme, host, and port. HTTPS is required except for literal loopback HTTP. Redirects are blocked.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") {
                    do { try runtime.saveProvider(configuration, key: key); key = ""; dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
        .onAppear { updateKeyStatus() }
        .onChange(of: baseURL) { _, _ in key = ""; updateKeyStatus() }
        .confirmationDialog("Remove this endpoint's saved API key?", isPresented: $removeOpen, titleVisibility: .visible) {
            Button("Remove API key", role: .destructive) {
                do { try ModelCredentialStore.delete(for: configuration); key = ""; updateKeyStatus() }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    private func updateKeyStatus() {
        do { keyStatus = try ModelCredentialStore.load(for: configuration) == nil ? "No saved key for this endpoint" : "Key saved in this Mac's Keychain" }
        catch { keyStatus = "Enter a valid endpoint to check its saved key" }
    }
}
