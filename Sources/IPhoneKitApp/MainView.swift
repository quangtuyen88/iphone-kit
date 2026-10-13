import SwiftUI
import AppKit
import IPhoneKitCore

private enum ManualGesture: String, CaseIterable, Identifiable {
    case live = "Live", tap = "Tap", double = "Double tap", triple = "Triple tap", hold = "Long press"
    case flick = "Flick", drag = "Drag", holdDrag = "Hold and drag"
    var id: String { rawValue }
    var instruction: String {
        switch self {
        case .live: "Click to tap. Click and drag to swipe."
        case .tap, .double, .triple: "Click a point on the phone screen."
        case .hold: "Click a point to press for one second."
        case .flick: "Drag toward the direction you want to flick."
        case .drag: "Drag between two points."
        case .holdDrag: "Drag to long press, then move an item."
        }
    }
}

@MainActor
struct MainView: View {
    @Bindable var runtime: AppRuntime
    @AppStorage("iPhoneKit.selectedPhone") private var storedSelection = ""
    @State private var selection: String?
    @State private var screenshot: Screenshot?
    @State private var previewError: String?
    @State private var gesture = ManualGesture.live
    @State private var typedText = ""
    @State private var busy = false
    @State private var settingUp = false

    @State private var panel = CommandLine.arguments.contains("--macro-self-test") ? "Macros" : "Agent"
    @State private var actionMessage = ""

    private var phone: PhoneInfo? { runtime.hub.phones.first { $0.id == selection } }
    private var canControl: Bool { phone?.status == .ready && !busy && !runtime.macros.isBusy }

        private var canGesture: Bool {
            phone?.status == .ready && !busy && !runtime.macros.runner.state.isActive
                && (!runtime.macros.isRecording || (runtime.macros.recordingPhoneID == selection && !runtime.macros.waitingForResult && !runtime.macros.recordingAction))
        }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.title2).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iPhoneKit").font(.headline)
                        Text("A phone for your agents").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
                List(runtime.hub.phones, selection: $selection) { phone in
                    HStack(spacing: 10) {
                        Image(systemName: "iphone").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(phone.name).fontWeight(.medium)
                            HStack(spacing: 5) {
                                Circle().fill(phone.status == .ready ? Color.green : Color.orange).frame(width: 5, height: 5)
                                Text(phone.status == .ready ? "Connected" : "Setup needed").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 6).tag(phone.id)
                }.listStyle(.sidebar)
                if runtime.hub.phones.isEmpty {
                    Text("Plug in an unlocked iPhone with a USB data cable.")
                        .font(.caption).foregroundStyle(.secondary).padding(20)
                }
                Spacer(minLength: 0)
                Label(runtime.hub.isDemo ? "Demo · no hardware input" : "USB + Bluetooth · local first", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary).padding(18)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let phone { phonePanel(phone) } else { welcome }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                sidePanel.frame(width: 320).padding(.horizontal, 20).padding(.vertical, 22)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: runtime.hub.phones.map { $0.id }, initial: true) { _, ids in
            if selection == nil || !ids.contains(selection ?? "") {
                selection = ids.contains(storedSelection) ? storedSelection : ids.first
            }
        }
        .onChange(of: selection) { _, value in if runtime.macros.isBusy { runtime.macros.stop() }
                    storedSelection = value ?? ""; screenshot = nil; actionMessage = "" }
        .task(id: selection) { await previewLoop() }
        .alert("iPhoneKit", isPresented: Binding(get: { runtime.errorMessage != nil }, set: { if !$0 { runtime.errorMessage = nil } })) {
            Button("OK", role: .cancel) { runtime.errorMessage = nil }
        } message: { Text(runtime.errorMessage ?? "") }
    }

private var welcome: some View {
        VStack(spacing: 20) {
            Image(systemName: "cable.connector").font(.system(size: 58, weight: .light)).foregroundStyle(.blue)
            Text("Connect your iPhone").font(.system(size: 28, weight: .semibold))
            Text("Plug it in, unlock it, and tap Trust This Computer.\nNo jailbreak, Developer Mode, or phone app needed.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(4)
            if let error = runtime.hub.lastError { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 30) }
            Label("Screens and commands stay on this Mac.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }

    private func phonePanel(_ phone: PhoneInfo) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(phone.name).font(.title2.weight(.semibold))
                    Text(runtime.hub.isDemo ? "Simulated device" : "\(phone.model) · iOS \(phone.systemVersion)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if runtime.hub.isDemo { Text("DEMO").font(.caption2.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 4).background(.blue.opacity(0.12), in: Capsule()).foregroundStyle(.blue) }
                Toggle("Keep awake", isOn: Binding(get: { phone.keepAwake }, set: { enabled in
                    do { try runtime.hub.setKeepAwake(phoneID: phone.id, enabled: enabled) }
                    catch { runtime.errorMessage = error.localizedDescription }
                }))
                .toggleStyle(.switch).controlSize(.small)
                .disabled(!phone.keepAwake && ![PhoneStatus.ready, .needsCapture, .needsWake].contains(phone.status))
                .help("While enabled, sends a modifier-only pulse after 20 seconds without phone input. Stops when iPhoneKit quits or the phone is unplugged.")
                Button { send(PhoneCommand(action: .pressHome, idempotencyKey: UUID().uuidString)) } label: { Label("Home", systemImage: "house") }
                    .disabled(!canControl).keyboardShortcut("h", modifiers: [.command, .shift])
                Button { runtime.cancelPhone(phone.id) } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Cancel pending actions and release held inputs")
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            if phone.status != .ready { setupPanel(phone).padding(.horizontal, 24).padding(.bottom, 12) }
            HStack {
                Picker("Gesture", selection: $gesture) { ForEach(ManualGesture.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu).frame(width: 165)
                Spacer()
                Text(screenshot.map { "\($0.nativeWidth) × \($0.nativeHeight)" } ?? "Screen preview")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.bottom, 8)
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                if let screenshot {
                    PhoneCanvas(screenshot: screenshot, enabled: canGesture && screenshot.nativeWidth < screenshot.nativeHeight) { shot, from, to in
                        control(shot, from: from, to: to)
                    }.padding(18)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "iphone").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.secondary)
                        Text(previewError ?? "Waiting for iPhone screen…").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(25)
                }
            }.padding(.horizontal, 24).frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) }
                Text(actionMessage.isEmpty ? gesture.instruction : actionMessage).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 26).padding(.vertical, 10)
            HStack(spacing: 8) {
                TextField("Type into the phone's focused field…", text: $typedText).textFieldStyle(.roundedBorder).onSubmit { type() }
                Button("Type") { type() }.buttonStyle(.borderedProminent).disabled(!canControl || typedText.isEmpty)
            }.padding(.horizontal, 24)
            Text("US-ASCII only. iOS may auto-capitalise; check the screen before submitting.")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 20)
        }
    }

private func setupPanel(_ phone: PhoneInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(phone.message, systemImage: phone.status == .needsWake ? "moon.zzz" : phone.trust == .locked ? "lock.iphone" : "info.circle").font(.callout)
            HStack {
                if phone.status == .needsWake {
                    Button("Wake iPhone") {
                        send(PhoneCommand(action: .wake, idempotencyKey: UUID().uuidString))
                    }.buttonStyle(.borderedProminent).disabled(busy)
                } else if phone.status == .needsTrust {
                    if phone.trust?.isActive == true {
                        ProgressView().controlSize(.small)
                        Text(phone.trust == .locked ? "Waiting for the iPhone to unlock…" : "Waiting for Trust…")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if phone.trust?.canRetry ?? true {
                        Button("Show Trust prompt") {
                            runtime.hub.requestTrust(phoneID: phone.id)
                            actionMessage = "Check the iPhone: tap Trust, then enter its passcode."
                        }.buttonStyle(.borderedProminent)
                    }
                } else {
                    Button(settingUp ? "Setting up…" : "Enable control") {
                        guard !settingUp else { return }
                        settingUp = true
                        Task { @MainActor in
                            defer { settingUp = false }
                            do { try await runtime.hub.prepare(phoneID: phone.id) }
                            catch { runtime.errorMessage = error.localizedDescription }
                        }
                    }.buttonStyle(.borderedProminent).disabled(settingUp)
                    if phone.status == .needsCapture {
                        Button("Wake iPhone") {
                            send(PhoneCommand(action: .wake, idempotencyKey: UUID().uuidString))
                        }.disabled(busy)
                    }
                    Button("Bluetooth settings") { openSettings("com.apple.BluetoothSettings") }.font(.caption)
                }
            }
            if runtime.hub.captures.count > 1 || phone.status == .needsCapture {
                Picker("Phone screen", selection: Binding(get: { phone.captureID ?? "" }, set: { id in
                    do { try runtime.hub.bindCapture(phoneID: phone.id, captureID: id) }
                    catch { runtime.errorMessage = error.localizedDescription }
                })) {
                    Text("Choose this phone's screen").tag("")
                    ForEach(runtime.hub.captures) { Text("\($0.name) · \(String($0.id.prefix(8)))").tag($0.id) }
                }.font(.caption)
                Text("For multiple phones, verify each selected screen belongs to that phone.").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Panel", selection: $panel) {
                Text("Agent").tag("Agent")
                Text("Macros").tag("Macros")
                Text("Connections").tag("Connections")
            }.pickerStyle(.segmented)
            if panel == "Connections" { connectionsPanel }
            else if panel == "Macros" { MacroView(runtime: runtime, phone: phone) }
            else { AgentChatView(runtime: runtime, phone: phone) }
        }.frame(maxHeight: .infinity, alignment: .top)
    }


    private var connectionsPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Agents", systemImage: "sparkles").font(.headline)
                Text("Give Claude, Codex, or any MCP client access to your connected phones.").font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                Button { runtime.copyMCPConfiguration(); actionMessage = "MCP configuration copied." } label: {
                    Label("Copy MCP configuration", systemImage: "doc.on.doc")
                }.buttonStyle(.borderedProminent)
                Text("Paste into your client's MCP configuration. Keep iPhoneKit running.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("Local API", systemImage: "network").font(.headline)
                Text(runtime.apiURL).font(.caption.monospaced()).textSelection(.enabled)
                Label(runtime.apiStatus, systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                Button { runtime.copyToken(); actionMessage = "API key copied. Share only with trusted clients." } label: {
                    Label("Copy API key", systemImage: "key")
                }
                Text("Bound to localhost. No cloud account or subscription.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions").font(.headline)
                permissionRow("Camera", key: "camera", pane: "com.apple.preference.security?Privacy_Camera")
                permissionRow("Bluetooth", key: "bluetooth", pane: "com.apple.preference.security?Privacy_Bluetooth")
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Activity").font(.headline)
                ForEach(runtime.hub.events.suffix(5).reversed()) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Text(event.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Unlock required. Use a device and accounts you're comfortable handing to an agent.")
                .font(.caption2).foregroundStyle(.secondary)
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private func permissionRow(_ title: String, key: String, pane: String) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            let status = runtime.hub.permissionStatus[key] ?? "not_requested"
            Text(status == "allowed" || status == "demo" ? "Allowed" : "Setup needed").font(.caption).foregroundStyle(status == "allowed" || status == "demo" ? Color.green : .secondary)
            Button { openSettings(pane) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).help("Open \(title) privacy settings")
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(url) }
    }

    private func previewLoop() async {
        guard let id = selection else { return }
        while !Task.isCancelled {
            do {
                let shot = try await runtime.hub.screenshot(phoneID: id, longEdge: 1344)
                guard selection == id else { return }
                screenshot = shot
                runtime.previewReady = true; previewError = nil
            } catch is CancellationError { return }
            catch { previewError = error.localizedDescription }
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
        }
    }

    private func type() {
        guard !typedText.isEmpty else { return }
        send(PhoneCommand(action: .typeText, idempotencyKey: UUID().uuidString, text: typedText))
    }

    private func send(_ command: PhoneCommand, screenshot: Screenshot? = nil) {
            guard let id = selection, !busy else { return }
            busy = true
            Task { @MainActor in
                defer { busy = false }
                do {
                    if runtime.macros.isRecording {
                        guard let screenshot, runtime.macros.recordingPhoneID == id else {
                            throw KitError("MACRO_RECORDING", "Only gestures on the recorded phone preview are allowed while recording.")
                        }
                        try await runtime.macros.record(command, screenshot: screenshot)
                        actionMessage = "Gesture sent once. Capture its visible result in Macros."
                    } else {
                        let result = try await runtime.hub.execute(phoneID: id, command: command)
                        actionMessage = result.status == "simulated" ? "Simulated. No real phone input." : "Input sent. Verify on the phone screen."
                    }
                } catch { actionMessage = error.localizedDescription }
            }
        }

    private func control(_ shot: Screenshot, from: CGPoint, to: CGPoint) {
        var action: PhoneAction = .tap
        switch gesture {
        case .live: action = hypot(to.x - from.x, to.y - from.y) > 8 ? .drag : .tap
        case .tap: action = .tap
        case .double: action = .doubleTap
        case .triple: action = .tripleTap
        case .hold: action = .longPress
        case .flick: action = .flick
        case .drag: action = .drag
        case .holdDrag: action = .holdAndDrag
        }
        var command = PhoneCommand(action: action, screenshotID: shot.id, idempotencyKey: UUID().uuidString, x: from.x, y: from.y)
        if action == .drag || action == .holdAndDrag {
            command.fromX = from.x; command.fromY = from.y; command.toX = to.x; command.toY = to.y
        }
        if action == .flick {
            let dx = to.x - from.x, dy = to.y - from.y
            command.direction = abs(dx) > abs(dy) ? (dx < 0 ? "left" : "right") : (dy < 0 ? "up" : "down")
        }
        send(command, screenshot: shot)
    }
}

@MainActor
private struct PhoneCanvas: View {
    let screenshot: Screenshot
    let enabled: Bool
    let action: (Screenshot, CGPoint, CGPoint) -> Void
    @State private var heldScreenshot: Screenshot?
    var body: some View {
        GeometryReader { proxy in
            let shot = heldScreenshot ?? screenshot
            let ratio = Double(shot.width) / Double(shot.height)
            let height = min(proxy.size.height, proxy.size.width / ratio)
            let width = height * ratio
            if let image = NSImage(data: shot.jpeg) {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.1)))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                        if heldScreenshot == nil { heldScreenshot = screenshot }
                    }.onEnded { value in
                        defer { heldScreenshot = nil }
                        guard enabled else { return }
                        let reference = heldScreenshot ?? screenshot
                        func pixel(_ point: CGPoint) -> CGPoint {
                            CGPoint(x: max(0, min(Double(reference.width - 1), point.x / width * Double(reference.width))),
                                    y: max(0, min(Double(reference.height - 1), point.y / height * Double(reference.height))))
                        }
                        action(reference, pixel(value.startLocation), pixel(value.location))
                    })
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
    }
}
