import AppKit
import IPhoneKitAPI
import IPhoneKitAgent
import IPhoneKitCore
import Observation
import SwiftUI

@Observable @MainActor
final class AppRuntime {
  let hub: PhoneHub

  let agent: AgentSession
  let macros: MacroWorkspace
  let macroSelfTestDirectory: URL?
  private(set) var providerConfiguration: ProviderConfiguration
  let headless = CommandLine.arguments.contains("--headless")
  private(set) var apiStatus = "Starting…"
  private(set) var apiURL = "http://127.0.0.1:8766"
  var errorMessage: String?

  var previewReady = false
  @ObservationIgnored private var server: LocalServer?
  @ObservationIgnored private var token = ""
  @ObservationIgnored private var started = false
  @ObservationIgnored private var signals: [DispatchSourceSignal] = []

  @ObservationIgnored private var shutdownTask: Task<Void, Never>?

  init() {
    let hub = PhoneHub(demo: CommandLine.arguments.contains("--demo"))
    self.hub = hub
    agent = AgentSession(controller: hub)
    let temporaryDirectory = FileManager.default.temporaryDirectory
    if hub.isDemo, CommandLine.arguments.contains("--macro-self-test") {
      macroSelfTestDirectory =
        ProcessInfo.processInfo.environment["IPHONEKIT_MACRO_TEST_DIRECTORY"]
        .map { path in URL(fileURLWithPath: path, isDirectory: true) }
        ?? temporaryDirectory.appendingPathComponent(
          "iphonekit-macro-self-test-\(UUID().uuidString)", isDirectory: true)
    } else {
      macroSelfTestDirectory = nil
    }
    let demoDirectory =
      macroSelfTestDirectory
      ?? temporaryDirectory.appendingPathComponent("iphonekit-demo", isDirectory: true)
    let store =
      hub.isDemo
      ? MacroStore(url: demoDirectory.appendingPathComponent("macros.json")) : MacroStore()
    macros = MacroWorkspace(controller: hub, store: store)
    providerConfiguration = ProviderConfiguration(
      baseURL: UserDefaults.standard.string(forKey: "iPhoneKit.modelBaseURL") ?? "",
      model: UserDefaults.standard.string(forKey: "iPhoneKit.modelName") ?? "gpt-4.1")
  }

  func start() async {
    guard !started else { return }
    started = true
    installSignals()
    await hub.start()
    do {
      let environment = ProcessInfo.processInfo.environment
      token = try environment["IPHONEKIT_API_KEY"] ?? TokenStore.loadOrCreate()
      let port = UInt16(environment["IPHONEKIT_PORT"] ?? "8766") ?? 8766
      let service = try LocalServer(controller: hub, port: port, token: token)
      server = service
      try service.start()
      for _ in 0..<30 {
        if service.isRunning || service.failure != nil { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      apiURL = "http://127.0.0.1:\(service.port)"
      apiStatus =
        service.isRunning ? "Listening · local only" : service.failure ?? "Server did not start"
      if !service.isRunning { errorMessage = apiStatus }
    } catch {
      apiStatus = "Unavailable"
      errorMessage = error.localizedDescription
    }
    if CommandLine.arguments.contains("--auto-prepare"), !hub.isDemo {
      for _ in 0..<30 {
        if !hub.phones.isEmpty { break }
        try? await Task.sleep(for: .milliseconds(200))
      }
      for phone in hub.phones {
        do { try await hub.prepare(phoneID: phone.id) } catch {
          errorMessage = error.localizedDescription
        }
      }
    }
    if headless {
      NSApp.setActivationPolicy(.accessory)
      NSApp.windows.forEach { $0.orderOut(nil) }
    }

    Task {
      await runAgentSelfTest()
      await runMacroSelfTest()
      await saveUISnapshot()
    }
  }

  func stop() async {
    macros.stop()
    if let current = shutdownTask { return await current.value }
    let task = Task { @MainActor in
      agent.stop()
      server?.stop()
      await hub.stop()
      signals.forEach { $0.cancel() }
      signals.removeAll()
    }
    shutdownTask = task
    await task.value

  }

  private func installSignals() {
    for number in [SIGTERM, SIGINT] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      // terminate() enters AppKit's nested quit loop, which cannot reenter this GCD callback.
      source.setEventHandler { [weak self] in
        Task { @MainActor [weak self] in
          await self?.stop()
          exit(0)
        }
      }
      source.resume()
      signals.append(source)
    }
  }

  func copyToken() { copy(token) }
  func copyMCPConfiguration() {
    let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/iphonekit-mcp")
      .path
    var environment = ["IPHONEKIT_PORT": String(server?.port ?? 8766)]
    if ProcessInfo.processInfo.environment["IPHONEKIT_API_KEY"] != nil {
      environment["IPHONEKIT_API_KEY"] = token
    }
    let configuration: [String: Any] = [
      "mcpServers": ["iphonekit": ["command": executable, "env": environment]]
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    {
      copy(text)
    }
  }
  func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func saveUISnapshot() async {
    guard hub.isDemo, CommandLine.arguments.contains("--ui-snapshot") else { return }
    for _ in 0..<100 {
      if previewReady { break }
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
    }
    guard let view = NSApp.windows.first(where: { $0.title == "iPhoneKit" })?.contentView else {
      return
    }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    if let png = bitmap.representation(using: .png, properties: [:]) {
      try? png.write(to: URL(fileURLWithPath: "/tmp/iphonekit-ui.png"), options: .atomic)
    }
  }

  func cancelPhone(_ phoneID: String) {
    if macros.recordingPhoneID == phoneID || macros.runner.activePhoneID == phoneID {
      macros.stop()
    } else if agent.activePhoneID == phoneID {
      agent.stop()
    } else {
      hub.cancel(phoneID: phoneID)
    }
  }
  func saveProvider(_ configuration: ProviderConfiguration, key: String) throws {
    _ = try configuration.endpoint()
    if !key.isEmpty { try ModelCredentialStore.save(key, for: configuration) }
    providerConfiguration = configuration
    UserDefaults.standard.set(configuration.baseURL, forKey: "iPhoneKit.modelBaseURL")
    UserDefaults.standard.set(configuration.model, forKey: "iPhoneKit.modelName")
  }
  func runAgent(goal: String, phoneID: String, configuration: ProviderConfiguration) throws {
    guard !macros.isBusy else {
      throw KitError("MACRO_BUSY", "Stop the macro or recording before starting an agent task.")
    }
    let planner: any VisionPlanning
    if hub.isDemo {
      planner = OfflineDemoPlanner()
    } else {
      let key = try ModelCredentialStore.load(for: configuration) ?? ""
      planner = try OpenAIVisionClient(configuration: configuration, apiKey: key)
    }
    try agent.start(goal: goal, phoneID: phoneID, planner: planner)

  }

  func runMacro(_ profile: MacroProfile) throws {
    guard !agent.state.isActive, !macros.isRecording else {
      throw KitError("AUTOMATION_BUSY", "Stop the agent or recording before starting a macro.")
    }
    try macros.runner.start(profile: profile, phoneID: profile.phoneID)
  }

  private func runAgentSelfTest() async {
    guard hub.isDemo, CommandLine.arguments.contains("--agent-self-test") else { return }
    do {
      try agent.start(
        goal: "Check the first reminder", phoneID: "demo-iphone", planner: OfflineDemoPlanner())
      let deadline = ContinuousClock.now + .seconds(10)
      var approvals = 0
      while agent.state.isActive, ContinuousClock.now < deadline {
        if let proposal = agent.proposal {
          approvals += 1
          agent.decide(proposalID: proposal.id, allow: true)
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      let result: [String: Any] = [
        "state": agent.state.rawValue, "approvals": approvals, "steps": agent.stepCount,
        "messages": agent.messages.count, "offline": true,
      ]
      let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
      try data.write(to: URL(fileURLWithPath: "/tmp/iphonekit-agent-check.json"), options: .atomic)
    } catch {
      agent.stop()
      try? Data("{\"state\":\"failed\"}".utf8).write(
        to: URL(fileURLWithPath: "/tmp/iphonekit-agent-check.json"), options: .atomic)
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var runtime: AppRuntime?
  private var terminating = false
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminating { return .terminateLater }
    guard let runtime else { return .terminateNow }
    terminating = true
    Task { @MainActor in
      await runtime.stop()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main @MainActor
struct IPhoneKitApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var runtime = AppRuntime()
  var body: some Scene {
    WindowGroup("iPhoneKit") {
      MainView(runtime: runtime)
        .frame(minWidth: 1000, minHeight: 650)
        .task {
          delegate.runtime = runtime
          await runtime.start()
        }
    }
    .defaultSize(width: 1160, height: 780)
    .windowToolbarStyle(.unifiedCompact)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .appInfo) {
        Button("Copy MCP Configuration") { runtime.copyMCPConfiguration() }
        Button("Copy Local API Key") { runtime.copyToken() }
        Button("Stop Automation") {
          runtime.macros.stop()
          runtime.agent.stop()
        }.keyboardShortcut(".", modifiers: .command)
      }
    }
  }
}
