import Foundation

public struct KitError: Error, LocalizedError, Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

public enum PhoneStatus: String, Codable, Sendable {
    case needsTrust = "needs_trust"
    case needsSetup = "needs_setup"
    case needsBluetooth = "needs_bluetooth"
    case needsCapture = "needs_capture"
    case needsWake = "needs_wake"
    case ready, offline
}

public struct PhoneInfo: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var model: String
    public var systemVersion: String
    public var bluetoothAddress: String?
    public var status: PhoneStatus
    public var message: String
    public var width: Int
    public var height: Int
    public var captureID: String?
    public var epoch: UInt64
    public var keepAwake: Bool
    public var lastKeepAwakePulseAt: Date?
    public var keepAwakeError: String?
    /// While `status` is `needs_trust`: which step of "Trust This Computer?" the phone is at.
    public var trust: TrustProblem?
    /// The MobileDevice error behind `trust`, as `0xE8……`.
    public var trustErrorCode: String?
    public init(id: String, name: String, model: String = "iPhone", systemVersion: String = "", bluetoothAddress: String? = nil,
                status: PhoneStatus = .needsSetup, message: String = "", width: Int = 0, height: Int = 0, captureID: String? = nil,
                epoch: UInt64 = 0, keepAwake: Bool = false, lastKeepAwakePulseAt: Date? = nil, keepAwakeError: String? = nil,
                trust: TrustProblem? = nil, trustErrorCode: String? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.systemVersion = systemVersion
        self.bluetoothAddress = bluetoothAddress
        self.status = status
        self.message = message
        self.width = width
        self.height = height
        self.captureID = captureID
        self.epoch = epoch
        self.keepAwake = keepAwake
        self.lastKeepAwakePulseAt = lastKeepAwakePulseAt
        self.keepAwakeError = keepAwakeError
        self.trust = trust
        self.trustErrorCode = trustErrorCode
    }
}

public struct CaptureInfo: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct Screenshot: Identifiable, Codable, Sendable {
    public let id: String
    public let phoneID: String
    public let epoch: UInt64
    public let width: Int
    public let height: Int
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let capturedAt: Date
    public let jpeg: Data
    public let pointerX: Double?
    public let pointerY: Double?
    public let pointerVisible: Bool?
public let orientation: String
    public init(id: String = UUID().uuidString, phoneID: String, epoch: UInt64, width: Int, height: Int,
                nativeWidth: Int, nativeHeight: Int, capturedAt: Date, jpeg: Data,
                pointerX: Double? = nil, pointerY: Double? = nil, pointerVisible: Bool? = nil) {
        self.id = id; self.phoneID = phoneID; self.epoch = epoch
        self.width = width; self.height = height; self.nativeWidth = nativeWidth; self.nativeHeight = nativeHeight
        self.capturedAt = capturedAt; self.jpeg = jpeg
        self.pointerX = pointerX; self.pointerY = pointerY; self.pointerVisible = pointerVisible
        self.orientation = nativeWidth > nativeHeight ? "landscape" : "portrait"
    }
}

public enum PhoneAction: String, Codable, Sendable, CaseIterable {
    case tap, doubleTap = "double_tap", tripleTap = "triple_tap", longPress = "long_press"
    case flick, drag, holdAndDrag = "hold_and_drag", typeText = "type_text"
    case pressKey = "press_key", pressHome = "press_home", wake, move, release
    public var usesCoordinates: Bool {
        switch self {
        case .tap, .doubleTap, .tripleTap, .longPress, .flick, .drag, .holdAndDrag, .move: true
        default: false
        }
    }
}

public struct PhoneCommand: Codable, Sendable, Equatable {
    public var action: PhoneAction
    public var screenshotID: String?
    public var idempotencyKey: String?
    public var deadline: Date?
    public var x: Double?
    public var y: Double?
    public var fromX: Double?
    public var fromY: Double?
    public var toX: Double?
    public var toY: Double?
    public var duration: Double?
    public var holdDurationMs: Double?
    public var direction: String?
    public var speed: String?
    public var text: String?
    public var key: String?
    public var modifiers: [String]?
    public var repeatCount: Int?
    public init(action: PhoneAction, screenshotID: String? = nil, idempotencyKey: String? = nil, deadline: Date? = nil,
                x: Double? = nil, y: Double? = nil, fromX: Double? = nil, fromY: Double? = nil, toX: Double? = nil, toY: Double? = nil,
                duration: Double? = nil, holdDurationMs: Double? = nil, direction: String? = nil, speed: String? = nil,
                text: String? = nil, key: String? = nil, modifiers: [String]? = nil, repeatCount: Int? = nil) {
        self.action = action; self.screenshotID = screenshotID; self.idempotencyKey = idempotencyKey; self.deadline = deadline
        self.x = x; self.y = y; self.fromX = fromX; self.fromY = fromY; self.toX = toX; self.toY = toY
        self.duration = duration; self.holdDurationMs = holdDurationMs; self.direction = direction; self.speed = speed
        self.text = text; self.key = key; self.modifiers = modifiers; self.repeatCount = repeatCount
    }
}

public struct ActionResult: Identifiable, Codable, Sendable {
    public let id: String
    public let phoneID: String
    public let action: PhoneAction
    public let status: String
    public let startedAt: Date
    public let completedAt: Date
    public let epoch: UInt64
    public let message: String
    public init(id: String = UUID().uuidString, phoneID: String, action: PhoneAction, status: String = "sent",
                startedAt: Date, completedAt: Date = Date(), epoch: UInt64, message: String = "Input sent. Take a screenshot to verify the result.") {
        self.id = id; self.phoneID = phoneID; self.action = action; self.status = status
        self.startedAt = startedAt; self.completedAt = completedAt; self.epoch = epoch; self.message = message
    }
}

public struct DiagnosticEvent: Identifiable, Sendable {
    public let id = UUID()
    public let date = Date()
    public let message: String
    public init(_ message: String) { self.message = message }
}

@MainActor
public protocol PhoneControlling: AnyObject {
    var phones: [PhoneInfo] { get }
    var captures: [CaptureInfo] { get }
    var events: [DiagnosticEvent] { get }
    var permissionStatus: [String: String] { get }
    var isDemo: Bool { get }
    func start() async
    func stop() async
    func prepare(phoneID: String) async throws
    func bindCapture(phoneID: String, captureID: String) throws
    func screenshot(phoneID: String, longEdge: Int) async throws -> Screenshot
    func execute(phoneID: String, command: PhoneCommand) async throws -> ActionResult
    func cancel(phoneID: String)
    func setKeepAwake(phoneID: String, enabled: Bool) throws
}


public extension PhoneControlling {
    func setKeepAwake(phoneID: String, enabled: Bool) throws {
        throw KitError("KEEP_AWAKE_UNAVAILABLE", "Keep-awake is not supported by this phone controller.")
    }
}

public enum KitJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let raw = path.last!.stringValue
            let parts = raw.split(separator: "_")
            var key = String(parts.first ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
            if key.hasSuffix("Id") { key = String(key.dropLast(2)) + "ID" }
            return JSONKey(stringValue: key)!
        }
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct JSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
