import Foundation

struct ImageGeometry: Sendable, Equatable {
    let width: Int
    let height: Int
    let nativeWidth: Int
    let nativeHeight: Int

    func pointer(x: Double, y: Double, buttons: UInt8 = 0) throws -> [UInt8] {
        guard width > 0, height > 0, x.isFinite, y.isFinite, x >= 0, y >= 0,
              x < Double(width), y < Double(height) else {
            throw KitError("INVALID_COORDINATES", "Coordinates must be pixels inside the referenced screenshot.")
        }
        // Landscape capture works, but its absolute-pointer axes have not been calibrated on hardware.
        guard nativeWidth < nativeHeight else {
            throw KitError("UNSUPPORTED_ORIENTATION", "Rotate the iPhone to portrait before sending pointer input.")
        }
        let hx = Int(((x + 0.5) / Double(width) * 32767).rounded())
        let hy = Int(((y + 0.5) / Double(height) * 32767).rounded())
        return HIDDescriptor.absolutePointer(x: hx, y: hy, buttons: buttons)
    }
}

struct TimedReport: Sendable, Equatable {
    let milliseconds: Double
    let bytes: [UInt8]
}

struct GesturePlan: Sendable {
    let reports: [TimedReport]

    static func build(_ command: PhoneCommand, geometry: ImageGeometry?) throws -> GesturePlan {
        var reports: [TimedReport] = []
        func add(_ time: Double, _ bytes: [UInt8]) { reports.append(TimedReport(milliseconds: time, bytes: bytes)) }
        func bounded(_ value: Double, min: Double, max: Double, name: String) throws -> Double {
            guard value.isFinite, value >= min, value <= max else {
                throw KitError("INVALID_ARGUMENT", "\(name) must be between \(min) and \(max).")
            }
            return value
        }
        func point(_ x: Double?, _ y: Double?) throws -> (Double, Double) {
            guard let x, let y, let geometry else {
                throw KitError("SCREENSHOT_REQUIRED", "Take a screenshot and pass its screenshot_id with pointer actions.")
            }
            _ = try geometry.pointer(x: x, y: y)
            return (x, y)
        }
        func pointer(_ time: Double, _ p: (Double, Double), _ buttons: UInt8) throws {
            guard let geometry else { throw KitError("SCREENSHOT_REQUIRED", "A screenshot is required.") }
            add(time, try geometry.pointer(x: p.0, y: p.1, buttons: buttons))
        }
        switch command.action {
        case .tap, .doubleTap, .tripleTap, .longPress, .move:
            let p = try point(command.x, command.y)
            try pointer(0, p, 0)
            if command.action == .move { break }
            let count = command.action == .tripleTap ? 3 : command.action == .doubleTap ? 2 : 1
            let hold = command.action == .longPress
                ? try bounded(command.duration ?? 1000, min: 100, max: 10_000, name: "duration (ms)") : 60
            for index in 0..<count {
                let start = 40.0 + Double(index) * 160
                try pointer(start, p, 1)
                try pointer(start + hold, p, 0)
            }
        case .drag, .holdAndDrag, .flick:
            let from: (Double, Double)
            let to: (Double, Double)
            let duration: Double
            var hold = 40.0
            if command.action == .flick {
                from = try point(command.x, command.y)
                guard let geometry, let direction = command.direction,
                      ["up", "down", "left", "right"].contains(direction) else {
                    throw KitError("INVALID_DIRECTION", "direction must be up, down, left, or right.")
                }
                let dx = Double(geometry.width) * 0.42
                let dy = Double(geometry.height) * 0.42
                to = (
                    min(Double(geometry.width - 1), max(0, from.0 + (direction == "left" ? -dx : direction == "right" ? dx : 0))),
                    min(Double(geometry.height - 1), max(0, from.1 + (direction == "up" ? -dy : direction == "down" ? dy : 0)))
                )
                duration = 135
            } else {
                from = try point(command.fromX, command.fromY)
                to = try point(command.toX, command.toY)
                let speeds = ["slow": 720.0, "medium": 360.0, "fast": 180.0]
                guard let speed = speeds[command.speed ?? "medium"] else {
                    throw KitError("INVALID_SPEED", "speed must be slow, medium, or fast.")
                }
                duration = speed
                if command.action == .holdAndDrag {
                    hold = try bounded(command.holdDurationMs ?? 500, min: 100, max: 10_000, name: "hold_duration_ms")
                }
            }
            try pointer(0, from, 0)
            try pointer(40, from, 1)
            let steps = max(1, Int(duration / 9))
            for index in 1...steps {
                let fraction = Double(index) / Double(steps)
                try pointer(40 + hold + duration * fraction,
                            (from.0 + (to.0 - from.0) * fraction, from.1 + (to.1 - from.1) * fraction), 1)
            }
            // No stationary pause before release: iOS measures release velocity from the final samples.
            try pointer(40 + hold + duration + 1, to, 0)
        case .typeText:
            guard let text = command.text else { throw KitError("INVALID_TEXT", "text is required.") }
            let keys = try HIDReports.typedKeys(text)
            for (index, key) in keys.enumerated() {
                let time = Double(index) * 60
                add(time, HIDReports.keyboard(usage: key.0, modifiers: key.1 ? 0x02 : 0))
                add(time + 30, HIDReports.keyboard())
            }
        case .pressKey:
            guard let key = command.key, let usage = HIDReports.keyUsages[key] else {
                throw KitError("INVALID_KEY", "Use enter, escape, backspace, tab, space, arrow keys, delete, home, end, pageup, or pagedown.")
            }
            let modifiers = try (command.modifiers ?? []).reduce(UInt8(0)) { mask, name in
                guard let value = HIDReports.modifierMasks[name] else {
                    throw KitError("INVALID_MODIFIER", "Use control, shift, alternate, or command.")
                }
                return mask | value
            }
            let count = command.repeatCount ?? 1
            guard (1...100).contains(count) else { throw KitError("INVALID_REPEAT", "repeat_count must be 1–100.") }
            for index in 0..<count {
                add(Double(index) * 80, HIDReports.keyboard(usage: usage, modifiers: modifiers))
                add(Double(index) * 80 + 40, HIDReports.keyboard())
            }
        case .pressHome:
            add(0, HIDReports.consumer(0x0223))
            add(60, HIDReports.consumer())
        case .wake:
            // A modifier-only keyboard pulse wakes iOS without typing or navigating.
            add(0, HIDReports.keyboard(modifiers: 0x02))
            add(60, HIDReports.keyboard())
        case .release:
            add(0, HIDReports.keyboard())
            add(1, HIDReports.consumer())
            add(2, HIDDescriptor.absolutePointer(x: 32766, y: 32766))
        }
        return GesturePlan(reports: reports)
    }
}

@MainActor
protocol ReportTransport: AnyObject {
    var epoch: UInt64 { get }
    var isReady: Bool { get }
    func send(_ report: [UInt8], epoch: UInt64, deadline: Date?) async throws
    func neutralize(epoch: UInt64)
}

@MainActor
struct GestureRunner {
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    func run(
            _ plan: GesturePlan, transport: any ReportTransport, epoch: UInt64, deadline: Date?,
            stillValid: () -> Bool, authorization: GuardedInput? = nil
        ) async throws {
            var didDispatch = false
            func checkValidity() throws {
                try Task.checkCancellation()
                try authorization?.witness.check()
                guard deadline.map({ value in value > Date() }) ?? true else {
                    throw KitError("DEADLINE_EXCEEDED", "Action deadline expired.")
                }
                guard transport.epoch == epoch, transport.isReady, stillValid() else {
                    throw KitError("CONNECTION_CHANGED", "Connection or screen geometry changed. Inspect the phone.")
                }
            }
            do {
                var previous = 0.0
                for report in plan.reports {
                    let wait = report.milliseconds - previous
                    if wait > 0 { try await sleep(.microseconds(Int64(wait * 1000))) }
                    try checkValidity()
                    if !didDispatch {
                        try await authorization?.authorize()
                        try checkValidity()
                        try authorization?.witness.beginDispatch()
                        didDispatch = true
                    }
                    try await transport.send(report.bytes, epoch: epoch, deadline: deadline)
                    try checkValidity()
                    previous = report.milliseconds
                }
            } catch {
                // A rejected guard sends no command reports. Cleanup after dispatch
                // stays on the original connection and cannot undo an applied action.
                if didDispatch, transport.epoch == epoch { transport.neutralize(epoch: epoch) }
                throw error
            }
        }
}

public extension PhoneCommand {
    func validate(for screenshot: Screenshot? = nil) throws {
        let geometry = screenshot.map {
            ImageGeometry(width: $0.width, height: $0.height, nativeWidth: $0.nativeWidth, nativeHeight: $0.nativeHeight)
        }
        _ = try GesturePlan.build(self, geometry: geometry)
    }
}
