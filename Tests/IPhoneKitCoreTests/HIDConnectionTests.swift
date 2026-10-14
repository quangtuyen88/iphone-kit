import Foundation
@preconcurrency import IOBluetooth
import Testing

@testable import IPhoneKitCore

private let phone = "02-00-00-00-00-01"

private final class FakeChannel: HIDChannel {
    let psm: BluetoothL2CAPPSM
    let deviceAddress: String?
    weak var delegate: HIDConnection?
    var shutdowns = 0
    var reports: [[UInt8]] = []
    var tokens: [UInt] = []
    var readyForInput = false
    var attachmentStatus: IOReturn = kIOReturnSuccess
    var completionOnAttach: IOReturn?

    init(psm: BluetoothL2CAPPSM, address: String = phone) {
        self.psm = psm
        deviceAddress = address
    }

    @discardableResult
    func attach(_ delegate: HIDConnection) -> IOReturn {
        guard attachmentStatus == kIOReturnSuccess else { return attachmentStatus }
        if self.delegate === delegate { return kIOReturnSuccess }
        self.delegate = delegate
        if let completionOnAttach { delegate.openCompleted(self, status: completionOnAttach) }
        return kIOReturnSuccess
    }

    func submit(_ buffer: UnsafeMutableRawPointer, length: UInt16, refcon: UnsafeMutableRawPointer) -> IOReturn {
        reports.append(Array(UnsafeRawBufferPointer(start: buffer, count: Int(length))))
        tokens.append(UInt(bitPattern: refcon))
        return kIOReturnSuccess
    }

    func shutdown() { shutdowns += 1 }
}

/// Mirrors the macOS 27 shim: opening without a baseband link is the call that freezes the main thread.
private final class FakeDevice: HIDRemoteDevice {
    var classicState: Int? = 0
    var aggregateConnected = false
    var isLinkUp: Bool {
        get {
            ClassicBluetooth.linkReady(
                requiresClassicState: true, classicState: classicState, reportedConnected: aggregateConnected)
        }
        set {
            classicState = newValue ? 2 : 0
            aggregateConnected = newValue
        }
    }
    var pages: [PageRequest] = []
    var opened: [FakeChannel] = []
    var opensWhileLinkDown = 0
    var opensReady = false
    var attachmentStatus: IOReturn = kIOReturnSuccess
    var completionOnAttach: IOReturn?

    func page(_ request: PageRequest) -> IOReturn {
        pages.append(request)
        if isLinkUp { request.complete(status: kIOReturnSuccess) }
        return kIOReturnSuccess
    }

    func openChannel(psm: BluetoothL2CAPPSM, delegate: HIDConnection) -> (IOReturn, (any HIDChannel)?) {
        if !isLinkUp { opensWhileLinkDown += 1 }
        let channel = FakeChannel(psm: psm)
        channel.readyForInput = opensReady
        channel.attachmentStatus = attachmentStatus
        channel.completionOnAttach = completionOnAttach
        opened.append(channel)
        return (kIOReturnSuccess, channel)
    }
}

private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000)
}

@MainActor private func makeConnection(_ device: FakeDevice, clock: Clock = Clock()) -> HIDConnection {
    HIDConnection(address: phone, resolve: { _ in device }, now: { clock.now })
}

/// Brings the link up the way the phone does: host-initiated control, then interrupt.
@MainActor private func ready(_ connection: HIDConnection) -> (control: FakeChannel, interrupt: FakeChannel) {
    let control = FakeChannel(psm: 0x11)
    let interrupt = FakeChannel(psm: 0x13)
    connection.accept(control)
    connection.accept(interrupt)
    var completed = 0
    while completed < interrupt.tokens.count {
        connection.writeCompleted(interrupt.tokens[completed], status: kIOReturnSuccess)
        completed += 1
    }
    return (control, interrupt)
}

@Test @MainActor func disconnectedPhoneIsPagedBeforeAnyChannelOpens() {
    let device = FakeDevice()
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    connection.connect()
    #expect(connection.connecting && device.pages.count == 1 && device.opened.isEmpty)
    device.isLinkUp = true
    connection.pageCompleted(device.pages[0], status: kIOReturnSuccess)
    #expect(device.opened.map(\.psm) == [0x11])
    connection.openCompleted(device.opened[0], status: kIOReturnSuccess)
    #expect(device.opened.map(\.psm) == [0x11, 0x13])
    connection.openCompleted(device.opened[1], status: kIOReturnSuccess)
    #expect(connection.isReady && !connection.connecting)
    #expect(device.opensWhileLinkDown == 0)
    #expect(device.opened[1].reports == [HIDReports.keyboard()])
    #expect(device.opened.allSatisfy { channel in channel.shutdowns == 0 })
}

@Test @MainActor func linkThatDropsBeforeOpeningNeverReachesIOBluetoothOpen() async throws {
    let device = FakeDevice()
    let connection = HIDConnection(address: phone, resolve: { _ in device }, readinessTimeout: .milliseconds(25))
    connection.connect()
    connection.pageCompleted(device.pages[0], status: kIOReturnSuccess)
    #expect(connection.connecting && device.opened.isEmpty)
    try await waitForHIDCondition { !connection.connecting }
    #expect(device.opened.isEmpty && device.opensWhileLinkDown == 0)
    #expect(connection.failures == 1)
}

@Test @MainActor func failedAttemptsBackOffThenPauseUntilExplicitRequest() {
    let device = FakeDevice()
    let clock = Clock()
    let connection = makeConnection(device, clock: clock)
    for (index, delay) in HIDConnection.retryDelays.enumerated() {
        connection.connect()
        #expect(device.pages.count == index + 1)
        connection.pageCompleted(device.pages[index], status: kIOReturnError)
        connection.connect()
        #expect(device.pages.count == index + 1, "Retry must wait \(delay) s")
        clock.now += delay
    }
    connection.connect()
    #expect(device.pages.count == 4)
    connection.pageCompleted(device.pages[3], status: kIOReturnError)
    clock.now += 3_600
    connection.connect()
    #expect(device.pages.count == 4, "Automatic reconnects pause after the last delay")
    connection.connect(userInitiated: true)
    #expect(device.pages.count == 5)
    connection.invalidate()
}

@Test @MainActor func stalePageCompletionCannotOpenChannelsForANewerAttempt() {
    let device = FakeDevice()
    let clock = Clock()
    let connection = makeConnection(device, clock: clock)
    defer { connection.invalidate() }
    connection.connect()
    connection.pageCompleted(device.pages[0], status: kIOReturnError)
    clock.now += HIDConnection.retryDelays[0]
    connection.connect()
    device.isLinkUp = true
    connection.pageCompleted(device.pages[0], status: kIOReturnSuccess)
    #expect(device.opened.isEmpty)
    connection.pageCompleted(device.pages[1], status: kIOReturnSuccess)
    #expect(device.opened.map(\.psm) == [0x11])
}

@Test @MainActor func aliasAndStaleCallbacksNeverCloseTheLiveLink() {
    let device = FakeDevice()
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    let (control, interrupt) = ready(connection)
    #expect(connection.isReady)
    let epoch = connection.epoch
    let strays = [FakeChannel(psm: 0x11), FakeChannel(psm: 0x11), FakeChannel(psm: 0x13)]
    connection.openCompleted(strays[0], status: kIOReturnError)
    connection.openCompleted(strays[1], status: kIOReturnSuccess)
    connection.channelClosed(strays[2])
    let alias = FakeChannel(psm: 0x11)
    connection.accept(alias)
    #expect(connection.isReady && connection.epoch == epoch)
    #expect(alias.delegate === connection)
    #expect(([control, interrupt, alias] + strays).allSatisfy { channel in channel.shutdowns == 0 })
}

@Test @MainActor func writesUseTheNewestWrapperAndCompleteByToken() async throws {
    let device = FakeDevice()
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    _ = ready(connection)
    let replacement = FakeChannel(psm: 0x13)
    connection.accept(replacement)
    let report = HIDReports.keyboard(modifiers: 2)
    let task = Task { @MainActor in try await connection.send(report, epoch: connection.epoch, deadline: nil) }
    while replacement.tokens.isEmpty { await Task.yield() }
    #expect(replacement.reports == [report])
    connection.writeCompleted(replacement.tokens[0], status: kIOReturnSuccess)
    try await task.value
}

@Test @MainActor func cancelledNativeInterruptWriteDrainsWithoutChangingEpoch() async throws {
    let device = FakeDevice()
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    let (_, interrupt) = ready(connection)
    let epoch = connection.epoch
    let originalTokenCount = interrupt.tokens.count
    var changes = 0
    connection.changed = { changes += 1 }
    let task = Task { @MainActor in
        try await connection.send(HIDReports.keyboard(modifiers: 2), epoch: epoch, deadline: nil)
    }
    while interrupt.tokens.count == originalTokenCount { await Task.yield() }

    #expect(connection.pendingInputWrites == 1)
    task.cancel()
    do {
        try await task.value
        Issue.record("Expected cancellation")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(connection.pendingInputWrites == 1)
    #expect(changes == 0)
    #expect(connection.epoch == epoch)

    let token = interrupt.tokens[originalTokenCount]
    connection.writeCompleted(token, status: kIOReturnSuccess)
    #expect(connection.pendingInputWrites == 0)
    #expect(changes == 1)
    #expect(connection.epoch == epoch)
    connection.writeCompleted(token, status: kIOReturnSuccess)
    #expect(changes == 1)
}

@Test @MainActor func liveChannelCloseTearsDownEachPSMOnce() {
    let device = FakeDevice()
    let connection = makeConnection(device)
    let (control, interrupt) = ready(connection)
    let replacement = FakeChannel(psm: 0x11)
    connection.accept(replacement)
    connection.channelClosed(control)
    #expect(connection.isReady, "A superseded wrapper's late close must not kill its replacement")
    connection.channelClosed(replacement)
    #expect(!connection.isReady && !connection.connecting)
    #expect(replacement.shutdowns == 0 && interrupt.shutdowns == 1 && control.shutdowns == 0)
    connection.channelClosed(interrupt)
    #expect(replacement.shutdowns + interrupt.shutdowns == 1)
}

@Test @MainActor func controlRequestsFromSupersededWrappersAreIgnored() {
    let device = FakeDevice()
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    let (control, _) = ready(connection)
    let replacement = FakeChannel(psm: 0x11)
    connection.accept(replacement)
    connection.received([0x15], on: control)
    #expect(connection.enabled && connection.isReady)
    connection.received([0x15], on: replacement)
    #expect(!connection.enabled && !connection.isReady)
}

@Test @MainActor func suspendKeepsChannelsWithoutRedundantReconnects() {
    let device = FakeDevice()
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    let (control, interrupt) = ready(connection)
    connection.received([0x13], on: control)
    #expect(!connection.isReady)
    connection.connect()
    #expect(device.pages.isEmpty && device.opened.isEmpty)
    connection.received([0x14], on: control)
    #expect(connection.isReady)
    #expect(control.shutdowns == 0 && interrupt.shutdowns == 0)
}

@Test @MainActor func linkDroppingRightAfterConnectingCountsAsFailure() {
    let device = FakeDevice()
    let clock = Clock()
    let connection = makeConnection(device, clock: clock)
    let (_, interrupt) = ready(connection)
    clock.now += 2
    connection.channelClosed(interrupt)
    #expect(connection.failures == 1)
    connection.connect()
    #expect(device.pages.isEmpty)
    clock.now += HIDConnection.retryDelays[0]
    connection.connect()
    #expect(device.pages.count == 1)
    connection.invalidate()
}

@Test @MainActor func phoneInitiatedChannelsResumePausedReconnects() {
    let device = FakeDevice()
    let clock = Clock()
    let connection = makeConnection(device, clock: clock)
    defer { connection.invalidate() }
    for index in 0...HIDConnection.retryDelays.count {
        connection.connect()
        connection.pageCompleted(device.pages[index], status: kIOReturnError)
        clock.now += 3_600
    }
    connection.connect()
    #expect(device.pages.count == HIDConnection.retryDelays.count + 1)
    let (_, interrupt) = ready(connection)
    #expect(connection.isReady)
    clock.now += 10
    connection.channelClosed(interrupt)
    #expect(connection.failures == 0, "A sustained link clears the backoff")
    connection.connect()
    #expect(device.pages.count == HIDConnection.retryDelays.count + 2)
}

@Test @MainActor func flappingPhoneLinkPausesAutomaticReconnects() {
    let device = FakeDevice()
    let clock = Clock()
    let connection = makeConnection(device, clock: clock)
    defer { connection.invalidate() }
    for _ in 0...HIDConnection.retryDelays.count {
        let (_, interrupt) = ready(connection)
        clock.now += 2
        connection.channelClosed(interrupt)
    }
    #expect(connection.failures == HIDConnection.retryDelays.count + 1)
    clock.now += 3_600
    connection.connect()
    #expect(device.pages.isEmpty)
}

@Test @MainActor func disabledConnectionRejectsPhoneInitiatedChannels() {
    let device = FakeDevice()
    let connection = makeConnection(device)
    connection.enabled = false
    let channel = FakeChannel(psm: 0x11)
    connection.accept(channel)
    #expect(channel.shutdowns == 1 && !connection.connecting)
    let foreign = FakeChannel(psm: 0x11, address: "00-11-22-33-44-55")
    connection.enabled = true
    connection.accept(foreign)
    #expect(foreign.shutdowns == 0 && !connection.connecting)
}

@Test @MainActor func openErrorFromTheCurrentAttemptFailsItOnce() {
    let device = FakeDevice()
    device.isLinkUp = true
    let connection = makeConnection(device)
    connection.connect()
    #expect(device.opened.map(\.psm) == [0x11])
    connection.openCompleted(device.opened[0], status: kIOReturnError)
    #expect(!connection.connecting && connection.failures == 1)
    connection.openCompleted(device.opened[0], status: kIOReturnError)
    #expect(connection.failures == 1)
}

@MainActor private func waitForHIDCondition(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "Bluetooth state did not settle")
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test @MainActor func successfulPageWaitsForLinkReadinessWithoutOpeningWhileDown() async throws {
    let device = FakeDevice()
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    connection.connect()
    connection.pageCompleted(device.pages[0], status: kIOReturnSuccess)
    try #require(connection.connecting && connection.failures == 0)
    #expect(device.opened.isEmpty && device.opensWhileLinkDown == 0)
    // Publish readiness before yielding; other MainActor tests can exhaust the polling deadline.
    device.isLinkUp = true
    try await waitForHIDCondition { !device.opened.isEmpty }
    connection.openCompleted(device.opened[0], status: kIOReturnSuccess)
    connection.openCompleted(device.opened[1], status: kIOReturnSuccess)
    #expect(connection.isReady && device.opensWhileLinkDown == 0)
}

@Test @MainActor func pagingAndBothChannelsUseOneResolvedDevice() {
    let device = FakeDevice()
    var resolutions = 0
    let connection = HIDConnection(
        address: phone,
        resolve: { _ in
            resolutions += 1
            return device
        })
    defer { connection.invalidate() }
    connection.connect()
    device.isLinkUp = true
    connection.pageCompleted(device.pages[0], status: kIOReturnSuccess)
    connection.openCompleted(device.opened[0], status: kIOReturnSuccess)
    connection.openCompleted(device.opened[1], status: kIOReturnSuccess)
    #expect(connection.isReady && resolutions == 1)
}

@Test @MainActor func invalidationCancelsDeferredBluetoothReadiness() async throws {
    let device = FakeDevice()
    let connection = makeConnection(device)
    connection.connect()
    connection.pageCompleted(device.pages[0], status: kIOReturnSuccess)
    try #require(connection.connecting)
    connection.invalidate()
    device.isLinkUp = true
    try await Task.sleep(for: .milliseconds(60))
    #expect(device.opened.isEmpty && !connection.connecting && connection.failures == 0)
}

@Test @MainActor func duplicatePagingCompletionCannotAbortOpeningChannels() {
    let device = FakeDevice()
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    connection.connect()
    device.isLinkUp = true
    connection.pageCompleted(device.pages[0], status: kIOReturnSuccess)
    connection.pageCompleted(device.pages[0], status: kIOReturnError)
    #expect(connection.connecting && connection.failures == 0)
    #expect(device.opened.count == 1 && device.opened[0].shutdowns == 0)
}

@Test @MainActor func reconnectAfterDeferredReadinessIgnoresOldAttempt() async throws {
    let oldDevice = FakeDevice()
    let newDevice = FakeDevice()
    var current = oldDevice
    let connection = HIDConnection(address: phone, resolve: { _ in current })
    defer { connection.invalidate() }
    connection.connect()
    connection.pageCompleted(oldDevice.pages[0], status: kIOReturnSuccess)
    connection.invalidate()
    current = newDevice
    connection.connect(userInitiated: true)
    oldDevice.isLinkUp = true
    newDevice.isLinkUp = true
    connection.pageCompleted(newDevice.pages[0], status: kIOReturnSuccess)
    try await Task.sleep(for: .milliseconds(60))
    #expect(oldDevice.opened.isEmpty && newDevice.opened.count == 1 && connection.failures == 0)
}

@Test @MainActor func classicHIDReconnectIgnoresDisconnectedBLEState() {
    let device = FakeDevice()
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    device.isLinkUp = true
    connection.connect()
    connection.openCompleted(device.opened[0], status: kIOReturnSuccess)
    connection.openCompleted(device.opened[1], status: kIOReturnSuccess)
    #expect(connection.isReady && device.pages.count == 1)
    connection.channelClosed(device.opened[0])
    device.classicState = 0
    device.aggregateConnected = false
    connection.connect(userInitiated: true)
    device.classicState = 2
    connection.pageCompleted(device.pages[1], status: kIOReturnSuccess)
    #expect(device.opened.count == 3 && device.aggregateConnected == false)
    connection.openCompleted(device.opened[2], status: kIOReturnSuccess)
    connection.openCompleted(device.opened[3], status: kIOReturnSuccess)
    #expect(connection.isReady && device.opensWhileLinkDown == 0)
}

@Test @MainActor func BLEConnectionCannotStandInForClassicHIDReadiness() {
    let device = FakeDevice()
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    device.classicState = 0
    device.aggregateConnected = true
    connection.connect()
    #expect(device.pages.count == 1 && device.opened.isEmpty)
    #expect(!ClassicBluetooth.linkReady(requiresClassicState: true, classicState: nil, reportedConnected: true))
    #expect(!ClassicBluetooth.linkReady(requiresClassicState: true, classicState: 1, reportedConnected: true))
    #expect(ClassicBluetooth.linkReady(requiresClassicState: false, classicState: nil, reportedConnected: true))
    #expect(!ClassicBluetooth.linkReady(requiresClassicState: false, classicState: nil, reportedConnected: false))
}

@Test @MainActor func immediateChannelCompletionSeesRegisteredAttempt() {
    let device = FakeDevice()
    device.isLinkUp = true
    device.completionOnAttach = kIOReturnSuccess
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    connection.connect()
    #expect(connection.isReady && device.opened.map { channel in channel.psm } == [0x11, 0x13])
}

@Test @MainActor func immediateChannelFailureDoesNotWaitForTimeout() {
    let device = FakeDevice()
    device.isLinkUp = true
    device.completionOnAttach = kIOReturnError
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    connection.connect()
    #expect(!connection.connecting && connection.failures == 1 && device.opened.count == 1)
}

@Test @MainActor func delegateRegistrationFailureStopsTheAttempt() {
    let device = FakeDevice()
    device.isLinkUp = true
    device.attachmentStatus = kIOReturnError
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    connection.connect()
    #expect(!connection.connecting && connection.failures == 1 && device.opened.count == 1)
    #expect(device.opened[0].shutdowns == 1)
}

@Test @MainActor func alreadyOpenNativeChannelDoesNotNeedAnotherOpenCallback() {
    let device = FakeDevice()
    device.classicState = 2
    device.aggregateConnected = false
    device.opensReady = true
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    connection.connect()
    #expect(connection.isReady && device.opened.count == 2)
    let epoch = connection.epoch
    connection.openCompleted(device.opened[0], status: kIOReturnSuccess)
    connection.openCompleted(device.opened[1], status: kIOReturnSuccess)
    #expect(connection.isReady && connection.epoch == epoch)
}

@Test @MainActor func incomingControlRaceStillOpensInterruptChannel() throws {
    let device = FakeDevice()
    device.isLinkUp = true
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    connection.connect()
    let incoming = FakeChannel(psm: 0x11)
    connection.accept(incoming)
    try #require(device.opened.count == 2, "Incoming control must not strand interrupt setup")
    connection.openCompleted(device.opened[0], status: kIOReturnSuccess)
    connection.openCompleted(device.opened[1], status: kIOReturnSuccess)
    #expect(connection.isReady && incoming.shutdowns == 0)
}

@Test @MainActor func incomingControlOnlyCompletesTheRemainingChannel() throws {
    let device = FakeDevice()
    device.classicState = 2
    let connection = makeConnection(device)
    defer { connection.invalidate() }
    connection.accept(FakeChannel(psm: 0x11))
    try #require(device.opened.map { channel in channel.psm } == [0x13])
    connection.openCompleted(device.opened[0], status: kIOReturnSuccess)
    #expect(connection.isReady && device.pages.isEmpty)
}
