import Foundation
import AppKit
import os
@preconcurrency import CoreBluetooth
@preconcurrency import IOBluetooth

let bluetoothLog = Logger(subsystem: "dev.iphonekit.mac", category: "bluetooth")

func normalizedBluetoothAddress(_ address: String) -> String {
    address.lowercased().replacingOccurrences(of: ":", with: "-")
}

@MainActor
final class HIDHost: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var permissionWaiters: [CheckedContinuation<Void, any Error>] = []
    private var record: IOBluetoothSDPServiceRecord?
    private var notifications: [IOBluetoothUserNotification] = []
    private var visibilityManager: NSObject?
    private var pairingTimeout: Task<Void, Never>?
    private(set) var connections: [String: HIDConnection] = [:]
    var changed: (() -> Void)?
    var diagnostic: ((String) -> Void)?
    var permission: String {
        switch CBManager.authorization {
        case .allowedAlways: "allowed"
        case .denied, .restricted: "denied"
        default: "not_requested"
        }
    }

    func requestPermission() async throws {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        if central?.state == .poweredOn { return }
        if central?.state == .poweredOff { throw KitError("BLUETOOTH_OFF", "Turn on Bluetooth in System Settings.") }
        if CBManager.authorization == .denied || CBManager.authorization == .restricted {
            throw KitError("BLUETOOTH_PERMISSION", "Allow iPhoneKit in System Settings > Privacy & Security > Bluetooth.")
        }
        try await withCheckedThrowingContinuation { permissionWaiters.append($0) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let error: KitError?
        switch central.state {
        case .poweredOn: error = nil
        case .poweredOff: error = KitError("BLUETOOTH_OFF", "Turn on Bluetooth in System Settings.")
        case .unauthorized: error = KitError("BLUETOOTH_PERMISSION", "Allow iPhoneKit Bluetooth access in System Settings.")
        case .unsupported: error = KitError("BLUETOOTH_UNSUPPORTED", "This Mac has no supported Bluetooth controller.")
        default: changed?(); return
        }
        let waiters = permissionWaiters
        permissionWaiters.removeAll()
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
        if central.state != .poweredOn {
            for connection in connections.values { connection.invalidate(reason: "Bluetooth unavailable") }
        }
        changed?()
    }

    func startService() throws {
        guard record == nil else { return }
        guard let published = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: SDP.hidRecord(name: "iPhoneKit HID")) else {
            throw KitError("HID_UNAVAILABLE", "This macOS version could not publish the Bluetooth HID service.")
        }
        record = published
        for psm: BluetoothL2CAPPSM in [0x11, 0x13] {
            guard let note = IOBluetoothL2CAPChannel.register(forChannelOpenNotifications: self,
                      selector: #selector(incoming(_:channel:)), withPSM: psm,
                      direction: kIOBluetoothUserNotificationChannelDirectionIncoming) else {
                stop()
                throw KitError("HID_UNAVAILABLE", "Bluetooth input channels are unavailable. Quit other phone-control applications.")
            }
            notifications.append(note)
        }
        diagnostic?("Bluetooth HID service ready.")
    }

    func connection(address: String) -> HIDConnection {
        let key = normalizedBluetoothAddress(address)
        if let connection = connections[key] { connection.enabled = true; return connection }
        let connection = HIDConnection(address: key)
        connection.changed = { [weak self] in self?.changed?() }
        connection.diagnostic = { [weak self] message in self?.diagnostic?(message) }
        connections[key] = connection
        return connection
    }

    @objc private func incoming(_ note: IOBluetoothUserNotification, channel: IOBluetoothL2CAPChannel) {
        guard let address = channel.device?.addressString,
              let connection = connections[normalizedBluetoothAddress(address)], connection.enabled else {
            bluetoothLog.notice("HID rejecting incoming PSM \(channel.psm): device is not under control")
            channel.close()
            return
        }
        connection.accept(channel)
    }

    func beginPairing() throws {
        if visibilityManager == nil {
            guard let type = NSClassFromString("CBClassicManager") as? NSObject.Type,
                  let allocated = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
                  allocated.responds(to: NSSelectorFromString("initWithQueue:options:")),
                  let initialized = allocated.perform(NSSelectorFromString("initWithQueue:options:"), with: DispatchQueue.main, with: nil)?.takeUnretainedValue() as? NSObject else {
                throw KitError("PAIRING_UNAVAILABLE", "Automatic discoverability is unavailable. Open System Settings > Bluetooth, then pair from the iPhone.")
            }
            visibilityManager = initialized
        }
        guard setDiscoverable(true) else { throw KitError("PAIRING_UNAVAILABLE", "Bluetooth pairing changed in this macOS version.") }
        pairingTimeout?.cancel()
        pairingTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            self?.endPairing()
        }
        diagnostic?("Pair from iPhone Settings > Bluetooth. Mac discoverable for three minutes.")
    }

    func endPairing() {
        pairingTimeout?.cancel()
        pairingTimeout = nil
        _ = setDiscoverable(false)
    }

    private func setDiscoverable(_ value: Bool) -> Bool {
        guard let manager = visibilityManager else { return false }
        let selector = NSSelectorFromString("setBTDiscoverable:")
        guard manager.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(manager.method(for: selector), to: Setter.self)(manager, selector, value)
        return true
    }

    func reconnect() {
        guard central?.state == .poweredOn else { return }
        for connection in connections.values where connection.enabled { connection.connect() }
    }

    func stop() {
        endPairing()
        for connection in connections.values {
            connection.enabled = false
            connection.invalidate(reason: "Bluetooth service stopped")
        }
        connections.removeAll()
        notifications.forEach { $0.unregister() }
        notifications.removeAll()
        _ = record?.remove()
        record = nil
        visibilityManager = nil
        let waiters = permissionWaiters
        permissionWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: KitError("CANCELLED", "Bluetooth setup cancelled.")) }
    }
}

/// The parts of `IOBluetoothL2CAPChannel` the HID link uses, so the connection state machine can run against fakes.
@MainActor
protocol HIDChannel: AnyObject {
    var psm: BluetoothL2CAPPSM { get }
    var deviceAddress: String? { get }
    var readyForInput: Bool { get }
    @discardableResult func attach(_ delegate: HIDConnection) -> IOReturn
    func submit(_ buffer: UnsafeMutableRawPointer, length: UInt16, refcon: UnsafeMutableRawPointer) -> IOReturn
    func shutdown()
}

/// The parts of `IOBluetoothDevice` the HID link uses.
@MainActor
protocol HIDRemoteDevice: AnyObject {
    var isLinkUp: Bool { get }
    func page(_ request: PageRequest) -> IOReturn
    func openChannel(psm: BluetoothL2CAPPSM, delegate: HIDConnection) -> (IOReturn, (any HIDChannel)?)
}

extension IOBluetoothL2CAPChannel: HIDChannel {
    var deviceAddress: String? { device?.addressString.map(normalizedBluetoothAddress) }
    var readyForInput: Bool { ClassicBluetooth.channelIsOpen(self) }

    @discardableResult
    func attach(_ delegate: HIDConnection) -> IOReturn {
        // Attaching re-points CoreBluetooth's shared streams at this wrapper; skip wrappers already attached.
        if (self.delegate() as AnyObject?) === delegate { return kIOReturnSuccess }
        return setDelegate(delegate)
    }

    func submit(_ buffer: UnsafeMutableRawPointer, length: UInt16, refcon: UnsafeMutableRawPointer) -> IOReturn {
        writeAsync(buffer, length: length, refcon: refcon)
    }

    func shutdown() { close() }
}

@MainActor
extension IOBluetoothDevice: HIDRemoteDevice {
    var isLinkUp: Bool { ClassicBluetooth.isLinkUp(self) }

    func page(_ request: PageRequest) -> IOReturn {
        openConnection(request, withPageTimeout: 0x2000, authenticationRequired: false)
    }

    func openChannel(psm: BluetoothL2CAPPSM, delegate: HIDConnection) -> (IOReturn, (any HIDChannel)?) {
        let (status, channel) = ClassicBluetooth.open(self, psm: psm, delegate: delegate)
        return (status, channel)
    }
}

/// Paging target for one connection attempt; IOBluetooth reports `connectionComplete:status:` to it.
@MainActor
final class PageRequest: NSObject {
    let attempt: UInt64
    let device: any HIDRemoteDevice
    private weak var owner: HIDConnection?

    init(owner: HIDConnection, attempt: UInt64, device: any HIDRemoteDevice) {
        self.owner = owner
        self.attempt = attempt
        self.device = device
    }

    func complete(status: IOReturn) {
        owner?.pageCompleted(self, status: status)
    }

    @objc(connectionComplete:status:)
    nonisolated func connectionComplete(_ device: IOBluetoothDevice?, status: IOReturn) {
        let aggregateReady = device?.isConnected() ?? false
        DispatchQueue.main.async { [self] in
            bluetoothLog.notice(
                "HID page result \(self.attempt): status=\(status), aggregateReady=\(aggregateReady), classicReady=\(self.device.isLinkUp)"
            )
            complete(status: status)
        }
    }
}

/// One Bluetooth HID link to a phone: control (PSM 0x11) and interrupt (PSM 0x13) channels.
///
/// On macOS 27 IOBluetooth is a CoreBluetooth shim with three traps this type is built around:
/// `openL2CAPChannelAsync` on a device without a baseband link pages by spinning a nested run loop on the main
/// thread for 3 s per try and retries forever; `closeChannel` closes by (device, PSM), so closing any alias wrapper
/// kills the live channel; and several wrappers can share one channel and its streams.
@MainActor
final class HIDConnection: NSObject, @preconcurrency IOBluetoothL2CAPChannelDelegate, ReportTransport {
    /// Waits after consecutive failures; past the last one only the phone or an explicit request reconnects.
    static let retryDelays: [TimeInterval] = [5, 15, 45]
    let address: String
    var enabled = true
    private(set) var epoch: UInt64 = 0
    private(set) var isReady = false
    private(set) var connecting = false
    private(set) var failures = 0
    private var retryAt = Date.distantPast
    private var readySince: Date?
    private var attempt: UInt64 = 0
    private var control: (any HIDChannel)?
    private var interrupt: (any HIDChannel)?
    private var controlWriter: L2CAPWriter?
    private var interruptWriter: L2CAPWriter?
    /// PSMs the current attempt is opening; any wrapper reporting one open is the same IOBluetooth channel.
    private var awaiting: Set<BluetoothL2CAPPSM> = []
    private var opening: [ObjectIdentifier: (channel: any HIDChannel, attempt: UInt64)] = [:]
    /// Every wrapper of the current link, retained because any of them may own the channel's streams.
    private var seen: [ObjectIdentifier: any HIDChannel] = [:]
    /// Wrappers superseded by a newer phone-initiated channel: kept alive, but their callbacks no longer count.
    private var retired: [any HIDChannel] = []
    private var pages: [ObjectIdentifier: PageRequest] = [:]
    private var connectionDevice: (any HIDRemoteDevice)?
    private var readinessTask: Task<Void, Never>?
    private let readinessTimeout: Duration
    private(set) var setupMessage = "On iPhone: Settings > Bluetooth > tap this Mac."
    private var timeout: Task<Void, Never>?
    private let resolve: (String) -> (any HIDRemoteDevice)?
    private let now: () -> Date
    var changed: (() -> Void)?
    var diagnostic: ((String) -> Void)?

    init(
        address: String,
        resolve: @escaping (String) -> (any HIDRemoteDevice)? = { address in IOBluetoothDevice(addressString: address)
        }, now: @escaping () -> Date = Date.init, readinessTimeout: Duration = .seconds(1)
    ) {
        self.address = address
        self.resolve = resolve
        self.now = now
        self.readinessTimeout = readinessTimeout
    }

    /// Starts an outgoing reconnect. Automatic calls respect the backoff; explicit requests reset it.
    func connect(userInitiated: Bool = false) {
        if userInitiated { resetBackoff() }
        guard enabled, !isReady, !connecting, control == nil || interrupt == nil,
            failures <= Self.retryDelays.count, now() >= retryAt, let device = resolve(address)
        else { return }
        attempt &+= 1
        epoch &+= 1
        connectionDevice = device
        connecting = true
        setupMessage = "Connecting Bluetooth input…"
        changed?()
        armTimeout()
        // Confirm this application's connection even when the system reports an existing link from another session.
        let request = PageRequest(owner: self, attempt: attempt, device: device)
        pages[ObjectIdentifier(request)] = request
        let status = device.page(request)
        bluetoothLog.notice("HID attempt \(self.attempt) paging \(self.address, privacy: .public): \(status)")
        if status != kIOReturnSuccess {
            pages.removeValue(forKey: ObjectIdentifier(request))
            failAttempt("paging returned \(status)")
        }
    }

    func resetBackoff() {
        failures = 0
        retryAt = .distantPast
    }

    func pageCompleted(_ request: PageRequest, status: IOReturn) {
        guard pages.removeValue(forKey: ObjectIdentifier(request)) != nil,
            request.attempt == attempt, connecting, enabled, !isReady
        else { return }
        guard status == kIOReturnSuccess else {
            failAttempt("paging failed with \(status)")
            return
        }
        let device = request.device
        if device.isLinkUp {
            openNextChannel(on: device)
            return
        }
        setupMessage = "Waiting for Bluetooth input channels…"
        changed?()
        let deadline = ContinuousClock.now + readinessTimeout
        // Do not invoke the SDK's hidden synchronous opener until this attempt's device reports an active link.
        readinessTask = Task { [weak self] in
            while true {
                guard let self, !Task.isCancelled, request.attempt == attempt, connecting, enabled, !isReady else {
                    return
                }
                if device.isLinkUp {
                    readinessTask = nil
                    bluetoothLog.notice("HID attempt \(self.attempt): link ready after successful paging")
                    openNextChannel(on: device)
                    return
                }
                if ContinuousClock.now >= deadline {
                    readinessTask = nil
                    failAttempt("paging succeeded but the Bluetooth link never became ready")
                    return
                }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
        }
    }

    /// Opens control, then interrupt, only while the baseband link is up so IOBluetooth stays asynchronous.
    private func openNextChannel(on device: any HIDRemoteDevice) {
        let psm: BluetoothL2CAPPSM = control == nil ? 0x11 : 0x13
        guard slot(psm) == nil, !awaiting.contains(psm) else { return }
        guard device.isLinkUp else {
            failAttempt("Classic Bluetooth dropped before opening PSM \(psm)")
            return
        }
        let current = attempt
        awaiting.insert(psm)
        let (status, channel) = device.openChannel(psm: psm, delegate: self)
        guard attempt == current, connecting else { return }
        guard status == kIOReturnSuccess, let channel else {
            awaiting.remove(psm)
            failAttempt("opening PSM \(psm) returned \(status)")
            return
        }
        let identifier = ObjectIdentifier(channel)
        seen[identifier] = channel
        opening[identifier] = (channel, current)
        let attached = channel.attach(self)
        guard attempt == current, connecting else { return }
        if attached != kIOReturnSuccess {
            failAttempt("attaching PSM \(psm) delegate returned \(attached)")
        } else if channel.readyForInput, opening[identifier]?.attempt == current {
            // A cached native channel can already be open before its delegate is installed.
            openCompleted(channel, status: kIOReturnSuccess)
        }
    }

    func l2capChannelOpenComplete(_ channel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        guard let channel else { return }
        openCompleted(channel, status: error)
    }

    func openCompleted(_ channel: any HIDChannel, status: IOReturn) {
        let started = opening.removeValue(forKey: ObjectIdentifier(channel))?.attempt
        let psm = channel.psm
        let expected = connecting && enabled && awaiting.contains(psm) && channel.deviceAddress == address
        guard status == kIOReturnSuccess else {
            // Errors from aliases or earlier attempts are ignored; closing them would close the live channel.
            if expected, started == attempt {
                awaiting.remove(psm)
                failAttempt("opening PSM \(psm) failed with \(status)")
            }
            return
        }
        guard expected else {
            if !enabled, slot(psm) == nil, channel.deviceAddress == address {
                close(channel, reason: "opened after control was disabled")
            }
            return
        }
        awaiting.remove(psm)
        guard adopt(channel) else { return }
        if psm == 0x11, interrupt == nil, let device = connectionDevice { openNextChannel(on: device) }
        finishOpening()
    }

    /// Host-initiated channel from the phone.
    func accept(_ channel: any HIDChannel) {
        let psm = channel.psm
        guard channel.deviceAddress == address, psm == 0x11 || psm == 0x13 else { return }
        guard enabled else {
            close(channel, reason: "phone opened PSM \(psm) while control is disabled")
            return
        }
        if !connecting, !isReady, control == nil || interrupt == nil {
            attempt &+= 1
            epoch &+= 1
            connecting = true
            setupMessage = "Connecting Bluetooth input…"
            armTimeout()
            changed?()
        }
        awaiting.remove(psm)
        // The newest wrapper from the phone wins; the occupant may be a channel whose close never arrived.
        guard adopt(channel) else { return }
        bluetoothLog.notice("HID incoming PSM \(psm) accepted")
        if control == nil || interrupt == nil,
            let device = connectionDevice ?? resolve(address), device.isLinkUp
        {
            connectionDevice = device
            openNextChannel(on: device)
        }
        finishOpening()
    }

    @discardableResult
    private func adopt(_ channel: any HIDChannel) -> Bool {
        if let old = slot(channel.psm), old !== channel {
            seen.removeValue(forKey: ObjectIdentifier(old))
            retired.append(old)
        }
        seen[ObjectIdentifier(channel)] = channel
        if channel.psm == 0x11 {
            control = channel
            if controlWriter == nil { controlWriter = makeWriter(psm: 0x11) }
        } else {
            interrupt = channel
            if interruptWriter == nil { interruptWriter = makeWriter(psm: 0x13) }
        }
        let status = channel.attach(self)
        guard status == kIOReturnSuccess else {
            failAttempt("attaching PSM \(channel.psm) delegate returned \(status)")
            return false
        }
        return slot(channel.psm) === channel
    }

    private func slot(_ psm: BluetoothL2CAPPSM) -> (any HIDChannel)? { psm == 0x11 ? control : interrupt }

    private func makeWriter(psm: BluetoothL2CAPPSM) -> L2CAPWriter {
        let writer = L2CAPWriter { [weak self] buffer, length, refcon in
            guard let channel = self?.slot(psm) else { return kIOReturnNotOpen }
            return channel.submit(buffer, length: length, refcon: refcon)
        }
        writer.failed = { [weak self, weak writer] in
            guard let self, let writer, writer === controlWriter || writer === interruptWriter else { return }
            invalidate(reason: "PSM \(psm) input failed")
        }
        return writer
    }

    private func finishOpening() {
        guard enabled, control != nil, interrupt != nil, !isReady else { return }
        connecting = false
        timeout?.cancel()
        timeout = nil
        readinessTask?.cancel()
        readinessTask = nil
        awaiting.removeAll()
        isReady = true
        readySince = now()
        bluetoothLog.notice("HID link ready for \(self.address, privacy: .public)")
        neutralize(epoch: epoch)
        changed?()
    }

    private func armTimeout() {
        timeout?.cancel()
        let generation = attempt
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, attempt == generation, connecting, !isReady else { return }
            failAttempt("timed out")
        }
    }

    private func failAttempt(_ reason: String) {
        noteFailure(reason)
        invalidate(reason: reason)
    }

    private func noteFailure(_ reason: String) {
        failures += 1
        bluetoothLog.notice("HID attempt \(self.attempt) failed (\(self.failures)): \(reason, privacy: .public)")
        if failures <= Self.retryDelays.count {
            retryAt = now().addingTimeInterval(Self.retryDelays[failures - 1])
        } else {
            diagnostic?(
                "Bluetooth reconnect paused after repeated failures. On iPhone: Settings > Bluetooth > tap this Mac, or enable control again."
            )
        }
    }

    func l2capChannelClosed(_ channel: IOBluetoothL2CAPChannel!) {
        guard let channel else { return }
        channelClosed(channel)
    }

    func channelClosed(_ channel: any HIDChannel) {
        let identifier = ObjectIdentifier(channel)
        guard seen.removeValue(forKey: identifier) != nil else { return }
        let psm = channel.psm
        if let entry = opening.removeValue(forKey: identifier), slot(psm) !== channel {
            if entry.attempt == attempt, connecting, slot(psm) == nil {
                awaiting.remove(psm)
                failAttempt("PSM \(psm) closed while opening")
            }
            return
        }
        guard slot(psm) != nil else { return }
        // This PSM is already closed. Only the surviving channel needs an explicit teardown.
        if psm == 0x11 {
            controlWriter?.invalidate()
            controlWriter = nil
            control = nil
        } else {
            interruptWriter?.invalidate()
            interruptWriter = nil
            interrupt = nil
        }
        invalidate(reason: "PSM \(psm) closed")
    }

    func invalidate(reason: String = "connection reset") {
        // Backoff is judged when a link ends: a short-lived link counts as a failure, a sustained one clears it.
        let lasted = readySince.map { since in now().timeIntervalSince(since) }
        timeout?.cancel()
        timeout = nil
        readinessTask?.cancel()
        readinessTask = nil
        connectionDevice = nil
        isReady = false
        connecting = false

        readySince = nil
        epoch &+= 1
        awaiting.removeAll()
        controlWriter?.invalidate()
        interruptWriter?.invalidate()
        controlWriter = nil
        interruptWriter = nil
        // Close each PSM once: IOBluetooth closes by (device, PSM), whichever alias wrapper is used.
        var closing: [BluetoothL2CAPPSM: any HIDChannel] = [:]
        for channel in [control, interrupt].compactMap({ channel in channel })
            + opening.values.map({ entry in entry.channel })
        where closing[channel.psm] == nil {
            closing[channel.psm] = channel
        }
        control = nil
        interrupt = nil
        opening.removeAll()
        seen.removeAll()
        retired.removeAll()
        for channel in closing.values { close(channel, reason: reason) }
        if let lasted {
            if lasted < 10 { noteFailure("link dropped \(Int(lasted)) s after connecting") } else { resetBackoff() }
        }
        setupMessage =
            enabled && failures <= Self.retryDelays.count
            ? "Reconnecting Bluetooth input automatically. Keep the iPhone awake and unlocked."
            : "Bluetooth input reconnect is paused. Click Enable control to retry."
        changed?()
    }

    private func close(_ channel: any HIDChannel, reason: String) {
        bluetoothLog.notice(
            "HID closing PSM \(channel.psm) for \(self.address, privacy: .public): \(reason, privacy: .public)")
        channel.shutdown()
    }

    func send(_ report: [UInt8], epoch expected: UInt64, deadline: Date?) async throws {
        guard enabled, isReady, epoch == expected, let writer = interruptWriter else {
            throw KitError(
                "BLUETOOTH_DISCONNECTED", "Bluetooth input disconnected. Inspect a fresh screenshot after reconnecting."
            )
        }
        let lengths: [UInt8: Int] = [1: 10, 2: 8, 3: 4]
        guard report.first == 0xA1, report.count >= 2, lengths[report[1]] == report.count else {
            throw KitError("INVALID_REPORT", "Invalid Bluetooth input report.")
        }
        let remaining = deadline.map { deadline in deadline.timeIntervalSinceNow }
        guard remaining.map({ remaining in remaining > 0 }) ?? true else {
            throw KitError("DEADLINE_EXCEEDED", "Action deadline expired.")
        }
        do { try await writer.write(report, maximumWait: remaining.map { remaining in .seconds(remaining) }) } catch {
            if (error as? KitError)?.code == "BLUETOOTH_TIMEOUT",
                deadline.map({ deadline in deadline <= Date() }) ?? false
            {
                throw KitError(
                    "DEADLINE_EXCEEDED",
                    "Action deadline expired during Bluetooth input. Inspect the phone before retrying.")
            }
            throw error
        }
        guard enabled, isReady, epoch == expected, interruptWriter === writer else {
            throw KitError(
                "CONNECTION_CHANGED",
                "Bluetooth connection changed during input. Inspect a fresh screenshot before retrying.")
        }
    }

    func neutralize(epoch expected: UInt64) {
        guard epoch == expected, let writer = interruptWriter else { return }
        do {
            for report in [
                HIDReports.keyboard(), HIDReports.consumer(), HIDDescriptor.absolutePointer(x: 32766, y: 32766),
            ] {
                guard epoch == expected, interruptWriter === writer else { return }
                try writer.enqueue(report)
            }
        } catch {
            if epoch == expected { invalidate(reason: "release reports failed") }
        }
    }

    func l2capChannelWriteComplete(
        _ channel: IOBluetoothL2CAPChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn
    ) {
        guard let refcon else { return }
        writeCompleted(UInt(bitPattern: refcon), status: error)
    }

    /// Write tokens are unique across writers, so either writer may own the completion.
    func writeCompleted(_ identifier: UInt, status: IOReturn) {
        controlWriter?.complete(identifier: identifier, status: status)
        interruptWriter?.complete(identifier: identifier, status: status)
    }

    func l2capChannelData(
        _ channel: IOBluetoothL2CAPChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int
    ) {
        guard let channel, let dataPointer, dataLength > 0, dataLength <= 512 else { return }
        received(Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength)), on: channel)
    }

    /// Control requests may arrive through any wrapper of the control PSM: wrappers share CoreBluetooth's streams.
    func received(_ request: [UInt8], on channel: any HIDChannel) {
        guard channel.psm == 0x11, seen[ObjectIdentifier(channel)] != nil, control != nil else { return }
        handleControl(request)
    }

    private func handleControl(_ request: [UInt8]) {
        guard let writer = controlWriter, !request.isEmpty else { return }
        let expected = epoch
        let header = request[0]
        let reply: [UInt8]
        switch header >> 4 {
        case 1:
            if header & 0x0F == 5 {
                enabled = false
                invalidate(reason: "phone sent virtual cable unplug")
            } else if header & 0x0F == 3 {
                neutralize(epoch: epoch)
                guard epoch == expected, controlWriter === writer else { return }
                isReady = false
                epoch &+= 1
                changed?()
            } else if header & 0x0F == 4 {
                finishOpening()
            }
            return
        case 4:
            let id: UInt8 = request.count > 1 ? request[1] : 1
            switch id {
            case 1: reply = HIDReports.keyboard()
            case 2: reply = HIDDescriptor.absolutePointer(x: 32766, y: 32766)
            case 3: reply = HIDReports.consumer()
            default: reply = [0x02]
            }
        case 6: reply = [0xA0, 0x01]
        case 8: reply = [0xA0, 0x00]
        case 7: reply = header & 0x01 == 1 ? [0x00] : [0x03]
        case 5, 9: reply = [0x00]
        default: reply = [0x03]
        }
        do { try writer.enqueue(reply) } catch {
            if epoch == expected, controlWriter === writer { invalidate(reason: "control reply failed") }
        }
    }
}
