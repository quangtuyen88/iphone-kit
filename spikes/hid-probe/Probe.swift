// HIDProbe — go/no-go spike for the three platform pieces an iPhone-driving Mac app needs:
//   1. USB control plane   (private MobileDevice.framework, dlopen'd)
//   2. Screen capture      (CoreMediaIO "screen capture devices" -> AVCaptureDevice .external)
//   3. Input               (Mac as Bluetooth HID device: BLE HOGP via CoreBluetooth, Classic HIDP via IOBluetooth)
// Modes: auto (non-interactive checks), pair (Classic HID pairing + pointer test), desc (BLE 0x2908 descriptor test)
import AppKit
import AVFoundation
import CoreBluetooth
import CoreMediaIO
import IOBluetooth

// MARK: - Logging

let logPath = "/tmp/iphonekit-probe.log"
let isoFormatter = ISO8601DateFormatter()

func log(_ message: String) {
    let line = "\(isoFormatter.string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
    }
}

func hex(_ value: some BinaryInteger) -> String { "0x" + String(value, radix: 16, uppercase: true) }

// MARK: - HID report descriptor: report 1 keyboard, report 2 absolute pointer, report 3 consumer

enum HIDDescriptor {
    static let bytes: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
        0xC0,
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02, 0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x16, 0x00, 0x00, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
        0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0xC0, 0xC0,
        0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x03,
        0x15, 0x00, 0x26, 0xFF, 0x03, 0x19, 0x00, 0x2A, 0xFF, 0x03, 0x75, 0x10, 0x95, 0x01, 0x81, 0x00,
        0xC0,
    ]

    static func absolutePointer(x: Int, y: Int, buttons: UInt8 = 0) -> [UInt8] {
        let cx = UInt16(clamping: max(0, min(32767, x))), cy = UInt16(clamping: max(0, min(32767, y)))
        return [0xA1, 0x02, buttons, UInt8(cx & 0xFF), UInt8(cx >> 8), UInt8(cy & 0xFF), UInt8(cy >> 8), 0x00]
    }
}

/// US-ANSI HID usages for printable ASCII.
enum Keyboard {
    static func usage(for character: Character) -> (UInt8, Bool)? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x61...0x7A: return (0x04 + ascii - 0x61, false)
        case 0x41...0x5A: return (0x04 + ascii - 0x41, true)
        case 0x31...0x39: return (0x1E + ascii - 0x31, false)
        case 0x30: return (0x27, false)
        case 0x20: return (0x2C, false)
        case 0x0A: return (0x28, false)
        default: break
        }
        let table: [Character: (UInt8, Bool)] = [
            "!": (0x1E, true), "@": (0x1F, true), "#": (0x20, true), "$": (0x21, true), "%": (0x22, true),
            "^": (0x23, true), "&": (0x24, true), "*": (0x25, true), "(": (0x26, true), ")": (0x27, true),
            "-": (0x2D, false), "_": (0x2D, true), "=": (0x2E, false), "+": (0x2E, true), "[": (0x2F, false),
            "{": (0x2F, true), "]": (0x30, false), "}": (0x30, true), "\\": (0x31, false), "|": (0x31, true),
            ";": (0x33, false), ":": (0x33, true), "'": (0x34, false), "\"": (0x34, true), "`": (0x35, false),
            "~": (0x35, true), ",": (0x36, false), "<": (0x36, true), ".": (0x37, false), ">": (0x37, true),
            "/": (0x38, false), "?": (0x38, true),
        ]
        return table[character]
    }
}

// MARK: - SDP record for a Bluetooth Classic HID device (keys are hex attribute IDs)

enum SDP {
    static func uint8(_ value: Int) -> NSDictionary { ["DataElementType": 1, "DataElementSize": 1, "DataElementValue": value] }
    static func uint16(_ value: Int) -> NSDictionary { ["DataElementType": 1, "DataElementSize": 2, "DataElementValue": value] }
    static func bool(_ value: Bool) -> NSDictionary { ["DataElementType": 5, "DataElementSize": 1, "DataElementValue": value] }
    static func octets(_ bytes: [UInt8]) -> NSDictionary { ["DataElementType": 4, "DataElementSize": bytes.count, "DataElementValue": Data(bytes)] }
    static func uuid(_ value: UInt16) -> IOBluetoothSDPUUID { IOBluetoothSDPUUID(uuid16: value) }

    static func hidRecord(name: String) -> [String: Any] {
        let l2cap = uuid(0x0100), hidp = uuid(0x0011), hidClass = uuid(0x1124)
        return [
            "0001": [hidClass],
            "0004": [[l2cap, uint16(0x11)], [hidp]],
            "0005": [uuid(0x1002)],
            "0006": [uint16(0x656E), uint16(0x006A), uint16(0x0100)],
            "0009": [[hidClass, uint16(0x0101)]],
            "000D": [[[l2cap, uint16(0x13)], [hidp]]],
            "0100": name,
            "0101": "Keyboard and absolute pointer",
            "0102": "iPhoneKit",
            "0201": uint16(0x0111),
            "0202": uint8(0xC0),
            "0203": uint8(0x21),
            "0204": bool(true),
            "0205": bool(true),
            "0206": [[uint8(0x22), octets(HIDDescriptor.bytes)]],
            "0207": [[uint16(0x0409), uint16(0x0100)]],
            "0209": bool(true),
            "020A": bool(true),
            "020C": uint16(0x0C80),
            "020D": bool(true),
            "020E": bool(false),
        ]
    }
}

// MARK: - 1. MobileDevice (USB lockdown)

// C layout: struct { AMDeviceRef device; unsigned int message; AMDeviceNotificationRef subscription; }
typealias AMCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
typealias AMSubscribe = @convention(c) (AMCallback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
typealias AMDeviceIntFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
typealias AMCopyIdentifier = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>?
typealias AMCopyValue = @convention(c) (UnsafeMutableRawPointer, CFString?, CFString) -> Unmanaged<AnyObject>?
typealias AMSetValue = @convention(c) (UnsafeMutableRawPointer, CFString?, CFString, CFTypeRef) -> Int32

enum MobileDevice {
    static var handle: UnsafeMutableRawPointer?
    static var subscription: UnsafeMutableRawPointer?
    static var enableAssistiveTouch = false
    static var touchedDevice: UnsafeMutableRawPointer?
    static var originalAssistiveTouch: Bool?

    /// Runs body inside a paired lockdown session (connect -> validate pairing -> start session).
    static func withSession<T>(_ device: UnsafeMutableRawPointer, _ body: () -> T) -> T? {
        guard let connect = symbol("AMDeviceConnect", as: AMDeviceIntFn.self),
              let disconnect = symbol("AMDeviceDisconnect", as: AMDeviceIntFn.self),
              let isPaired = symbol("AMDeviceIsPaired", as: AMDeviceIntFn.self),
              let validate = symbol("AMDeviceValidatePairing", as: AMDeviceIntFn.self),
              let startSession = symbol("AMDeviceStartSession", as: AMDeviceIntFn.self),
              let stopSession = symbol("AMDeviceStopSession", as: AMDeviceIntFn.self) else { return nil }
        let connected = connect(device)
        guard connected == 0 else { log("MobileDevice: connect rc=\(connected)"); return nil }
        defer { _ = disconnect(device) }
        let paired = isPaired(device), validated = validate(device), session = startSession(device)
        guard paired == 1, validated == 0, session == 0 else {
            log("MobileDevice: session unavailable paired=\(paired) validate=\(hex(UInt32(bitPattern: validated))) start=\(hex(UInt32(bitPattern: session)))")
            return nil
        }
        defer { _ = stopSession(device) }
        return body()
    }

    static func assistiveTouch(_ device: UnsafeMutableRawPointer) -> Bool? {
        withSession(device) {
            symbol("AMDeviceCopyValue", as: AMCopyValue.self)?(device, "com.apple.Accessibility" as CFString, "AssistiveTouchEnabledByiTunes" as CFString)?
                .takeRetainedValue() as? Bool
        } ?? nil
    }

    static func setAssistiveTouch(_ device: UnsafeMutableRawPointer, _ enabled: Bool) {
        let status = withSession(device) {
            symbol("AMDeviceSetValue", as: AMSetValue.self)?(device, "com.apple.Accessibility" as CFString, "AssistiveTouchEnabledByiTunes" as CFString, (enabled ? kCFBooleanTrue : kCFBooleanFalse)!)
        } ?? nil
        log("MobileDevice: set AssistiveTouchEnabledByiTunes=\(enabled) rc=\(status.map { hex(UInt32(bitPattern: $0)) } ?? "no session") now=\(assistiveTouch(device).map(String.init) ?? "?")")
    }

    static func restore() {
        guard let device = touchedDevice, let original = originalAssistiveTouch, original == false else { return }
        setAssistiveTouch(device, original)
    }

    static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    static func probe() {
        let path = "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
        guard let opened = dlopen(path, RTLD_NOW) else {
            log("MobileDevice: dlopen FAILED \(String(cString: dlerror()))")
            return
        }
        handle = opened
        let required = [
            "AMDeviceNotificationSubscribe", "AMDeviceConnect", "AMDeviceDisconnect", "AMDeviceIsPaired",
            "AMDevicePair", "AMDeviceValidatePairing", "AMDeviceStartSession", "AMDeviceStopSession",
            "AMDeviceCopyValue", "AMDeviceSetValue", "AMDeviceSecureStartService", "AMDeviceLookupApplications",
            "AMDeviceGetInterfaceType", "AMDeviceCopyDeviceIdentifier",
        ]
        let missing = required.filter { dlsym(opened, $0) == nil }
        log("MobileDevice: \(required.count - missing.count)/\(required.count) symbols resolved\(missing.isEmpty ? "" : " missing=\(missing)")")
        guard let subscribe = symbol("AMDeviceNotificationSubscribe", as: AMSubscribe.self) else { return }
        let callback: AMCallback = { info, _ in
            guard let info, info.load(fromByteOffset: 8, as: UInt32.self) == 1,
                  let device = info.load(as: UnsafeMutableRawPointer?.self) else { return }
            let udid = MobileDevice.symbol("AMDeviceCopyDeviceIdentifier", as: AMCopyIdentifier.self)?(device)?.takeRetainedValue() as String? ?? "?"
            let interface = MobileDevice.symbol("AMDeviceGetInterfaceType", as: AMDeviceIntFn.self)?(device) ?? -1
            var name = "?"
            if let connect = MobileDevice.symbol("AMDeviceConnect", as: AMDeviceIntFn.self),
               let disconnect = MobileDevice.symbol("AMDeviceDisconnect", as: AMDeviceIntFn.self),
               let copyValue = MobileDevice.symbol("AMDeviceCopyValue", as: AMCopyValue.self),
               connect(device) == 0 {
                name = (copyValue(device, nil, "DeviceName" as CFString)?.takeRetainedValue() as? String) ?? "?"
                _ = disconnect(device)
            }
            let kind = interface == 1 ? "USB" : interface == 2 ? "network" : "type\(interface)"
            log("MobileDevice: device attached udid=\(udid) interface=\(kind) name=\(name)")
            guard interface == 1 else { return }
            let current = MobileDevice.assistiveTouch(device)
            log("MobileDevice: AssistiveTouchEnabledByiTunes=\(current.map(String.init) ?? "unreadable")")
            if MobileDevice.enableAssistiveTouch, MobileDevice.touchedDevice == nil, current != true {
                _ = MobileDevice.symbol("AMDeviceRetain", as: AMDeviceIntFn.self)?(device)
                MobileDevice.touchedDevice = device
                MobileDevice.originalAssistiveTouch = current ?? false
                MobileDevice.setAssistiveTouch(device, true)
            }
        }
        var subscriptionOut: UnsafeMutableRawPointer?
        let status = subscribe(callback, 0, 0, nil, &subscriptionOut)
        subscription = subscriptionOut
        log("MobileDevice: AMDeviceNotificationSubscribe rc=\(status)")
    }
}

// MARK: - 2. Screen capture (CoreMediaIO)

func probeScreenCapture() {
    var address = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var allow: UInt32 = 1
    let status = CMIOObjectSetPropertyData(
        CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    log("CMIO: allow screen-capture devices rc=\(status) cameraAuth=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: nil, position: .unspecified)
        let devices = discovery.devices.map { "\($0.localizedName) model=\($0.modelID) uniqueID=\($0.uniqueID) muxed=\($0.hasMediaType(.muxed))" }
        log("CMIO: external capture devices=\(devices)")
    }
}

/// Grabs iPhone frames from the CMIO capture device; writes /tmp/iphone-screen.png every `every` seconds.
final class ScreenSnapper: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "snap")
    private let every: TimeInterval
    private var lastWrite = Date.distantPast
    private var frames = 0

    init(every: TimeInterval) {
        self.every = every
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            log("Snap: camera access granted=\(granted)")
            guard granted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.configure(attempt: 0) }
        }
    }

    private func configure(attempt: Int) {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: nil, position: .unspecified).devices
        guard let device = devices.first(where: { $0.hasMediaType(.muxed) }) else {
            if attempt < 10 { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.configure(attempt: attempt + 1) } }
            else { log("Snap: no iPhone capture device") }
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            session.startRunning()
            log("Snap: capturing \(device.localizedName) running=\(session.isRunning)")
        } catch {
            log("Snap: input error \(error.localizedDescription)")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        guard frames > 5, Date().timeIntervalSince(lastWrite) >= every,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastWrite = Date()
        let rep = NSBitmapImageRep(ciImage: CIImage(cvPixelBuffer: pixelBuffer))
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: "/tmp/iphone-screen.png"))
        if frames < 400 || frames % 300 == 0 {
            log("Snap: frame \(frames) \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) -> /tmp/iphone-screen.png")
        }
    }
}

// MARK: - 3a. BLE HID-over-GATT via public CoreBluetooth

final class BLEProbe: NSObject, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager?
    private let testReportReference: Bool

    init(testReportReference: Bool) {
        self.testReportReference = testReportReference
    }

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        log("BLE: state=\(peripheral.state.rawValue) authorization=\(CBManager.authorization.rawValue)")
        guard peripheral.state == .poweredOn else { return }
        let report = CBMutableCharacteristic(type: CBUUID(string: "2A4D"), properties: [.read, .notify], value: nil, permissions: [.readable])
        if testReportReference {
            log("BLE: creating Report Reference 0x2908 descriptor (a crash right after this line = rejected)")
            report.descriptors = [CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([0x02, 0x01]))]
            log("BLE: Report Reference 0x2908 descriptor accepted")
        }
        let service = CBMutableService(type: CBUUID(string: "1812"), primary: true)
        service.characteristics = [
            CBMutableCharacteristic(type: CBUUID(string: "2A4A"), properties: [.read], value: Data([0x11, 0x01, 0x00, 0x02]), permissions: [.readable]),
            CBMutableCharacteristic(type: CBUUID(string: "2A4B"), properties: [.read], value: Data(HIDDescriptor.bytes), permissions: [.readable]),
            CBMutableCharacteristic(type: CBUUID(string: "2A4C"), properties: [.writeWithoutResponse], value: nil, permissions: [.writeable]),
            CBMutableCharacteristic(type: CBUUID(string: "2A4E"), properties: [.read, .writeWithoutResponse], value: nil, permissions: [.readable, .writeable]),
            report,
        ]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error as NSError? {
            log("BLE: add HID service 0x1812 FAILED domain=\(error.domain) code=\(error.code) \(error.localizedDescription)")
            return
        }
        log("BLE: add HID service 0x1812 OK")
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: "iPhoneKit",
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")],
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        log("BLE: advertising \(error.map { "FAILED \($0.localizedDescription)" } ?? "OK")")
    }
}

// MARK: - 3b. Classic HID (HIDP over L2CAP) via IOBluetooth

typealias GetDiscoverable = @convention(c) () -> Int32
typealias SetDiscoverable = @convention(c) (Int32) -> Void
typealias BoolSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool

/// bluetoothd only stays discoverable while a client holds a "discoverable controller".
/// On macOS 12+ IOBluetooth is a shim over CoreBluetooth's private CBClassicManager, which exposes one.
enum ClassicVisibility {
    static var manager: NSObject?

    static func classicManager() -> NSObject? {
        if let manager { return manager }
        guard let cls = NSClassFromString("CBClassicManager") as? NSObject.Type else { return nil }
        let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
        let initSel = NSSelectorFromString("initWithQueue:options:")
        manager = allocated?.perform(initSel, with: DispatchQueue.main, with: nil)?.takeUnretainedValue() as? NSObject
        return manager
    }

    static func set(_ selector: String, _ value: Bool) -> Bool {
        guard let target = classicManager() else { return false }
        let sel = NSSelectorFromString(selector)
        guard target.responds(to: sel) else { return false }
        unsafeBitCast(target.method(for: sel), to: BoolSetter.self)(target, sel, value)
        return true
    }

    static func get(_ selector: String) -> Bool? {
        guard let target = classicManager() else { return nil }
        let sel = NSSelectorFromString(selector)
        guard target.responds(to: sel) else { return nil }
        return unsafeBitCast(target.method(for: sel), to: BoolGetter.self)(target, sel)
    }
}

final class ClassicProbe: NSObject, IOBluetoothL2CAPChannelDelegate {
    private var record: IOBluetoothSDPServiceRecord?
    private var notifications: [IOBluetoothUserNotification] = []
    private var control: IOBluetoothL2CAPChannel?
    private var interrupt: IOBluetoothL2CAPChannel?
    private var connecting = false
    private var connectStarted = Date.distantPast
    private var pendingChannels: [IOBluetoothL2CAPChannel] = []
    private var originalDiscoverable: Int32?
    private var pairTimer: Timer?
    private var connectNote: IOBluetoothUserNotification?
    private let bluetoothHandle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)

    private func fn<T>(_ name: String, _ type: T.Type) -> T? {
        guard let bluetoothHandle, let pointer = dlsym(bluetoothHandle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    func start(pairMode: Bool, targetAddress: String?) {
        if let host = IOBluetoothHostController.default() {
            log("Classic: controller name=\(host.nameAsString() ?? "?") address=\(host.addressAsString() ?? "?") power=\(host.powerState.rawValue) class=\(hex(host.classOfDevice()))")
        } else {
            log("Classic: no default host controller")
        }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        log("Classic: paired=\(paired.map { "\($0.name ?? "?")[\($0.addressString ?? "?")] connected=\($0.isConnected())" })")

        if let published = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: SDP.hidRecord(name: "iPhoneKit HID")) {
            record = published
            var handle: BluetoothSDPServiceRecordHandle = 0
            let handleStatus = published.getHandle(&handle)
            var psm: BluetoothL2CAPPSM = 0
            let psmStatus = published.getL2CAPPSM(&psm)
            let descriptorElement = published.getAttributeDataElement(0x0206)
            log("Classic: SDP HID record published handle=\(hex(handle)) (rc=\(handleStatus)) psm=\(hex(psm)) (rc=\(psmStatus)) attributes=\(published.attributes?.count ?? 0) hidDescriptorList=\(descriptorElement != nil ? "present" : "MISSING")")
        } else {
            log("Classic: SDP HID record publish FAILED (nil)")
        }

        for psm: BluetoothL2CAPPSM in [0x11, 0x13] {
            if let note = IOBluetoothL2CAPChannel.register(
                forChannelOpenNotifications: self, selector: #selector(incomingChannel(_:channel:)),
                withPSM: psm, direction: kIOBluetoothUserNotificationChannelDirectionIncoming) {
                notifications.append(note)
                log("Classic: listening for incoming L2CAP PSM \(hex(psm))")
            } else {
                log("Classic: incoming L2CAP registration FAILED for PSM \(hex(psm))")
            }
        }

        let getDiscoverable = fn("IOBluetoothPreferenceGetDiscoverableState", GetDiscoverable.self)
        let current = getDiscoverable?()
        log("Classic: discoverable=\(current.map(String.init) ?? "unavailable")")
        guard pairMode else { return }

        if let set = fn("IOBluetoothPreferenceSetDiscoverableState", SetDiscoverable.self), let current {
            originalDiscoverable = current
            set(1)
            log("Classic: discoverable -> \(getDiscoverable?() ?? -1)")
        }
        let connectable = ClassicVisibility.set("setBTConnectable:", true)
        let discoverable = ClassicVisibility.set("setBTDiscoverable:", true)
        log("Classic: CBClassicManager setBTConnectable=\(connectable) setBTDiscoverable=\(discoverable)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            log("Classic: CBClassicManager discoverable=\(ClassicVisibility.get("discoverable").map(String.init) ?? "?") connectable=\(ClassicVisibility.get("connectable").map(String.init) ?? "?")")
        }
        presentAsKeyboardAndPointer()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        log("Classic: on the iPhone open Settings > Bluetooth and tap '\(IOBluetoothHostController.default()?.nameAsString() ?? "this Mac")'")
        pairTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.connectIfPaired(targetAddress: targetAddress)
        }
        startCommandChannel()
    }

    private func connectIfPaired(targetAddress: String?) {
        if connecting, Date().timeIntervalSince(connectStarted) > 20 {
            log("Classic: outgoing connect timed out, retrying")
            connecting = false
        }
        guard control == nil, !connecting else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let target = paired.first { device in
            if let targetAddress { return device.addressString?.lowercased() == targetAddress.lowercased() }
            return (device.name ?? "").localizedCaseInsensitiveContains("iphone")
        }
        guard let target else { return }
        connecting = true
        connectStarted = Date()
        var channel: IOBluetoothL2CAPChannel?
        let status = target.openL2CAPChannelAsync(&channel, withPSM: 0x11, delegate: self)
        if let channel { pendingChannels.append(channel) }
        log("Classic: outgoing L2CAP control (0x11) to \(target.name ?? "?")[\(target.addressString ?? "?")] rc=\(status)")
        if status != kIOReturnSuccess { connecting = false }
    }

    /// iOS only lists HID-class devices in Settings > Bluetooth, so temporarily advertise
    /// Class of Device 0x0025C0 (limited discoverable, peripheral, keyboard+pointing combo).
    private func presentAsKeyboardAndPointer() {
        guard let host = IOBluetoothHostController.default() else { return }
        let sel = NSSelectorFromString("setClassOfDevice:forTimeInterval:")
        guard host.responds(to: sel) else {
            log("Classic: setClassOfDevice:forTimeInterval: unavailable")
            return
        }
        typealias SetClass = @convention(c) (AnyObject, Selector, UInt32, Double) -> Int32
        let status = unsafeBitCast(host.method(for: sel), to: SetClass.self)(host, sel, 0x0025C0, duration)
        log("Classic: setClassOfDevice(0x0025C0, \(Int(duration))s) rc=\(hex(UInt32(bitPattern: status))) now=\(hex(host.classOfDevice()))")
    }

    @objc func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        log("Classic: ACL connected \(device.name ?? "?")[\(device.addressString ?? "?")] paired=\(device.isPaired()) class=\(hex(device.classOfDevice))")
    }

    @objc func incomingChannel(_ note: IOBluetoothUserNotification, channel: IOBluetoothL2CAPChannel) {
        log("Classic: INCOMING L2CAP PSM \(hex(channel.psm)) from \(channel.device?.name ?? "?")[\(channel.device?.addressString ?? "?")]")
        channel.setDelegate(self)
        adopt(channel)
    }

    private func adopt(_ channel: IOBluetoothL2CAPChannel) {
        if channel.psm == 0x11 { control = channel }
        if channel.psm == 0x13 { interrupt = channel; runPointerTest() }
    }

    func l2capChannelOpenComplete(_ channel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        log("Classic: L2CAP PSM \(hex(channel.psm)) open complete rc=\(error)")
        guard error == kIOReturnSuccess else { connecting = false; return }
        adopt(channel)
        if channel.psm == 0x11, interrupt == nil, let device = channel.device {
            var next: IOBluetoothL2CAPChannel?
            let status = device.openL2CAPChannelAsync(&next, withPSM: 0x13, delegate: self)
            if let next { pendingChannels.append(next) }
            log("Classic: outgoing L2CAP interrupt (0x13) rc=\(status)")
        }
    }

    func l2capChannelData(_ channel: IOBluetoothL2CAPChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = [UInt8](UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        log("Classic: rx PSM \(hex(channel.psm)) \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        guard channel.psm == 0x11, let header = bytes.first else { return }
        var reply: [UInt8]
        switch header >> 4 {
        case 0x1 where header & 0x0F == 0x05: reply = []   // VIRTUAL_CABLE_UNPLUG
        case 0x4: reply = [0xA1, bytes.count > 1 ? bytes[1] : 0x01] + [UInt8](repeating: 0, count: 8)  // GET_REPORT
        case 0x6: reply = [0xA0, 0x01]                     // GET_PROTOCOL -> report protocol
        case 0x8: reply = [0xA0, 0x00]                     // GET_IDLE
        case 0x5, 0x7, 0x9: reply = [0x00]                 // SET_REPORT / SET_PROTOCOL / SET_IDLE -> HANDSHAKE OK
        default: reply = [0x03]                            // HANDSHAKE ERR_UNSUPPORTED_REQUEST
        }
        guard !reply.isEmpty else { return }
        let status = reply.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
        log("Classic: tx control reply \(reply.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")) rc=\(status)")
    }

    func l2capChannelClosed(_ channel: IOBluetoothL2CAPChannel!) {
        log("Classic: L2CAP PSM \(hex(channel.psm)) closed")
        if channel === control { control = nil }
        if channel === interrupt { interrupt = nil }
        connecting = false
    }

    // MARK: Command channel for the spike: echo "click 585 120" > /tmp/iphonekit-cmd.txt
    private var commandTimer: Timer?
    private var screen = (width: 1170.0, height: 2532.0)
    private var buttons: UInt8 = 0

    func startCommandChannel() {
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            let path = "/tmp/iphonekit-cmd.txt"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(atPath: path)
            var delay = 0.0
            for line in text.split(separator: "\n") {
                delay = self?.schedule(String(line), after: delay) ?? delay
            }
        }
    }

    private func sendKey(usage: UInt8, modifiers: UInt8) -> IOReturn {
        guard let interrupt else { return kIOReturnNotOpen }
        var report: [UInt8] = [0xA1, 0x01, modifiers, 0x00, usage, 0, 0, 0, 0, 0]
        return report.withUnsafeMutableBytes { interrupt.writeSync($0.baseAddress, length: UInt16($0.count)) }
    }

    private func sendConsumer(_ usage: UInt16) -> IOReturn {
        guard let interrupt else { return kIOReturnNotOpen }
        var report: [UInt8] = [0xA1, 0x03, UInt8(usage & 0xFF), UInt8(usage >> 8)]
        return report.withUnsafeMutableBytes { interrupt.writeSync($0.baseAddress, length: UInt16($0.count)) }
    }

    private func sendPointer(x: Double, y: Double) -> IOReturn {
        guard let interrupt else { return kIOReturnNotOpen }
        let hx = Int((x / screen.width * 32767).rounded()), hy = Int((y / screen.height * 32767).rounded())
        var report = HIDDescriptor.absolutePointer(x: hx, y: hy, buttons: buttons)
        return report.withUnsafeMutableBytes { interrupt.writeSync($0.baseAddress, length: UInt16($0.count)) }
    }

    /// Returns the delay after which the next command may start.
    private func schedule(_ line: String, after delay: Double) -> Double {
        let parts = line.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return delay }
        let numbers = parts.dropFirst().compactMap(Double.init)
        let at = { (offset: Double, work: @escaping () -> Void) in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + offset, execute: work)
        }
        switch (verb, numbers.count) {
        case ("screen", 2):
            screen = (numbers[0], numbers[1])
            log("Cmd: screen \(numbers[0])x\(numbers[1])")
            return delay
        case ("move", 2):
            at(0) { log("Cmd: move \(numbers[0]),\(numbers[1]) rc=\(self.sendPointer(x: numbers[0], y: numbers[1]))") }
            return delay + 0.1
        case ("click", 2), ("hold", 3):
            let (x, y) = (numbers[0], numbers[1])
            let holdSeconds = numbers.count == 3 ? numbers[2] / 1000 : 0.08
            at(0) { _ = self.sendPointer(x: x, y: y) }
            at(0.06) { self.buttons = 1; _ = self.sendPointer(x: x, y: y) }
            at(0.06 + holdSeconds) {
                self.buttons = 0
                log("Cmd: \(verb) \(x),\(y) rc=\(self.sendPointer(x: x, y: y))")
            }
            return delay + 0.12 + holdSeconds
        case ("drag", 4):
            let (x0, y0, x1, y1) = (numbers[0], numbers[1], numbers[2], numbers[3])
            let steps = 20
            at(0) { _ = self.sendPointer(x: x0, y: y0) }
            at(0.05) { self.buttons = 1; _ = self.sendPointer(x: x0, y: y0) }
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                at(0.05 + 0.015 * Double(step)) { _ = self.sendPointer(x: x0 + (x1 - x0) * t, y: y0 + (y1 - y0) * t) }
            }
            let end = 0.05 + 0.015 * Double(steps) + 0.05
            at(end) {
                self.buttons = 0
                log("Cmd: drag \(x0),\(y0) -> \(x1),\(y1) rc=\(self.sendPointer(x: x1, y: y1))")
            }
            return delay + end + 0.1
        case ("wait", 1):
            return delay + numbers[0] / 1000
        case ("type", _):
            let text = String(line.dropFirst(5))
            var offset = 0.0
            for character in text {
                guard let (usage, shift) = Keyboard.usage(for: character) else {
                    log("Cmd: type skips unsupported '\(character)'")
                    continue
                }
                at(offset) { _ = self.sendKey(usage: usage, modifiers: shift ? 0x02 : 0) }
                at(offset + 0.03) { _ = self.sendKey(usage: 0, modifiers: 0) }
                offset += 0.06
            }
            at(offset) { log("Cmd: typed \(text.count) chars") }
            return delay + offset + 0.05
        case ("key", _):
            let name = parts.count > 1 ? parts[1] : ""
            let usage: UInt8 = ["enter": 0x28, "escape": 0x29, "backspace": 0x2A, "tab": 0x2B, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52][name] ?? 0
            let modifiers: UInt8 = parts.dropFirst(2).reduce(0) { $0 | (["control": 0x01, "shift": 0x02, "alternate": 0x04, "command": 0x08][$1] ?? 0) }
            at(0) { _ = self.sendKey(usage: usage, modifiers: modifiers) }
            at(0.05) { log("Cmd: key \(name) rc=\(self.sendKey(usage: 0, modifiers: 0))") }
            return delay + 0.1
        case ("home", 0):
            at(0) { _ = self.sendConsumer(0x0223) }
            at(0.05) { log("Cmd: home (AC Home) rc=\(self.sendConsumer(0))") }
            return delay + 0.1
        default:
            log("Cmd: unknown '\(line)'")
            return delay
        }
    }

    private func runPointerTest() {
        guard let interrupt else { return }
        let path: [(Int, Int)] = [(16384, 16384), (4096, 4096), (28672, 4096), (28672, 28672), (4096, 28672), (16384, 16384)]
        for (index, point) in path.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 1.0) {
                var report = HIDDescriptor.absolutePointer(x: point.0, y: point.1)
                let status = report.withUnsafeMutableBytes { interrupt.writeSync($0.baseAddress, length: UInt16($0.count)) }
                log("Classic: pointer -> (\(point.0), \(point.1)) rc=\(status)")
            }
        }
    }

    func stop() {
        pairTimer?.invalidate()
        control?.close()
        interrupt?.close()
        notifications.forEach { $0.unregister() }
        if record?.remove() == kIOReturnSuccess { log("Classic: SDP record removed") }
        connectNote?.unregister()
        if ClassicVisibility.manager != nil {
            _ = ClassicVisibility.set("setBTDiscoverable:", false)
            log("Classic: CBClassicManager discoverable released")
        }
        if let originalDiscoverable, let set = fn("IOBluetoothPreferenceSetDiscoverableState", SetDiscoverable.self) {
            set(originalDiscoverable)
            log("Classic: discoverable restored -> \(originalDiscoverable)")
        }
    }
}

// MARK: - Mac-initiated pairing (IOBluetoothDevicePair)

final class OutgoingPairing: NSObject, IOBluetoothDevicePairDelegate {
    private var pairing: IOBluetoothDevicePair?

    func start(address: String) {
        guard let device = IOBluetoothDevice(addressString: address) else {
            log("PairOut: no device for \(address)")
            return
        }
        pairing = IOBluetoothDevicePair(device: device)
        pairing?.delegate = self
        log("PairOut: pairing with \(device.name ?? "?")[\(address)] rc=\(pairing?.start() ?? -1)")
    }

    func devicePairingStarted(_ sender: Any!) { log("PairOut: started") }
    func devicePairingConnecting(_ sender: Any!) { log("PairOut: connecting") }
    func devicePairingPINCodeRequest(_ sender: Any!) { log("PairOut: PIN code requested") }
    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) { log("PairOut: passkey \(passkey)") }
    func deviceSimplePairingComplete(_ sender: Any!, status: BluetoothHCIEventStatus) { log("PairOut: SSP complete status=\(status)") }
    func devicePairingFinished(_ sender: Any!, error: IOReturn) { log("PairOut: finished rc=\(error)") }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        log("PairOut: numeric comparison \(numericValue) -> accepting")
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }
}

// MARK: - Main

let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
let mode = arguments.first ?? "auto"
let extras = Array(arguments.dropFirst())
let targetAddress = extras.first { $0.count == 17 }
let duration: Double = extras.compactMap(Double.init).first ?? (mode.hasPrefix("pair") ? 300 : 12)
if mode == "pairout", targetAddress == nil {
    log("Usage: HIDProbe pairout <Bluetooth address> [seconds]")
    exit(2)
}
let outgoingPairing = OutgoingPairing()
let snapper = ScreenSnapper(every: 3)

log("=== HIDProbe mode=\(mode) pid=\(getpid()) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString) ===")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let classic = ClassicProbe()
let ble = BLEProbe(testReportReference: mode == "desc")

// Bluetooth TCC must be granted before IOBluetooth is touched, otherwise the prompt blocks the main thread.
final class BluetoothGate: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var onReady: (() -> Void)?

    func wait(_ ready: @escaping () -> Void) {
        onReady = ready
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Auth: bluetooth authorization=\(CBManager.authorization.rawValue) state=\(central.state.rawValue)")
        guard CBManager.authorization == .allowedAlways, central.state == .poweredOn, let ready = onReady else { return }
        onReady = nil
        ready()
    }
}

let gate = BluetoothGate()
if mode == "snap" {
    probeScreenCapture()
    snapper.start()
}
if mode == "auto" || mode.hasPrefix("pair") {
    MobileDevice.enableAssistiveTouch = mode.hasPrefix("pair")
    MobileDevice.probe()
    probeScreenCapture()
    if mode.hasPrefix("pair") { snapper.start() }
}
var gatePassed = false
gate.wait {
    gatePassed = true
    switch mode {
    case "desc":
        ble.start()
    case "pair":
        classic.start(pairMode: true, targetAddress: targetAddress)
    case "pairout":
        classic.start(pairMode: true, targetAddress: targetAddress)
        if let targetAddress { outgoingPairing.start(address: targetAddress) }
    default:
        classic.start(pairMode: false, targetAddress: nil)
        ble.start()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: finish)
}

func finish() {
    classic.stop()
    MobileDevice.restore()
    log("=== HIDProbe done ===")
    exit(0)
}

signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler(handler: finish)
termSource.resume()
DispatchQueue.main.asyncAfter(deadline: .now() + 240) {
    guard !gatePassed else { return }
    log("Auth: Bluetooth permission not granted within 240s")
    finish()
}
app.run()
