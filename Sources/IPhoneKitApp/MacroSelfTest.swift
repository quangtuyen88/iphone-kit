import Foundation
import IPhoneKitAgent
import IPhoneKitCore

extension AppRuntime {
  func runMacroSelfTest() async {
    guard hub.isDemo, let directory = macroSelfTestDirectory else { return }
    var report: [String: Any] = ["offline": true]
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      for _ in 0..<100 {
        if previewReady { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      guard previewReady, let phone = hub.phones.first else {
        throw KitError("DEMO_NOT_READY", "The demo preview did not start.")
      }
      macros.newProfile(phone: phone)
      macros.draft.name = "Demo · verified toggle loop"
      try macros.beginRecording(phone: phone)
      for _ in 0..<2 {
        let shot = try await hub.screenshot(phoneID: phone.id, longEdge: 900)
        try await macros.record(
          PhoneCommand(action: .tap, screenshotID: shot.id, x: 90, y: 200), screenshot: shot)
        try await macros.captureResult()
      }
      macros.finishRecording()
      macros.draft.repetitions = 2
      macros.draft.maximumActions = 4
      macros.draft.maximumSeconds = 20
      for index in macros.draft.steps.indices {
        macros.draft.steps[index].delaySeconds = 0.05
        macros.draft.steps[index].timeoutSeconds = 3
        macros.draft.steps[index].requiresApproval = index == 1
      }
      try macros.save()
      let saved = try MacroStore(url: directory.appendingPathComponent("macros.json")).load()
      guard saved.count == 1, saved.first?.id == macros.draft.id, saved.first?.steps.count == 2
      else {
        throw KitError("DEMO_SAVE_FAILED", "The recorded profile did not reload intact.")
      }
      report["reloaded_profiles"] = saved.count
      try runMacro(macros.draft)
      var approvals = 0
      let deadline = ContinuousClock.now + .seconds(25)
      while macros.runner.state.isActive, ContinuousClock.now < deadline {
        if let proposal = macros.runner.proposal {
          approvals += 1
          macros.runner.decide(proposalID: proposal.id, allow: true)
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      report["state"] = macros.runner.state.rawValue
      report["message"] = macros.runner.message
      report["actions"] = macros.runner.actionCount
      report["steps"] = macros.draft.steps.count
      report["approvals"] = approvals
      report["saved_profiles"] = macros.profiles.count
    } catch {
      report["state"] = "failed"
      report["message"] = error.localizedDescription
      macros.stop()
    }
    if let data = try? JSONSerialization.data(
      withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
    {
      try? data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
    }
  }
}
