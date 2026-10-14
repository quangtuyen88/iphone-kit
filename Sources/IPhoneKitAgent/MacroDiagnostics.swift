import Foundation
import IPhoneKitCore

public enum MacroInputOutcome: String, Codable, Sendable {
    case notDispatched = "not_dispatched"
    case possiblySent = "possibly_sent"
    case sentButUnverified = "sent_but_unverified"

    public var message: String {
        switch self {
        case .notDispatched: "The interrupted command was not dispatched."
        case .possiblySent: "The interrupted command may have been sent. Inspect the phone."
        case .sentButUnverified: "Input was sent, but its result was not verified. Inspect the phone."
        }
    }
}

public enum MacroPauseReason: String, Codable, Sendable {
    case connectionChanged = "connection_changed"
    case screenChanged = "screen_changed"
    case contextChanged = "context_changed"
    case staleFrame = "stale_frame"
    case timeLimit = "time_limit"
    case inputFailure = "input_failure"
    case inputUncertain = "input_uncertain"
    case verificationFailed = "verification_failed"
    case approvalRejected = "approval_rejected"
    case userStopped = "user_stopped"
    case guardUnavailable = "guard_unavailable"

    public var message: String {
        switch self {
        case .connectionChanged: "The phone connection, screen source, or geometry changed."
        case .screenChanged: "The expected target screen could not be verified."
        case .contextChanged: "The surrounding screen changed. Animations, timers, or overlays can pause replay."
        case .staleFrame: "A fresh, correctly timed screen could not be verified."
        case .timeLimit: "The session or action time limit was reached."
        case .inputFailure: "Input failed. Inspect the phone before starting a new run."
        case .inputUncertain: "The input outcome is uncertain. Inspect the phone."
        case .verificationFailed: "Screen verification failed. Inspect the phone."
        case .approvalRejected: "The proposed action was rejected."
        case .userStopped: "The run was stopped."
        case .guardUnavailable: "This connection cannot verify the screen before input."
        }
    }
}

public struct MacroStepProgress: Codable, Sendable, Equatable {
    public let iteration: Int
    public let stepIndex: Int
    public let action: PhoneAction
}

/// Volatile recovery state. Never used as a resume cursor or exported as a trace.
public struct MacroRecovery: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let phoneID: String
    public let reason: MacroPauseReason
    public let lastVerifiedStep: MacroStepProgress?
    public let interruptedStep: MacroStepProgress?
    public let outcome: MacroInputOutcome
}

public enum MacroDiagnosticPhase: String, Codable, Sendable {
    case started
    case waitingForScreen = "waiting_for_screen"
    case awaitingApproval = "awaiting_approval"
    case checkingBeforeInput = "checking_before_input"
    case dispatched
    case sent
    case resultVerified = "result_verified"
    case interrupted
    case draining
    case stopped
    case completed
}

/// Exportable metadata only: never add images, OCR, names, device IDs, command
/// payloads, or raw backend errors to this type.
public struct MacroDiagnosticEvent: Identifiable, Codable, Sendable {
    public let id: UUID
    public let runID: UUID
    public let timestamp: Date
    public let phase: MacroDiagnosticPhase
    public let progress: MacroStepProgress?
    public let outcome: MacroInputOutcome?
    public let reason: MacroPauseReason?
}
