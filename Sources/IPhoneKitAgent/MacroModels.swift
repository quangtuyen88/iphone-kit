import Foundation
import IPhoneKitCore

/// A point expressed as a fraction of the screenshot's width and height.
/// The origin is the top-left corner and both axes increase toward the bottom/right.
public struct MacroPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangular region expressed in normalized (0...1) screenshot coordinates.
public struct MacroRegion: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = MacroRegion(x: 0, y: 0, width: 1, height: 1)
}

/// A JPEG guard recorded before or after a macro gesture.
public struct VisualAnchor: Codable, Sendable {
    public var image: Data
    public var region: MacroRegion
    public var expectedText: String
    public var tolerance: Double
    public var pointer: MacroPoint?

    public init(
        screenshot: Screenshot,
        region: MacroRegion = .full,
        expectedText: String = "",
        tolerance: Double = 0.035
    ) throws {
        try MacroValidation.validateScreenshotMetadata(screenshot)
        try MacroValidation.validateRegion(region)
        try MacroValidation.validateImageData(screenshot.jpeg)
        try LocalVisualMatcher.validateImage(screenshot.jpeg)
        guard expectedText.utf8.count <= MacroValidation.maxTextBytes,
              !expectedText.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
            throw MacroValidation.error("INVALID_EXPECTED_TEXT", "Expected anchor text is empty or too large/control-filled.")
        }
        guard tolerance.isFinite, tolerance >= 0, tolerance <= 1 else {
            throw MacroValidation.error("INVALID_TOLERANCE", "Anchor tolerance must be finite and between 0 and 1.")
        }

        var normalizedPointer: MacroPoint?
        if screenshot.pointerVisible != false, screenshot.pointerX != nil || screenshot.pointerY != nil {
            guard let pointerX = screenshot.pointerX, let pointerY = screenshot.pointerY,
                  pointerX.isFinite, pointerY.isFinite,
                  pointerX >= 0, pointerY >= 0,
                  pointerX < Double(screenshot.width), pointerY < Double(screenshot.height) else {
                throw MacroValidation.error("INVALID_POINTER", "A visible pointer must have finite coordinates inside the screenshot.")
            }
            normalizedPointer = MacroPoint(
                x: pointerX / Double(screenshot.width),
                y: pointerY / Double(screenshot.height)
            )
        }

        self.image = screenshot.jpeg
        self.region = region
        self.expectedText = expectedText
        self.tolerance = tolerance
        self.pointer = normalizedPointer
    }
}

/// A gesture recorded without screenshot IDs, deadlines, or other runtime metadata.
public struct MacroGesture: Codable, Sendable {
    public var action: PhoneAction
    public var start: MacroPoint
    public var end: MacroPoint
    public var duration: Double?
    public var holdDurationMs: Double?
    public var direction: String?
    public var speed: String?

    public init(command: PhoneCommand, screenshot: Screenshot) throws {
        try MacroValidation.validateScreenshotMetadata(screenshot)
        guard MacroValidation.allowedActions.contains(command.action) else {
            throw MacroValidation.error("UNSUPPORTED_MACRO_ACTION", "Only pointer gestures can be recorded in a visual macro.")
        }
        // Keep this call in the recording path so changes to the core gesture validator
        // remain authoritative for macros as well.
        try command.validate(for: screenshot)

        let startAbsolute: MacroPoint
        let endAbsolute: MacroPoint
        switch command.action {
        case .tap, .doubleTap, .tripleTap, .longPress:
            guard let x = command.x, let y = command.y else {
                throw MacroValidation.error("INVALID_GESTURE", "A tap gesture requires x and y.")
            }
            startAbsolute = MacroPoint(x: x, y: y)
            endAbsolute = startAbsolute
        case .drag, .holdAndDrag:
            guard let fromX = command.fromX, let fromY = command.fromY,
                  let toX = command.toX, let toY = command.toY else {
                throw MacroValidation.error("INVALID_GESTURE", "A drag gesture requires from and to coordinates.")
            }
            startAbsolute = MacroPoint(x: fromX, y: fromY)
            endAbsolute = MacroPoint(x: toX, y: toY)
        case .flick:
            guard let x = command.x, let y = command.y,
                  let direction = command.direction,
                  MacroValidation.directions.contains(direction) else {
                throw MacroValidation.error("INVALID_GESTURE", "A flick requires x, y, and an up/down/left/right direction.")
            }
            startAbsolute = MacroPoint(x: x, y: y)
            endAbsolute = MacroGesture.flickEnd(start: startAbsolute, direction: direction, screenshot: screenshot)
        default:
            // The action set is checked above; this keeps the switch exhaustive if the
            // core model gains another action in the future.
            throw MacroValidation.error("UNSUPPORTED_MACRO_ACTION", "This action cannot be stored in a visual macro.")
        }

        guard let start = MacroGesture.normalized(startAbsolute, screenshot: screenshot),
              let end = MacroGesture.normalized(endAbsolute, screenshot: screenshot) else {
            throw MacroValidation.error("INVALID_GESTURE", "Gesture coordinates must be finite pixels inside the screenshot.")
        }

        self.action = command.action
        self.start = start
        self.end = end
        self.duration = command.duration
        self.holdDurationMs = command.holdDurationMs
        self.direction = command.direction
        self.speed = command.speed
        try validateNormalized()
    }

    public func command(for screenshot: Screenshot) throws -> PhoneCommand {
        try MacroValidation.validateScreenshotMetadata(screenshot)
        try validateNormalized()

        let start = MacroGesture.absolute(start, screenshot: screenshot)
        let end = MacroGesture.absolute(end, screenshot: screenshot)
        var command: PhoneCommand
        switch action {
        case .tap, .doubleTap, .tripleTap, .longPress:
            command = PhoneCommand(
                action: action,
                screenshotID: screenshot.id,
                idempotencyKey: UUID().uuidString,
                x: start.x,
                y: start.y,
                duration: duration
            )
        case .drag, .holdAndDrag:
            command = PhoneCommand(
                action: action,
                screenshotID: screenshot.id,
                idempotencyKey: UUID().uuidString,
                fromX: start.x,
                fromY: start.y,
                toX: end.x,
                toY: end.y,
                duration: duration,
                holdDurationMs: holdDurationMs,
                speed: speed
            )
        case .flick:
            command = PhoneCommand(
                action: action,
                screenshotID: screenshot.id,
                idempotencyKey: UUID().uuidString,
                x: start.x,
                y: start.y,
                duration: duration,
                direction: direction
            )
        default:
            throw MacroValidation.error("UNSUPPORTED_MACRO_ACTION", "This action cannot be replayed from a visual macro.")
        }
        // A macro replay always binds to the fresh frame. The runner owns deadline
        // policy, so this deliberately remains nil.
        command.deadline = nil
        try command.validate(for: screenshot)
        return command
    }

    fileprivate func validateNormalized() throws {
        guard MacroValidation.allowedActions.contains(action),
              MacroValidation.validPoint(start), MacroValidation.validPoint(end) else {
            throw MacroValidation.error("INVALID_GESTURE", "Macro gesture coordinates or action are invalid.")
        }
        guard duration.map({ $0.isFinite }) ?? true,
              holdDurationMs.map({ $0.isFinite }) ?? true else {
            throw MacroValidation.error("INVALID_GESTURE", "Gesture durations must be finite.")
        }
        if let duration {
            guard duration >= 0, duration <= 10_000 else {
                throw MacroValidation.error("INVALID_GESTURE", "Gesture duration is outside the supported range.")
            }
        }
        if let holdDurationMs {
            guard holdDurationMs >= 0, holdDurationMs <= 10_000 else {
                throw MacroValidation.error("INVALID_GESTURE", "Gesture hold duration is outside the supported range.")
            }
        }
        if let direction, !MacroValidation.directions.contains(direction) {
            throw MacroValidation.error("INVALID_GESTURE", "Gesture direction must be up, down, left, or right.")
        }
        if let speed, !MacroValidation.speeds.contains(speed) {
            throw MacroValidation.error("INVALID_GESTURE", "Gesture speed must be slow, medium, or fast.")
        }
        switch action {
        case .tap, .doubleTap, .tripleTap:
            guard start == end else { throw MacroValidation.error("INVALID_GESTURE", "Tap endpoints must be equal.") }
        case .longPress:
            guard start == end else { throw MacroValidation.error("INVALID_GESTURE", "Long-press endpoints must be equal.") }
            if let duration { guard duration >= 100 else { throw MacroValidation.error("INVALID_GESTURE", "Long-press duration is too short.") } }
        case .holdAndDrag:
            if let holdDurationMs { guard holdDurationMs >= 100 else { throw MacroValidation.error("INVALID_GESTURE", "Hold duration is too short.") } }
        case .flick:
            guard let direction, MacroValidation.directions.contains(direction) else {
                throw MacroValidation.error("INVALID_GESTURE", "Flick direction is required.")
            }
        case .drag:
            break
        default:
            throw MacroValidation.error("UNSUPPORTED_MACRO_ACTION", "This action cannot be stored in a visual macro.")
        }
    }

    private static func normalized(_ point: MacroPoint, screenshot: Screenshot) -> MacroPoint? {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0,
              point.x < Double(screenshot.width), point.y < Double(screenshot.height) else { return nil }
        return MacroPoint(x: point.x / Double(screenshot.width), y: point.y / Double(screenshot.height))
    }

    private static func absolute(_ point: MacroPoint, screenshot: Screenshot) -> MacroPoint {
        // Values have already been checked to be strictly less than one. Keep a tiny
        // margin for floating point values decoded from JSON at the upper boundary.
        let x = min(Double(screenshot.width) - 0.000001, max(0, point.x * Double(screenshot.width)))
        let y = min(Double(screenshot.height) - 0.000001, max(0, point.y * Double(screenshot.height)))
        return MacroPoint(x: x, y: y)
    }

    private static func flickEnd(start: MacroPoint, direction: String, screenshot: Screenshot) -> MacroPoint {
        let dx = Double(screenshot.width) * 0.42
        let dy = Double(screenshot.height) * 0.42
        let x = min(Double(screenshot.width - 1), max(0, start.x + (direction == "left" ? -dx : direction == "right" ? dx : 0)))
        let y = min(Double(screenshot.height - 1), max(0, start.y + (direction == "up" ? -dy : direction == "down" ? dy : 0)))
        return MacroPoint(x: x, y: y)
    }
}

public struct MacroStep: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var gesture: MacroGesture
    public var before: VisualAnchor
    public var after: VisualAnchor
    public var delaySeconds: Double
    public var timeoutSeconds: Double
    public var requiresApproval: Bool

    public init(
        name: String,
        gesture: MacroGesture,
        before: VisualAnchor,
        after: VisualAnchor,
        delaySeconds: Double = 0.5,
        timeoutSeconds: Double = 8,
        requiresApproval: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.gesture = gesture
        self.before = before
        self.after = after
        self.delaySeconds = delaySeconds
        self.timeoutSeconds = timeoutSeconds
        self.requiresApproval = requiresApproval
    }

    fileprivate func validate() throws {
        try MacroValidation.validateName(name, field: "step name", maxBytes: MacroValidation.maxNameBytes)
        try gesture.validateNormalized()
        try before.validateStored()
        try after.validateStored()
        guard delaySeconds.isFinite, delaySeconds >= 0, delaySeconds <= 30 else {
            throw MacroValidation.error("INVALID_STEP_DELAY", "Step delay must be finite and between 0 and 30 seconds.")
        }
        guard timeoutSeconds.isFinite, timeoutSeconds >= 0.2, timeoutSeconds <= 30 else {
            throw MacroValidation.error("INVALID_STEP_TIMEOUT", "Step timeout must be finite and between 0.2 and 30 seconds.")
        }
    }
}

public struct MacroProfile: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var phoneID: String
    public var nativeWidth: Int
    public var nativeHeight: Int
    public var steps: [MacroStep]
    public var repetitions: Int
    public var maximumActions: Int
    public var maximumSeconds: Double
    public var stopWhen: VisualAnchor?

    public init(
        name: String,
        phoneID: String,
        nativeWidth: Int,
        nativeHeight: Int,
        steps: [MacroStep] = [],
        repetitions: Int = 1,
        maximumActions: Int = 20,
        maximumSeconds: Double = 120
    ) {
        self.id = UUID()
        self.name = name
        self.phoneID = phoneID
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.steps = steps
        self.repetitions = repetitions
        self.maximumActions = maximumActions
        self.maximumSeconds = maximumSeconds
        self.stopWhen = nil
    }

    public func validate(allowDraft: Bool = false) throws {
        try MacroValidation.validateName(name, field: "profile name", maxBytes: MacroValidation.maxNameBytes)
        try MacroValidation.validateName(phoneID, field: "phone ID", maxBytes: MacroValidation.maxPhoneIDBytes)
        guard nativeWidth > 0, nativeHeight > 0, nativeWidth < nativeHeight,
              nativeWidth <= MacroValidation.maxPortraitDimension,
              nativeHeight <= MacroValidation.maxPortraitDimension else {
            throw MacroValidation.error("UNSUPPORTED_ORIENTATION", "Macro profiles require a portrait phone no larger than 4096 pixels.")
        }
        guard steps.count <= MacroValidation.maxSteps else {
            throw MacroValidation.error("MACRO_TOO_LARGE", "A macro may contain at most 20 steps.")
        }
        guard (1...20).contains(repetitions) else {
            throw MacroValidation.error("INVALID_REPETITIONS", "Repetitions must be between 1 and 20.")
        }
        guard (1...100).contains(maximumActions) else {
            throw MacroValidation.error("INVALID_ACTION_BUDGET", "Maximum actions must be between 1 and 100.")
        }
        guard maximumSeconds.isFinite, (5...600).contains(maximumSeconds) else {
            throw MacroValidation.error("INVALID_TIME_BUDGET", "Maximum seconds must be finite and between 5 and 600.")
        }
        guard Set(steps.map(\.id)).count == steps.count else {
            throw MacroValidation.error("DUPLICATE_STEP_ID", "Macro steps must have unique IDs.")
        }
        if steps.isEmpty && !allowDraft {
            throw MacroValidation.error("EMPTY_MACRO", "A macro needs at least one step unless it is an explicitly stored draft.")
        }
        for step in steps { try step.validate() }
        try stopWhen?.validateStored()
    }
}

// MARK: - Shared validation used by the matcher and store

internal enum MacroValidation {
    static let maxImageBytes = 1_048_576
    static let maxSteps = 20
    static let maxPortraitDimension = 4096
    static let maxTextBytes = 4096
    static let maxNameBytes = 256
    static let maxPhoneIDBytes = 256
    static let directions: Set<String> = ["up", "down", "left", "right"]
    static let speeds: Set<String> = ["slow", "medium", "fast"]
    static let allowedActions: [PhoneAction] = [.tap, .doubleTap, .tripleTap, .longPress, .drag, .holdAndDrag, .flick]

    static func error(_ code: String, _ message: String) -> KitError { KitError(code, message) }

    static func validateName(_ value: String, field: String, maxBytes: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maxBytes,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw error("INVALID_MACRO_TEXT", "The \(field) must be non-empty, bounded, and contain no control characters.")
        }
    }

    static func validateRegion(_ region: MacroRegion) throws {
        guard region.x.isFinite, region.y.isFinite, region.width.isFinite, region.height.isFinite,
              region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
              region.x <= 1, region.y <= 1,
              region.x + region.width <= 1, region.y + region.height <= 1 else {
            throw error("INVALID_REGION", "Anchor region must be finite, positive, and inside normalized screenshot bounds.")
        }
    }

    static func validPoint(_ point: MacroPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0 && point.x < 1 && point.y < 1
    }

    static func validateScreenshotMetadata(_ screenshot: Screenshot) throws {
        guard !screenshot.id.isEmpty, screenshot.id.utf8.count <= maxPhoneIDBytes,
              !screenshot.id.unicodeScalars.contains(where: { $0.value < 0x20 }),
              screenshot.width > 0, screenshot.height > 0, screenshot.width < screenshot.height,
              screenshot.nativeWidth > 0, screenshot.nativeHeight > 0,
              screenshot.width <= maxPortraitDimension, screenshot.height <= maxPortraitDimension,
              screenshot.nativeWidth <= maxPortraitDimension, screenshot.nativeHeight <= maxPortraitDimension,
              screenshot.nativeWidth < screenshot.nativeHeight else {
            throw error("UNSUPPORTED_ORIENTATION", "Visual macros require a portrait screenshot no larger than 4096 pixels.")
        }
        if screenshot.pointerVisible != false, screenshot.pointerX != nil || screenshot.pointerY != nil {
            guard let x = screenshot.pointerX, let y = screenshot.pointerY,
                  x.isFinite, y.isFinite,
                  x >= 0, y >= 0,
                  x < Double(screenshot.width), y < Double(screenshot.height) else {
                throw error("INVALID_POINTER", "Pointer coordinates must be finite pixels inside the screenshot.")
            }
        } else {
            if let x = screenshot.pointerX { guard x.isFinite else { throw error("INVALID_POINTER", "Pointer coordinates must be finite.") } }
            if let y = screenshot.pointerY { guard y.isFinite else { throw error("INVALID_POINTER", "Pointer coordinates must be finite.") } }
        }
    }

    static func validateImageData(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maxImageBytes else {
            throw error("IMAGE_TOO_LARGE", "Macro anchor images must be non-empty JPEG data no larger than 1 MB.")
        }
        // JPEG's SOI marker is cheap to check here. Full bounded decoding is done by
        // LocalVisualMatcher, where the dimensions can be checked before rasterizing.
        guard data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else {
            throw error("INVALID_IMAGE", "Macro anchors must store JPEG screenshot data.")
        }
    }
}

internal extension VisualAnchor {
    func validateStored() throws {
        try MacroValidation.validateRegion(region)
        try MacroValidation.validateImageData(image)
        try LocalVisualMatcher.validateImage(image)
        guard expectedText.utf8.count <= MacroValidation.maxTextBytes,
              !expectedText.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
            throw MacroValidation.error("INVALID_EXPECTED_TEXT", "Expected anchor text is empty or too large/control-filled.")
        }
        guard tolerance.isFinite, tolerance >= 0, tolerance <= 1 else {
            throw MacroValidation.error("INVALID_TOLERANCE", "Anchor tolerance must be finite and between 0 and 1.")
        }
        if let pointer {
            guard MacroValidation.validPoint(pointer) else {
                throw MacroValidation.error("INVALID_POINTER", "Stored pointer coordinates must be finite normalized points.")
            }
        }
    }
}
