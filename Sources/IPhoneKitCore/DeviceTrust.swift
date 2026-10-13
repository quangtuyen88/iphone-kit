import Foundation

/// MobileDevice/lockdownd result codes (kAMD… errors) that drive the trust flow.
enum LockdownCode {
    static let passcodeProtected = code(0xE800_001A)
    static let missingHostID = code(0xE800_001B)
    static let invalidHostID = code(0xE800_001C)
    static let missingPairRecord = code(0xE800_0025)
    static let invalidPairRecord = code(0xE800_005C)
    static let userDenied = code(0xE800_0095)
    static let dialogPending = code(0xE800_0096)
    static let prohibitedByPolicy = code(0xE800_009A)
    static let securePairingRequired = code(0xE800_009B)
    static let deviceLocked = code(0xE800_00E2)

    static func code(_ value: UInt32) -> Int32 { Int32(bitPattern: value) }

    static func hex(_ code: Int32) -> String { String(format: "0x%08X", UInt32(bitPattern: code)) }

    /// Session failures meaning this Mac is not (or no longer) trusted, or the phone is too locked to tell.
    static func needsTrust(_ code: Int32) -> Bool {
        [passcodeProtected, missingHostID, invalidHostID, missingPairRecord, invalidPairRecord, deviceLocked].contains(code)
    }
}

/// Why a USB-connected phone does not trust this Mac yet. Raw values are part of the API.
public enum TrustProblem: String, Codable, Sendable, Equatable {
    /// Waiting for the user to unlock the phone; the Trust prompt can only appear on an unlocked phone.
    case locked
    /// The Trust prompt is on the phone.
    case awaitingUser = "awaiting_user"
    /// The phone rejected pairing; this does not establish which UI action caused it.
    case denied
    /// A device-management policy forbids pairing.
    case blocked
    /// Automatic attempts stopped; an explicit request starts again.
    case expired
    /// Pairing returned an unexpected error.
    case failed
    /// Pairing succeeded but the phone still refuses a session; automatic attempts stop.
    case sessionFailed = "session_failed"
    /// This macOS build lacks the pairing call; only reconnecting the cable shows the prompt.
    case unavailable

    /// The workflow is still retrying on its own.
    public var isActive: Bool { self == .locked || self == .awaitingUser }

    /// An explicit Show Trust prompt request can make progress.
    public var canRetry: Bool { [.denied, .expired, .failed, .sessionFailed].contains(self) }

    public static let checkingMessage = "Unlock the iPhone and keep it connected by USB. iPhoneKit will ask it to trust this Mac."

    public func message(code: String? = nil) -> String {
        let detail = code.map { " (\($0))" } ?? ""
        return switch self {
        case .locked: "Unlock the iPhone. If it asks, tap Trust and enter its passcode."
        case .awaitingUser: "On the iPhone, tap Trust, then enter its passcode."
        case .denied: "The iPhone rejected the pairing request\(detail). Unlock it and reconnect the USB cable. If prompted, tap Trust and enter the passcode on the iPhone."
        case .blocked: "A device-management policy on this iPhone blocks pairing with this Mac."
        case .expired: "The iPhone didn't answer the Trust request. Unlock it, then click Show Trust prompt."
        case .failed: "Pairing failed\(detail). iPhoneKit keeps retrying; if this persists, unplug and reconnect the iPhone."
        case .sessionFailed: "The iPhone accepted pairing but isn't completing the USB connection\(detail). Unplug and reconnect it, then click Show Trust prompt."
        case .unavailable: "Unlock the iPhone, then unplug and reconnect it to show the Trust prompt."
        }
    }
}

/// One phone's attempt to get "Trust This Computer?" accepted over the classic usbmux lockdown path.
///
/// lockdownd shows the prompt only for a pairing request that arrives while the phone is unlocked, and saves the
/// pairing only on a request made after the user accepts (`ExtendedPairingErrors` reports both states as codes;
/// libimobiledevice's idevicepair asks the user to "attempt to pair again" for the same reason). Requests therefore
/// repeat, each after the caller found the session still failing. A locked phone is retried for as long as it stays
/// locked — that is invisible to the user — while the bounded window only runs once the phone has answered (prompt
/// shown, or an unexpected error). Denial and policy errors latch until an explicit request or an unplug.
struct TrustWorkflow: Equatable {
    static let lockedInterval: TimeInterval = 5
    static let pendingInterval: TimeInterval = 3
    static let window: TimeInterval = 180

    private(set) var problem: TrustProblem?
    private(set) var lastCode: Int32 = 0
    private var windowStart: Date?
    private var nextAttempt: Date?

    /// A workflow re-armed by an explicit request (Show Trust prompt, Enable control), due immediately.
    static func restarted(now: Date) -> TrustWorkflow {
        var flow = TrustWorkflow()
        flow.nextAttempt = now
        return flow
    }

    /// Whether to send a pairing request now.
    mutating func attemptDue(now: Date) -> Bool {
        if let problem, !problem.isActive, problem != .failed { return false }
        if let windowStart, now.timeIntervalSince(windowStart) >= Self.window {
            problem = .expired
            return false
        }
        return now >= (nextAttempt ?? now)
    }

    mutating func record(_ code: Int32, now: Date) {
        lastCode = code
        switch code {
        case 0:
            // The session that follows decides; a transient failure there retries soon.
            problem = nil
            nextAttempt = now.addingTimeInterval(Self.pendingInterval)
        case LockdownCode.dialogPending:
            if windowStart == nil { windowStart = now }
            problem = .awaitingUser
            nextAttempt = now.addingTimeInterval(Self.pendingInterval)
        case LockdownCode.passcodeProtected, LockdownCode.deviceLocked:
            problem = .locked
            nextAttempt = now.addingTimeInterval(Self.lockedInterval)
        case LockdownCode.userDenied:
            problem = .denied
        case LockdownCode.prohibitedByPolicy, LockdownCode.securePairingRequired:
            problem = .blocked
        default:
            if windowStart == nil { windowStart = now }
            problem = .failed
            nextAttempt = now.addingTimeInterval(Self.lockedInterval)
        }
    }

    /// The session was refused because the phone is locked. It cannot show the prompt and may be paired already, so
    /// wait for unlock without sending a request; latched outcomes (Don't Trust, policy, expiry) stay latched.
    mutating func observeLocked(_ code: Int32, now: Date) {
        if let problem, !problem.isActive, problem != .failed { return }
        record(code, now: now)
    }

    /// Pairing reported success but the next session still failed. A locked phone (for example one that rebooted and
    /// was not unlocked yet) keeps waiting for unlock; any other refusal stops automatic attempts.
    mutating func recordRefusalAfterPairing(_ code: Int32, now: Date) {
        if code == LockdownCode.passcodeProtected || code == LockdownCode.deviceLocked {
            record(code, now: now)
        } else {
            lastCode = code
            problem = .sessionFailed
        }
    }

    mutating func markUnavailable() { problem = .unavailable }
}
