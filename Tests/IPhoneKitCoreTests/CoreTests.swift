import Foundation
import Testing
@testable import IPhoneKitCore

private let portrait = ImageGeometry(width: 621, height: 1344, nativeWidth: 1170, nativeHeight: 2532)

@Test func snakeCaseRoundTrip() throws {
    let command = PhoneCommand(action: .tap, screenshotID: "frame-1", idempotencyKey: "op-1", x: 7, y: 8)
    let data = try KitJSON.encoder().encode(command)
    #expect(String(decoding: data, as: UTF8.self).contains("screenshot_id"))
    #expect(try KitJSON.decoder().decode(PhoneCommand.self, from: data) == command)
    let phone = PhoneInfo(id: "usb-1", name: "Phone", captureID: "capture-1", epoch: 7)
    #expect(try KitJSON.decoder().decode(PhoneInfo.self, from: KitJSON.encoder().encode(phone)) == phone)
}

@Test func pointerCoordinatesValidated() throws {
    #expect(throws: KitError.self) { try portrait.pointer(x: -1, y: 0) }
    #expect(throws: KitError.self) { try portrait.pointer(x: .nan, y: 0) }
    #expect(throws: KitError.self) { try portrait.pointer(x: 621, y: 0) }
    let point = try portrait.pointer(x: 310, y: 671.5)
    let x = Int(point[3]) | Int(point[4]) << 8
    #expect(abs(x - 16384) <= 1)
    #expect(point.count == 8)
}

@Test func landscapeFailsClosed() {
    let landscape = ImageGeometry(width: 1344, height: 621, nativeWidth: 2532, nativeHeight: 1170)
    #expect(throws: KitError.self) { try landscape.pointer(x: 100, y: 100) }
}

@Test func clickCountsAndLongPress() throws {
    for (action, count) in [(PhoneAction.tap, 1), (.doubleTap, 2), (.tripleTap, 3)] {
        let plan = try GesturePlan.build(PhoneCommand(action: action, x: 50, y: 80), geometry: portrait)
        #expect(plan.reports.filter { $0.bytes[2] == 1 }.count == count)
        #expect(plan.reports.last?.bytes[2] == 0)
    }
    let hold = try GesturePlan.build(PhoneCommand(action: .longPress, x: 5, y: 5, duration: 750), geometry: portrait)
    #expect(hold.reports.last!.milliseconds - hold.reports[1].milliseconds == 750)
    #expect(throws: KitError.self) { try GesturePlan.build(PhoneCommand(action: .longPress, x: 5, y: 5, duration: .infinity), geometry: portrait) }
}


@Test func wakeUsesNonTypingModifierPulse() throws {
    let plan = try GesturePlan.build(PhoneCommand(action: .wake), geometry: nil)
    #expect(plan.reports.count == 2)
    #expect(plan.reports[0].bytes == HIDReports.keyboard(modifiers: 0x02))
    #expect(plan.reports[1].bytes == HIDReports.keyboard())
}


@Test func keepAwakePolicyWaitsForIdleInterval() {
    let now = Date(timeIntervalSince1970: 100)
    #expect(!KeepAwakePolicy.isDue(enabled: false, lastActivity: nil, lastAttempt: nil, now: now))
    #expect(!KeepAwakePolicy.isDue(enabled: true, lastActivity: now.addingTimeInterval(-19), lastAttempt: nil, now: now))
    #expect(KeepAwakePolicy.isDue(enabled: true, lastActivity: now.addingTimeInterval(-20), lastAttempt: nil, now: now))
    #expect(KeepAwakePolicy.isDue(enabled: true, lastActivity: nil, lastAttempt: nil, now: now))
    #expect(!KeepAwakePolicy.isDue(enabled: true, lastActivity: now.addingTimeInterval(-30), lastAttempt: now.addingTimeInterval(-5), now: now))
}

@Test func physicalUSBRetainsSleepingPhoneWithoutTreatingUnplugAsSleep() throws {
    let id = "00000000-0000000000000001"
    let phone = USBPhone(id: id, name: "iPhone", model: "iPhone14,7", systemVersion: "27.0",
                         bluetoothAddress: "02:00:00:00:00:01", trusted: true, assistiveTouch: true, available: true)
    let physical = Set([USBPhysicalPresence.normalize(id)])
    let sleeping = USBPhysicalPresence.reconciled(known: [id: phone.settingAvailable(false)], live: [:], physical: physical)
    #expect(sleeping[id]?.available == false)
    let uncertain = USBPhysicalPresence.reconciled(known: sleeping, live: [:], physical: nil)
    #expect(uncertain[id]?.available == false)
    let awake = USBPhysicalPresence.reconciled(known: sleeping, live: [id: phone], physical: physical)
    #expect(awake[id]?.available == true)
    let unplugged = USBPhysicalPresence.reconciled(known: sleeping, live: [:], physical: [])
    #expect(unplugged.isEmpty)
}

@Test func flickReleasesWhileMoving() throws {
    let plan = try GesturePlan.build(PhoneCommand(action: .flick, x: 310, y: 900, direction: "up"), geometry: portrait)
    let release = plan.reports.last!
    let lastMove = plan.reports[plan.reports.count - 2]
    #expect(release.bytes[2] == 0)
    #expect(release.milliseconds - lastMove.milliseconds <= 16)
    #expect(lastMove.bytes != plan.reports[plan.reports.count - 3].bytes)
    #expect(throws: KitError.self) { try GesturePlan.build(PhoneCommand(action: .flick, x: 1, y: 1, direction: "diagonal"), geometry: portrait) }
}

@Test func unsupportedTextRejectedBeforeAnyInput() throws {
    #expect(throws: KitError.self) { try HIDReports.typedKeys("café") }
    #expect(throws: KitError.self) { try HIDReports.typedKeys("emoji 🦊") }
    #expect(throws: KitError.self) { try HIDReports.typedKeys("") }
    #expect(try HIDReports.typedKeys("Az09!?\n").count == 7)
    let plan = try GesturePlan.build(PhoneCommand(action: .typeText, text: "Ab"), geometry: nil)
    #expect(plan.reports[0].bytes[2] == 2)
    #expect(plan.reports[1].bytes == HIDReports.keyboard())
    #expect(plan.reports.last!.bytes == HIDReports.keyboard())
}

@Test func keyboardAndConsumerReleased() throws {
    let key = try GesturePlan.build(PhoneCommand(action: .pressKey, key: "enter", modifiers: ["command"], repeatCount: 2), geometry: nil)
    #expect(key.reports.count == 4)
    #expect(key.reports[0].bytes[2] == 8)
    #expect(key.reports.last!.bytes == HIDReports.keyboard())
    let home = try GesturePlan.build(PhoneCommand(action: .pressHome), geometry: nil)
    #expect(home.reports.first!.bytes == HIDReports.consumer(0x0223))
    #expect(home.reports.last!.bytes == HIDReports.consumer())
    #expect(throws: KitError.self) { try GesturePlan.build(PhoneCommand(action: .pressKey, key: "unknown"), geometry: nil) }
    #expect(throws: KitError.self) { try GesturePlan.build(PhoneCommand(action: .pressKey, key: "enter", modifiers: ["invalid"]), geometry: nil) }
}

@MainActor private final class RecordingTransport: ReportTransport {
    var epoch: UInt64 = 1
    var isReady = true
    var reports: [[UInt8]] = []
    var releases = 0
    func send(_ report: [UInt8], epoch: UInt64, deadline: Date?) throws {
        guard self.epoch == epoch, isReady else { throw KitError("DISCONNECTED", "Disconnected.") }
        reports.append(report)
    }
    func neutralize(epoch: UInt64) { if epoch == self.epoch { releases += 1 } }
}

@Test @MainActor func disconnectDoesNotReplayOldGesture() async throws {
    let transport = RecordingTransport()
    let plan = try GesturePlan.build(PhoneCommand(action: .tap, x: 5, y: 5), geometry: portrait)
    let runner = GestureRunner(sleep: { _ in transport.epoch = 2 })
    do { try await runner.run(plan, transport: transport, epoch: 1, deadline: nil, stillValid: { true }); Issue.record("Expected epoch rejection") }
    catch { #expect((error as? KitError)?.code == "CONNECTION_CHANGED") }
    #expect(transport.reports.count == 1)
    #expect(transport.releases == 0)
}

@Test @MainActor func cancelledGestureReleasesHeldInputs() async throws {
    let transport = RecordingTransport()
    let plan = try GesturePlan.build(PhoneCommand(action: .tap, x: 5, y: 5), geometry: portrait)
    let runner = GestureRunner(sleep: { _ in throw CancellationError() })
    do { try await runner.run(plan, transport: transport, epoch: 1, deadline: nil, stillValid: { true }); Issue.record("Expected cancellation") }
    catch { #expect(error is CancellationError) }
    #expect(transport.releases == 1)
}

@Test @MainActor func fifoPreventsOverlap() async throws {
    let queue = CommandQueue()
    var observed: [String] = []
    let tasks = (0..<8).map { index in
        Task { @MainActor in
            try await queue.submit {
                observed.append("start-\(index)")
                try await Task.sleep(for: .milliseconds(2))
                observed.append("end-\(index)")
                return ActionResult(phoneID: "demo", action: .tap, startedAt: Date(), epoch: 1)
            }
        }
    }
    for task in tasks { _ = try await task.value }
    #expect(observed.count == 16)
    for index in stride(from: 0, to: observed.count, by: 2) {
        #expect(observed[index].dropFirst(6) == observed[index + 1].dropFirst(4))
    }
}

@Test @MainActor func demoUsesRealValidationAndIdempotency() async throws {
    let hub = PhoneHub(demo: true)
    await hub.start()
    let screenshot = try await hub.screenshot(phoneID: "demo-iphone", longEdge: 900)
    #expect(screenshot.jpeg.count > 1000)
    #expect(screenshot.height == 900)
    #expect(screenshot.nativeWidth == 390)
    let command = PhoneCommand(action: .tap, screenshotID: screenshot.id, idempotencyKey: "unique", x: 100, y: 150)
    let first = try await hub.execute(phoneID: "demo-iphone", command: command)
    let second = try await hub.execute(phoneID: "demo-iphone", command: command)
    #expect(first.id == second.id)
    #expect(first.status == "simulated")
    do { _ = try await hub.execute(phoneID: "demo-iphone", command: PhoneCommand(action: .tap, x: 1, y: 1)); Issue.record("Expected screenshot requirement") }
    catch { #expect((error as? KitError)?.code == "SCREENSHOT_REQUIRED") }
    do { _ = try await hub.execute(phoneID: "demo-iphone", command: PhoneCommand(action: .pressHome, idempotencyKey: "unique")); Issue.record("Expected conflict") }
    catch { #expect((error as? KitError)?.code == "IDEMPOTENCY_CONFLICT") }
    await hub.stop()
}
