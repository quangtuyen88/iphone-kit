import Foundation
import IOBluetooth

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

enum HIDReports {
    static func keyboard(usage: UInt8 = 0, modifiers: UInt8 = 0) -> [UInt8] {
        [0xA1, 0x01, modifiers, 0, usage, 0, 0, 0, 0, 0]
    }
    static func consumer(_ usage: UInt16 = 0) -> [UInt8] {
        [0xA1, 0x03, UInt8(usage & 0xFF), UInt8(usage >> 8)]
    }
    static let keyUsages: [String: UInt8] = [
        "enter": 0x28, "escape": 0x29, "backspace": 0x2A, "tab": 0x2B,
        "space": 0x2C, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
        "delete": 0x4C, "home": 0x4A, "end": 0x4D, "pageup": 0x4B, "pagedown": 0x4E,
    ]
    static let modifierMasks: [String: UInt8] = ["control": 0x01, "shift": 0x02, "alternate": 0x04, "command": 0x08]

    static func typedKeys(_ text: String) throws -> [(UInt8, Bool)] {
        guard !text.isEmpty, text.utf8.count <= 1000 else {
            throw KitError("INVALID_TEXT", "Text must contain 1–1000 US-ASCII characters.")
        }
        return try text.map { character in
            guard let key = Keyboard.usage(for: character) else {
                throw KitError("UNSUPPORTED_TEXT", "Bluetooth typing supports US-ASCII only. No text was sent.")
            }
            return key
        }
    }
}
