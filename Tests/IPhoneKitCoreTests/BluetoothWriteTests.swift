import Foundation
@preconcurrency import IOBluetooth
import Testing

@testable import IPhoneKitCore

@Test func bluetoothSourceAvoidsMainThreadBlockingCalls() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let directory = root.appendingPathComponent("Sources/IPhoneKitCore")
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { file in file.pathExtension == "swift" }
    var openers = 0
    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(!source.contains(".writeSync("), "Synchronous Bluetooth write in \(file.lastPathComponent)")
        #expect(!source.contains("openL2CAPChannelSync"), "Synchronous Bluetooth open in \(file.lastPathComponent)")
        openers += source.components(separatedBy: "openL2CAPChannelAsync(").count - 1
    }
    #expect(openers == 1, "Keep native channel opening behind the guarded transport adapter")
}

@MainActor private final class WriteProbe {
    var identifiers: [UInt] = []
    var reports: [[UInt8]] = []
    var status: IOReturn = kIOReturnSuccess
    var complete: ((UInt) -> Void)?

    func submit(_ buffer: UnsafeMutableRawPointer, length: UInt16, refcon: UnsafeMutableRawPointer) -> IOReturn {
        let identifier = UInt(bitPattern: refcon)
        identifiers.append(identifier)
        reports.append(Array(UnsafeRawBufferPointer(start: buffer, count: Int(length))))
        complete?(identifier)
        return status
    }

    func writer(timeout: Duration = .seconds(2)) -> L2CAPWriter {
        L2CAPWriter(timeout: timeout) { buffer, length, refcon in
            self.submit(buffer, length: length, refcon: refcon)
        }
    }

    func waitForSubmission(count: Int = 1) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while identifiers.count < count {
            try #require(ContinuousClock.now < deadline, "No Bluetooth write was submitted.")
            await Task.yield()
        }
    }
}

@Test @MainActor func stalledWriteYieldsMainActorAndWaitsForAcknowledgement() async throws {
    let probe = WriteProbe()
    let writer = probe.writer()
    defer { writer.invalidate() }
    var finished = false
    let bytes = HIDReports.keyboard(modifiers: 2)
    let task = Task { @MainActor in
        try await writer.write(bytes)
        finished = true
    }
    try await probe.waitForSubmission()
    var heartbeat = false
    await Task { @MainActor in heartbeat = true }.value
    #expect(heartbeat && !finished)
    #expect(probe.reports == [bytes])
    writer.complete(identifier: probe.identifiers[0], status: kIOReturnSuccess)
    try await task.value
    #expect(finished && writer.pendingCount == 0)
    writer.complete(identifier: probe.identifiers[0], status: kIOReturnSuccess)
}

@Test @MainActor func missingWriteCompletionTimesOutAndFailsClosed() async throws {
    let probe = WriteProbe()
    let writer = probe.writer(timeout: .milliseconds(20))
    var failed = false
    writer.failed = { failed = true }
    do {
        try await writer.write(HIDReports.keyboard())
        Issue.record("Expected timeout")
    } catch { #expect((error as? KitError)?.code == "BLUETOOTH_TIMEOUT") }
    #expect(failed && writer.pendingCount == 0)
    writer.complete(identifier: probe.identifiers[0], status: kIOReturnSuccess)
    #expect(throws: KitError.self) { try writer.enqueue(HIDReports.keyboard()) }
}

@Test @MainActor func cancelledInFlightWriteResumesOnceAndKeepsItsWatchdog() async throws {
    let probe = WriteProbe()
    let writer = probe.writer(timeout: .milliseconds(40))
    let failure = AsyncStream<Void>.makeStream()
    writer.failed = {
        failure.continuation.yield(())
        failure.continuation.finish()
    }
    let task = Task { @MainActor in try await writer.write(HIDReports.keyboard()) }
    try await probe.waitForSubmission()
    task.cancel()
    do {
        try await task.value
        Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    #expect(writer.pendingCount == 1)
    for await _ in failure.stream {}
    #expect(writer.pendingCount == 0)
    #expect(throws: KitError.self) { try writer.enqueue(HIDReports.keyboard()) }
}

@Test @MainActor func synchronousWriteCompletionDoesNotLoseContinuation() async throws {
    let probe = WriteProbe()
    let writer = probe.writer()
    defer { writer.invalidate() }
    probe.complete = { [weak writer] identifier in writer?.complete(identifier: identifier, status: kIOReturnSuccess) }
    try await writer.write(HIDReports.keyboard())
    #expect(writer.pendingCount == 0)
}

@Test @MainActor func rejectedWriteFailsWithoutWaitingForTimeout() async throws {
    let probe = WriteProbe()
    probe.status = kIOReturnNotOpen
    let writer = probe.writer()
    var failed = false
    writer.failed = { failed = true }
    do {
        try await writer.write(HIDReports.keyboard())
        Issue.record("Expected rejected write")
    } catch { #expect((error as? KitError)?.code == "ACTION_INTERRUPTED") }
    #expect(failed && writer.pendingCount == 0)
}

@Test @MainActor func failedWriteCompletionInterruptsOutstandingWrites() async throws {
    let probe = WriteProbe()
    let writer = probe.writer()
    let task = Task { @MainActor in try await writer.write(HIDReports.keyboard()) }
    try await probe.waitForSubmission()
    try writer.enqueue(HIDReports.consumer())
    writer.complete(identifier: probe.identifiers[0], status: kIOReturnError)
    do {
        try await task.value
        Issue.record("Expected interrupted write")
    } catch { #expect((error as? KitError)?.code == "ACTION_INTERRUPTED") }
    #expect(writer.pendingCount == 0)
    #expect(probe.reports.count == 1)
    #expect(throws: KitError.self) { try writer.enqueue(HIDReports.keyboard()) }
    writer.complete(identifier: probe.identifiers[0], status: kIOReturnSuccess)
}

@Test @MainActor func disconnectSettlesWaitersAndLateCallbackCannotCompleteNewWrite() async throws {
    let oldProbe = WriteProbe()
    let oldWriter = oldProbe.writer()
    let oldTask = Task { @MainActor in try await oldWriter.write(HIDReports.keyboard()) }
    try await oldProbe.waitForSubmission()
    oldWriter.invalidate()
    do {
        try await oldTask.value
        Issue.record("Expected disconnect")
    } catch { #expect((error as? KitError)?.code == "BLUETOOTH_DISCONNECTED") }
    #expect(oldWriter.pendingCount == 0)
    let probe = WriteProbe()
    let writer = probe.writer()
    defer { writer.invalidate() }
    let task = Task { @MainActor in try await writer.write(HIDReports.keyboard()) }
    try await probe.waitForSubmission()
    writer.complete(identifier: oldProbe.identifiers[0], status: kIOReturnSuccess)
    #expect(writer.pendingCount == 1)
    writer.complete(identifier: probe.identifiers[0], status: kIOReturnSuccess)
    try await task.value
}

@Test @MainActor func neutralReportsRemainOrderedAndPendingWritesAreBounded() throws {
    let probe = WriteProbe()
    let writer = probe.writer()
    defer { writer.invalidate() }
    let reports = [HIDReports.keyboard(), HIDReports.consumer(), HIDDescriptor.absolutePointer(x: 32766, y: 32766)]
    for report in reports { try writer.enqueue(report) }
    #expect(probe.reports == [reports[0]])
    for _ in 3..<32 { try writer.enqueue(reports[0]) }
    #expect(throws: KitError.self) { try writer.enqueue(reports[0]) }
    #expect(writer.pendingCount == 32)
    var completed = 0
    while writer.pendingCount > 0 {
        #expect(probe.identifiers.count == completed + 1)
        writer.complete(identifier: probe.identifiers[completed], status: kIOReturnSuccess)
        completed += 1
    }
    #expect(probe.reports == reports + Array(repeating: reports[0], count: 29))
}

@MainActor private final class SuspendedTransport: ReportTransport {
    var epoch: UInt64 = 1
    var isReady = true
    var releases = 0
    let writer: L2CAPWriter
    init(writer: L2CAPWriter) { self.writer = writer }
    func send(_ report: [UInt8], epoch: UInt64, deadline: Date?) async throws {
        let remaining = deadline.map { deadline in Duration.seconds(deadline.timeIntervalSinceNow) }
        try await writer.write(report, maximumWait: remaining)
    }
    func neutralize(epoch: UInt64) { if self.epoch == epoch { releases += 1 } }
}

@Test @MainActor func connectionChangeDuringFinalWriteIsRejectedWithoutStaleRelease() async throws {
    let probe = WriteProbe()
    let writer = probe.writer()
    defer { writer.invalidate() }
    let transport = SuspendedTransport(writer: writer)
    let plan = GesturePlan(reports: [TimedReport(milliseconds: 0, bytes: HIDReports.keyboard())])
    let task = Task { @MainActor in
        try await GestureRunner().run(plan, transport: transport, epoch: 1, deadline: nil, stillValid: { true })
    }
    try await probe.waitForSubmission()
    transport.epoch = 2
    writer.complete(identifier: probe.identifiers[0], status: kIOReturnSuccess)
    do {
        try await task.value
        Issue.record("Expected connection change")
    } catch { #expect((error as? KitError)?.code == "CONNECTION_CHANGED") }
    #expect(transport.releases == 0)
}

@Test @MainActor func flickReportsAwaitCompletionInOrder() async throws {
    let probe = WriteProbe()
    let writer = probe.writer()
    defer { writer.invalidate() }
    probe.complete = { [weak writer] identifier in writer?.complete(identifier: identifier, status: kIOReturnSuccess) }
    let transport = SuspendedTransport(writer: writer)
    let geometry = ImageGeometry(width: 621, height: 1344, nativeWidth: 1170, nativeHeight: 2532)
    let plan = try GesturePlan.build(PhoneCommand(action: .flick, x: 310, y: 900, direction: "up"), geometry: geometry)
    try await GestureRunner(sleep: { _ in }).run(
        plan, transport: transport, epoch: 1, deadline: nil, stillValid: { true })
    #expect(probe.reports == plan.reports.map { report in report.bytes })
    #expect(probe.reports.last?[2] == 0)
    #expect(transport.releases == 0)
}

@Test @MainActor func writerIsReleasedWithItsOwnerEvenWithPendingWrites() throws {
    let probe = WriteProbe()
    var writer: L2CAPWriter? = probe.writer()
    weak let observed = writer
    try writer?.enqueue(HIDReports.keyboard())
    writer?.invalidate()
    writer = nil
    #expect(observed == nil)
}

@Test @MainActor func cancellationBeforeSubmissionSendsNothing() async {
    let probe = WriteProbe()
    let writer = probe.writer()
    defer { writer.invalidate() }
    let task = Task { @MainActor in try await writer.write(HIDReports.keyboard()) }
    task.cancel()
    do {
        try await task.value
        Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    #expect(probe.reports.isEmpty)
}

@Test @MainActor func cancelledQueuedWriteIsRemovedBeforeNativeSubmission() async throws {
    let probe = WriteProbe()
    let writer = probe.writer()
    defer { writer.invalidate() }
    try writer.enqueue(HIDReports.keyboard())
    let task = Task { @MainActor in try await writer.write(HIDReports.consumer()) }
    while writer.pendingCount < 2 { await Task.yield() }
    task.cancel()
    do {
        try await task.value
        Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    #expect(writer.pendingCount == 1)
    writer.complete(identifier: probe.identifiers[0], status: kIOReturnSuccess)
    #expect(probe.reports.count == 1)
}

@Test @MainActor func cancelledInputReleasesBeforeNextGestureIsSubmitted() async throws {
    let probe = WriteProbe()
    let writer = probe.writer()
    defer { writer.invalidate() }
    let held = HIDReports.keyboard(modifiers: 2)
    let release = HIDReports.keyboard()
    let next = HIDReports.consumer(0x0223)
    let task = Task { @MainActor in try await writer.write(held) }
    try await probe.waitForSubmission()
    task.cancel()
    do {
        try await task.value
        Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    try writer.enqueue(release)
    try writer.enqueue(next)
    #expect(probe.reports == [held])
    writer.complete(identifier: probe.identifiers[0], status: kIOReturnSuccess)
    #expect(probe.reports == [held, release])
    writer.complete(identifier: probe.identifiers[1], status: kIOReturnSuccess)
    #expect(probe.reports == [held, release, next])
    writer.complete(identifier: probe.identifiers[2], status: kIOReturnSuccess)
}

@Test @MainActor func actionBudgetShortensNativeWriteWatchdog() async throws {
    let probe = WriteProbe()
    let writer = probe.writer()
    let start = ContinuousClock.now
    do {
        try await writer.write(HIDReports.keyboard(), maximumWait: .milliseconds(20))
        Issue.record("Expected budget expiry")
    } catch { #expect((error as? KitError)?.code == "BLUETOOTH_TIMEOUT") }
    #expect(ContinuousClock.now - start < .seconds(1))
    #expect(writer.pendingCount == 0)
}
