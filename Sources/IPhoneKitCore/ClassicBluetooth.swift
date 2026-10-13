import Foundation
@preconcurrency import IOBluetooth
import ObjectiveC

/// macOS 27 can attach both a Classic peer and a disconnected BLE peripheral to the same device.
/// Its aggregate isConnected() then reports only BLE, including inside the public L2CAP opener.
@MainActor
enum ClassicBluetooth {
    static func linkReady(requiresClassicState: Bool, classicState: Int?, reportedConnected: Bool) -> Bool {
        requiresClassicState ? classicState == 2 : reportedConnected
    }

    static func isLinkUp(_ device: IOBluetoothDevice) -> Bool {
        if #available(macOS 27.0, *) {
            return linkReady(
                requiresClassicState: true, classicState: state(of: peer(of: device)), reportedConnected: false)
        }
        return device.isConnected()
    }

    static func open(_ device: IOBluetoothDevice, psm: BluetoothL2CAPPSM, delegate: HIDConnection) -> (
        IOReturn, IOBluetoothL2CAPChannel?
    ) {
        if #available(macOS 27.0, *) {
            guard let peer = peer(of: device), state(of: peer) == 2 else { return (kIOReturnNotOpen, nil) }
            // Do not enter the aggregate-readiness path, even if BLE currently happens to be connected.
            return openClassic(device, peer: peer, psm: psm)
        }
        guard device.isConnected() else { return (kIOReturnNotOpen, nil) }
        var channel: IOBluetoothL2CAPChannel?
        let status = device.openL2CAPChannelAsync(&channel, withPSM: psm, delegate: delegate)
        return (status, channel)
    }

    static func channelIsOpen(_ channel: IOBluetoothL2CAPChannel) -> Bool {
        guard channel.responds(to: NSSelectorFromString("isOpen")) else { return false }
        return (channel.value(forKey: "isOpen") as? NSNumber)?.boolValue == true
    }

    private static func peer(of device: IOBluetoothDevice) -> NSObject? {
        guard device.responds(to: NSSelectorFromString("peer")) else { return nil }
        return device.value(forKey: "peer") as? NSObject
    }

    private static func state(of peer: NSObject?) -> Int? {
        guard let peer, peer.responds(to: NSSelectorFromString("state")) else { return nil }
        return (peer.value(forKey: "state") as? NSNumber)?.intValue
    }

    private static func openClassic(_ device: IOBluetoothDevice, peer: NSObject, psm: BluetoothL2CAPPSM) -> (
        IOReturn, IOBluetoothL2CAPChannel?
    ) {
        let selector = NSSelectorFromString("initWithDevice:andClassicPeer:PSM:")
        guard let method = class_getInstanceMethod(IOBluetoothL2CAPChannel.self, selector),
            let encoding = method_getTypeEncoding(method), String(cString: encoding) == "@36@0:8@16@24S32",
            let allocation = IOBluetoothL2CAPChannel.perform(NSSelectorFromString("alloc"))
        else {
            bluetoothLog.error("Classic Bluetooth channel initializer is unavailable or its ABI changed")
            return (kIOReturnUnsupported, nil)
        }
        // Use the framework's connected-Classic fast path, without mutating its BLE association or spinning its
        // hidden baseband wait. The init-family method consumes alloc's +1, including on nil/replacement returns.
        typealias Initializer =
            @convention(c) (AnyObject, Selector, IOBluetoothDevice, NSObject, BluetoothL2CAPPSM) -> Unmanaged<
                IOBluetoothL2CAPChannel
            >?
        let initialize = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        let receiver = allocation.takeUnretainedValue()
        guard let channel = initialize(receiver, selector, device, peer, psm)?.takeRetainedValue() else {
            return (kIOReturnError, nil)
        }
        bluetoothLog.notice("HID opening Classic PSM \(psm), aggregateConnected=\(device.isConnected())")
        return (kIOReturnSuccess, channel)
    }
}
