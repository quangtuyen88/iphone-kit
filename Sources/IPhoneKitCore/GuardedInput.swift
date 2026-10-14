import Foundation

/// Per-command dispatch evidence. Revocation and dispatch share the main actor;
/// emergency release reports are deliberately not counted as command dispatch.
@MainActor
public final class InputDispatchWitness {
    public let id = UUID()
    public private(set) var didBeginDispatch = false
    private var revoked = false

    public init() {}

    public func check() throws {
        try Task.checkCancellation()
        guard !revoked else { throw CancellationError() }
    }

    public func beginDispatch() throws {
        try check()
        didBeginDispatch = true
    }

    @discardableResult
    public func revokeAndSnapshot() -> Bool {
        revoked = true
        return didBeginDispatch
    }
}

/// A read-only, cancellation-cooperative screen check. Implementations must not
/// recursively submit input while the command queue is awaiting authorization.
@MainActor
public struct GuardedInput {
    public let witness: InputDispatchWitness
    private let validation: @MainActor () async throws -> Void

    public init(witness: InputDispatchWitness, validation: @escaping @MainActor () async throws -> Void) {
        self.witness = witness
        self.validation = validation
    }

    public func authorize() async throws {
        try witness.check()
        try await validation()
        try witness.check()
    }
}
