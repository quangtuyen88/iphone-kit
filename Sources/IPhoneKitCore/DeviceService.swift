import Foundation
import IOKit
import IOKit.usb

struct USBPhone: Sendable, Equatable, Codable {
    let id: String
    let name: String
    let model: String
    let systemVersion: String
    let bluetoothAddress: String?
    let trusted: Bool
    let assistiveTouch: Bool?
    let available: Bool
    /// Why a connected phone is not trusted; nil while trusted or while it cannot be told yet.
    var trustProblem: TrustProblem? = nil
    /// The MobileDevice code behind `trustProblem`.
    var trustCode: Int32? = nil

    func settingAvailable(_ value: Bool) -> USBPhone {
        USBPhone(id: id, name: name, model: model, systemVersion: systemVersion, bluetoothAddress: bluetoothAddress,
                 trusted: trusted, assistiveTouch: assistiveTouch, available: value, trustProblem: trustProblem, trustCode: trustCode)
    }
}

enum USBPhysicalPresence {
    static func normalize(_ value: String) -> String {
        value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined().uppercased()
    }
    static func connectedSerials() -> Set<String>? {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(kIOUSBHostDeviceClassName),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var serials: Set<String> = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let vendor = IORegistryEntryCreateCFProperty(service, kUSBVendorID as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            guard vendor?.intValue == 0x05AC,
                  let serial = IORegistryEntryCreateCFProperty(service, kUSBSerialNumberString as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
            serials.insert(normalize(serial))
        }
        return serials
    }
    static func reconciled(known: [String: USBPhone], live: [String: USBPhone], physical: Set<String>?) -> [String: USBPhone] {
        var result = known
        for (id, phone) in live { result[id] = phone.settingAvailable(true) }
        guard let physical else { return result }
        for (id, phone) in result where live[id] == nil {
            if physical.contains(normalize(id)) { result[id] = phone.settingAvailable(false) }
            else { result.removeValue(forKey: id) }
        }
        return result
    }
}

private typealias AMCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
private typealias AMSubscribe = @convention(c) (AMCallback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
private typealias AMSubscribeWithOptions = @convention(c) (AMCallback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>, CFDictionary) -> Int32
private typealias AMInt = @convention(c) (UnsafeMutableRawPointer) -> Int32
private typealias AMVoid = @convention(c) (UnsafeMutableRawPointer) -> Void
private typealias AMIdentifier = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>?
private typealias AMValue = @convention(c) (UnsafeMutableRawPointer, CFString?, CFString) -> Unmanaged<AnyObject>?
private typealias AMSetValue = @convention(c) (UnsafeMutableRawPointer, CFString?, CFString, CFTypeRef) -> Int32
private typealias AMPairWithOptions = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32

/// Where a lockdown session failed, with MobileDevice's code.
private struct LockdownFailure: Error, LocalizedError {
    enum Stage { case connect, validate, start }
    let stage: Stage
    let code: Int32
    var needsTrust: Bool { stage != .connect && LockdownCode.needsTrust(code) }
    var errorDescription: String? {
        "The iPhone did not open a USB session (\(LockdownCode.hex(code))). Unlock it, or unplug and reconnect it."
    }
}

/// All MobileDevice pointers and blocking lockdown calls stay on one thread with a CFRunLoop.
/// The condition protects publication of that run loop; clients only receive Sendable value snapshots.
///
/// Discovery and lockdown use usbmuxd only — the Finder path, which needs no Developer Mode. MobileDevice's
/// RemoteXPC feed is deliberately not used: every session on it rides CoreDevice developer tunnels.
final class DeviceService: @unchecked Sendable {
    private let ready = NSCondition()
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var stopped = false
    private var handle: UnsafeMutableRawPointer?
    private var subscriptions: [UnsafeMutableRawPointer] = []
    private var devices: [String: UnsafeMutableRawPointer] = [:]
    private var trust: [String: TrustWorkflow] = [:]
    private var loggedTrust: [String: String] = [:]
    private var phones: [String: USBPhone] = [:]
    private var remembered: [String: USBPhone] = [:]
    private var originals: [String: Bool] = [:]
    private var sessionChanges: Set<String> = []
    private let journalURL: URL
    private let knownURL: URL
    private let updated: @Sendable ([USBPhone]) -> Void
    private let diagnostic: @Sendable (String) -> Void

    init(updated: @escaping @Sendable ([USBPhone]) -> Void, diagnostic: @escaping @Sendable (String) -> Void) throws {
        self.updated = updated
        self.diagnostic = diagnostic
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("iPhoneKit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        journalURL = directory.appendingPathComponent("accessibility-journal.json")
        knownURL = directory.appendingPathComponent("known-phones.json")
        if let data = try? Data(contentsOf: journalURL) { originals = (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:] }
        if let data = try? Data(contentsOf: knownURL), let cached = try? JSONDecoder().decode([String: USBPhone].self, from: data) {
            remembered = cached.mapValues { $0.settingAvailable(false) }
            phones = USBPhysicalPresence.reconciled(known: remembered, live: [:], physical: USBPhysicalPresence.connectedSerials())
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let worker = Thread { [self] in
                ready.lock()
                runLoop = CFRunLoopGetCurrent()
                ready.broadcast()
                ready.unlock()
                do {
                    try subscribe()
                    continuation.resume()
                    CFRunLoopRun()
                } catch {
                    continuation.resume(throwing: error)
                    diagnostic("USB discovery unavailable: \(error.localizedDescription)")
                }
                ready.lock()
                stopped = true
                ready.unlock()
            }
            worker.name = "iPhoneKit USB"
            thread = worker
            worker.start()
        }
    }

    @discardableResult
    private func perform(_ work: @escaping @Sendable () -> Void) -> Bool {
        ready.lock()
        let loop = runLoop
        let unavailable = stopped
        ready.unlock()
        guard let loop, !unavailable else { return false }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue as CFString, work)
        CFRunLoopWakeUp(loop)
        return true
    }

    func refresh() {
        perform { [self] in rebuild() }
    }

    /// Starts or restarts the Trust workflow from an explicit request; the first step observes before pairing.
    func requestTrust(phoneID: String) {
        perform { [self] in
            guard devices[phoneID] != nil else { return }
            restartTrust(phoneID)
            rebuild()
        }
    }

    /// Turns on AssistiveTouch, first asking the phone to trust this Mac if it does not. Returns the phone as read
    /// afterwards, so callers need not wait for the asynchronous `updated` snapshot.
    func enableControl(phoneID: String) async throws -> USBPhone? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<USBPhone?, any Error>) in
            let scheduled = perform { [self] in
                do {
                    guard let device = devices[phoneID] else {
                        throw KitError("PHONE_OFFLINE", "Connect the iPhone by USB and unlock it.")
                    }
                    do { try enableAssistiveTouch(device, phoneID: phoneID) }
                    catch let failure as LockdownFailure where failure.needsTrust {
                        restartTrust(phoneID)
                        rebuild()
                        guard let phone = phones[phoneID], phone.trusted, let device = devices[phoneID] else {
                            let phone = phones[phoneID]
                            throw KitError("TRUST_REQUIRED", phone?.trustProblem?.message(code: phone?.trustCode.map(LockdownCode.hex))
                                ?? TrustProblem.checkingMessage)
                        }
                        try enableAssistiveTouch(device, phoneID: phoneID)
                    }
                    let phone = evaluate(phoneID)
                    if let phone { phones[phoneID] = phone }
                    publish()
                    continuation.resume(returning: phone)
                } catch { continuation.resume(throwing: error) }
            }
            if !scheduled { continuation.resume(throwing: KitError("USB_UNAVAILABLE", "USB discovery is not running.")) }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            let scheduled = perform { [self] in
                restoreConnectedSettings()
                if let unsubscribe: AMInt = symbol("AMDeviceNotificationUnsubscribe") {
                    for subscription in subscriptions { _ = unsubscribe(subscription) }
                }
                subscriptions.removeAll()
                for device in devices.values { release(device) }
                devices.removeAll()
                trust.removeAll()
                loggedTrust.removeAll()
                phones.removeAll()
                publish()
                ready.lock()
                stopped = true
                ready.unlock()
                if let runLoop { CFRunLoopStop(runLoop) }
                continuation.resume()
            }
            if !scheduled { continuation.resume() }
        }
    }

    private func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private func subscribe() throws {
        guard let opened = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW) else {
            throw KitError("UNSUPPORTED_MACOS", "Apple's MobileDevice framework is unavailable on this Mac.")
        }
        handle = opened
        let required = ["AMDeviceNotificationUnsubscribe", "AMDeviceRetain", "AMDeviceRelease",
                        "AMDeviceGetInterfaceType", "AMDeviceCopyDeviceIdentifier", "AMDeviceConnect", "AMDeviceDisconnect",
                        "AMDeviceValidatePairing", "AMDeviceStartSession", "AMDeviceStopSession", "AMDeviceCopyValue", "AMDeviceSetValue"]
        guard required.allSatisfy({ dlsym(opened, $0) != nil }) else {
            throw KitError("UNSUPPORTED_MACOS", "Required iPhone services changed on this macOS version.")
        }
        let callback: AMCallback = { information, context in
            guard let information, let context else { return }
            let owner = Unmanaged<DeviceService>.fromOpaque(context).takeUnretainedValue()
            let message = information.load(fromByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
            guard let device = information.load(as: UnsafeMutableRawPointer?.self) else {
                if message == 2 { owner.refresh() }
                return
            }
            owner.notification(device, message: message)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var subscription: UnsafeMutableRawPointer?
        var status: Int32 = -1
        if let subscribe: AMSubscribeWithOptions = symbol("AMDeviceNotificationSubscribeWithOptions") {
            let options: [String: Any] = [
                "NotificationOptionSearchForPairedDevices": true,
                "NotificationOptionSearchForPairedDevicesViaDirectConnectionsOnly": true,
                "NotificationOptionSearchForWiFiPairableDevices": false,
                "NotificationOptionEnableUSBMux": true,
            ]
            status = subscribe(callback, 0, 0, context, &subscription, options as NSDictionary)
        }
        if status != 0 || subscription == nil, let subscribe: AMSubscribe = symbol("AMDeviceNotificationSubscribe") {
            status = subscribe(callback, 0, 0, context, &subscription)
        }
        guard status == 0, let subscription else {
            throw KitError("USB_UNAVAILABLE", "Unable to watch USB iPhones (\(status)).")
        }
        subscriptions.append(subscription)
        diagnostic("USB discovery started.")
    }

    private func notification(_ device: UnsafeMutableRawPointer, message: UInt32) {
        guard let identify: AMIdentifier = symbol("AMDeviceCopyDeviceIdentifier"),
              let id = identify(device)?.takeRetainedValue() as String? else { return }
        if message == 1 {
            guard let interface: AMInt = symbol("AMDeviceGetInterfaceType"), interface(device) == 1 else { return }
            if let previous = devices[id], previous != device { release(previous) }
            if devices[id] != device {
                let retain: AMVoid? = symbol("AMDeviceRetain")
                retain?(device)
                devices[id] = device
            }
            if originals[id] != nil, !sessionChanges.contains(id) { restoreSettings(device, id: id) }
            if let phone = evaluate(id) {
                phones[id] = phone
                remember([phone])
            }
        } else if message == 2 {
            guard devices[id] == device else { return }
            release(device)
            devices.removeValue(forKey: id)
            // Re-read the rest: one phone detaching must not mark the others unavailable.
            rebuild()
            return
        } else { return }
        publish()
    }

    /// Re-reads every connected phone, keeping remembered phones that are only physically present.
    private func rebuild() {
        let physical = USBPhysicalPresence.connectedSerials()
        if let physical {
            let stale = devices.filter { !physical.contains(USBPhysicalPresence.normalize($0.key)) }
            for (id, device) in stale {
                release(device)
                devices.removeValue(forKey: id)
            }
            // Only unplugging clears Trust latches; usbmux pausing during sleep keeps Don't Trust and the window.
            for id in Array(trust.keys) where !physical.contains(USBPhysicalPresence.normalize(id)) { resetTrust(id) }
        }
        var live: [String: USBPhone] = [:]
        for id in devices.keys { if let phone = evaluate(id) { live[id] = phone } }
        remember(live.values)
        let known = phones.merging(remembered) { current, _ in current }
        phones = USBPhysicalPresence.reconciled(known: known, live: live, physical: physical)
        publish()
    }

    private func release(_ device: UnsafeMutableRawPointer) {
        let release: AMVoid? = symbol("AMDeviceRelease")
        release?(device)
    }

    private func publish() { updated(phones.values.sorted { $0.id < $1.id }) }

    /// Reads one phone. A session refused for trust reasons feeds the Trust workflow; nil means unreachable for now.
    private func evaluate(_ id: String) -> USBPhone? {
        guard let device = devices[id] else { return nil }
        switch probe(device, id: id) {
        case .success(let phone):
            if trust[id] != nil { diagnostic("\(phone.name) trusts this Mac.") }
            resetTrust(id)
            return phone
        case .failure(let failure) where failure.needsTrust:
            return pairIfDue(device, id: id, refusal: failure.code)
        case .failure:
            // Keep a running Trust workflow on screen through a transient connect failure.
            return trust[id].map { untrusted(id, flow: $0) }
        }
    }

    /// Advances the Trust workflow after a session was refused, sending at most one pairing request.
    private func pairIfDue(_ device: UnsafeMutableRawPointer, id: String, refusal: Int32) -> USBPhone {
        var flow = trust[id] ?? TrustWorkflow()
        let now = Date()
        if refusal == LockdownCode.passcodeProtected || refusal == LockdownCode.deviceLocked {
            flow.observeLocked(refusal, now: now)
        } else if flow.attemptDue(now: now) {
            if let pair: AMPairWithOptions = symbol("AMDevicePairWithOptions") {
                let code = requestPairing(device, pair)
                flow.record(code, now: now)
                if code == 0 {
                    switch probe(device, id: id) {
                    case .success(let phone):
                        diagnostic("\(phone.name) now trusts this Mac.")
                        resetTrust(id)
                        return phone
                    case .failure(let failure) where failure.stage != .connect:
                        flow.recordRefusalAfterPairing(failure.code, now: now)
                    case .failure:
                        break
                    }
                }
            } else {
                flow.markUnavailable()
            }
        }
        trust[id] = flow
        let phone = untrusted(id, flow: flow)
        let key = "\(flow.problem?.rawValue ?? "checking")/\(flow.lastCode)"
        if loggedTrust[id] != key {
            loggedTrust[id] = key
            let detail = flow.lastCode == 0 ? "" : " [\(LockdownCode.hex(flow.lastCode))]"
            diagnostic("\(phone.name): \(flow.problem?.message() ?? TrustProblem.checkingMessage)\(detail)")
        }
        return phone
    }

    /// Asks lockdownd to pair. On an unlocked phone this shows "Trust This Computer?". `ForceLegacy` keeps pairing on
    /// lockdownd — what usbmuxd itself does on attach — instead of CoreDevice RemotePairing.
    private func requestPairing(_ device: UnsafeMutableRawPointer, _ pair: AMPairWithOptions) -> Int32 {
        guard let connect: AMInt = symbol("AMDeviceConnect"), let disconnect: AMInt = symbol("AMDeviceDisconnect") else { return -1 }
        let connected = connect(device)
        guard connected == 0 else { return connected }
        defer { _ = disconnect(device) }
        return pair(device, ["ExtendedPairingErrors": true, "ForceLegacy": true] as NSDictionary)
    }

    private func untrusted(_ id: String, flow: TrustWorkflow) -> USBPhone {
        let known = remembered[id] ?? phones[id]
        return USBPhone(id: id, name: known?.name ?? "iPhone", model: known?.model ?? "iPhone",
                        systemVersion: known?.systemVersion ?? "", bluetoothAddress: known?.bluetoothAddress,
                        trusted: false, assistiveTouch: nil, available: true,
                        trustProblem: flow.problem, trustCode: flow.lastCode == 0 ? nil : flow.lastCode)
    }

    private func restartTrust(_ id: String) {
        trust[id] = .restarted(now: Date())
        loggedTrust[id] = nil
    }

    private func resetTrust(_ id: String) {
        trust[id] = nil
        loggedTrust[id] = nil
    }

    private func probe(_ device: UnsafeMutableRawPointer, id: String) -> Result<USBPhone, LockdownFailure> {
        do {
            return .success(try session(device) {
                USBPhone(id: id, name: value(device, key: "DeviceName") as? String ?? "iPhone",
                         model: value(device, key: "ProductType") as? String ?? "iPhone",
                         systemVersion: value(device, key: "ProductVersion") as? String ?? "",
                         bluetoothAddress: value(device, key: "BluetoothAddress") as? String,
                         trusted: true,
                         assistiveTouch: (value(device, domain: "com.apple.Accessibility", key: "AssistiveTouchEnabledByiTunes") as? NSNumber)?.boolValue,
                         available: true)
            })
        } catch let failure as LockdownFailure {
            return .failure(failure)
        } catch {
            return .failure(LockdownFailure(stage: .connect, code: -1))
        }
    }

    private func session<T>(_ device: UnsafeMutableRawPointer, _ body: () throws -> T) throws -> T {
        guard let connect: AMInt = symbol("AMDeviceConnect"), let disconnect: AMInt = symbol("AMDeviceDisconnect"),
              let validate: AMInt = symbol("AMDeviceValidatePairing"), let start: AMInt = symbol("AMDeviceStartSession"),
              let stop: AMInt = symbol("AMDeviceStopSession") else {
            throw KitError("UNSUPPORTED_MACOS", "Required iPhone pairing services are unavailable.")
        }
        let connected = connect(device)
        guard connected == 0 else { throw LockdownFailure(stage: .connect, code: connected) }
        defer { _ = disconnect(device) }
        let validated = validate(device)
        guard validated == 0 else { throw LockdownFailure(stage: .validate, code: validated) }
        let started = start(device)
        guard started == 0 else { throw LockdownFailure(stage: .start, code: started) }
        defer { _ = stop(device) }
        return try body()
    }

    private func value(_ device: UnsafeMutableRawPointer, domain: String? = nil, key: String) -> AnyObject? {
        let copy: AMValue? = symbol("AMDeviceCopyValue")
        return copy?(device, domain.map { $0 as CFString }, key as CFString)?.takeRetainedValue()
    }

    private func enableAssistiveTouch(_ device: UnsafeMutableRawPointer, phoneID: String) throws {
        try session(device) {
            guard let current = value(device, domain: "com.apple.Accessibility", key: "AssistiveTouchEnabledByiTunes") as? NSNumber else {
                throw KitError("SETTING_UNAVAILABLE", "Cannot read AssistiveTouch. Enable it manually in Settings > Accessibility > Touch.")
            }
            guard !current.boolValue else { return }
            originals = try AccessibilityJournal.recording(phoneID: phoneID, original: false, values: originals) { values in
                try persistJournal(values)
            }
            try setAssistiveTouch(device, enabled: true)
            sessionChanges.insert(phoneID)
        }
    }

    private func setAssistiveTouch(_ device: UnsafeMutableRawPointer, enabled: Bool) throws {
        guard let set: AMSetValue = symbol("AMDeviceSetValue") else { throw KitError("SETTING_UNAVAILABLE", "AssistiveTouch setup is unavailable.") }
        let status = set(device, "com.apple.Accessibility" as CFString, "AssistiveTouchEnabledByiTunes" as CFString,
                         enabled ? kCFBooleanTrue : kCFBooleanFalse)
        guard status == 0, (value(device, domain: "com.apple.Accessibility", key: "AssistiveTouchEnabledByiTunes") as? NSNumber)?.boolValue == enabled else {
            throw KitError("SETTING_FAILED", "AssistiveTouch did not accept the change. Enable it manually and retry.")
        }
    }

    private func saveJournal() throws { try persistJournal(originals) }

    private func persistJournal(_ values: [String: Bool]) throws {
        try JSONEncoder().encode(values).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    private func restoreSettings(_ device: UnsafeMutableRawPointer, id: String) {
        guard let original = originals[id] else { return }
        do {
            try session(device) {
                let current = (value(device, domain: "com.apple.Accessibility", key: "AssistiveTouchEnabledByiTunes") as? NSNumber)?.boolValue
                if current == true { try setAssistiveTouch(device, enabled: original) }
                guard current != nil else { throw KitError("SETTING_UNAVAILABLE", "Cannot read prior accessibility settings.") }
            }
            originals.removeValue(forKey: id)
            sessionChanges.remove(id)
            try saveJournal()
            diagnostic("Restored prior AssistiveTouch setting.")
        } catch { diagnostic("AssistiveTouch restoration pending: reconnect and unlock the phone.") }
    }

    private func restoreConnectedSettings() {
        for (id, device) in devices { restoreSettings(device, id: id) }
    }

    private func remember<S: Sequence>(_ values: S) where S.Element == USBPhone {
        var changed = false
        for phone in values where phone.trusted && phone.bluetoothAddress != nil {
            let cached = phone.settingAvailable(false)
            if remembered[phone.id] != cached { remembered[phone.id] = cached; changed = true }
        }
        guard changed, let data = try? JSONEncoder().encode(remembered) else { return }
        do {
            try data.write(to: knownURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownURL.path)
        } catch { diagnostic("Could not persist known-phone metadata: \(error.localizedDescription)") }
    }
}
