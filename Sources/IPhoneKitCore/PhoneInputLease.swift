import Foundation

@MainActor
public protocol ExclusivePhoneControlling: PhoneControlling {
    func acquireInput(phoneID: String) throws -> PhoneInputLease
}

@MainActor
public final class PhoneInputLease {
    public let phoneID: String

    private let executeHandler: @MainActor (PhoneCommand) async throws -> ActionResult
    private let guardedExecuteHandler: (@MainActor (PhoneCommand, GuardedInput) async throws -> ActionResult)?
    private let drainHandler: @MainActor () -> Bool
    private let cancelHandler: @MainActor () -> Void
    private let releaseHandler: @MainActor () -> Void
    private var cancelInvoked = false
    private var releaseInvoked = false
    private var witnesses: [UUID: InputDispatchWitness] = [:]

    public var supportsGuardedExecution: Bool { guardedExecuteHandler != nil }
    public var isDrained: Bool { drainHandler() }

    public init(
        phoneID: String,
        execute: @escaping @MainActor (PhoneCommand) async throws -> ActionResult,
        guardedExecute: (@MainActor (PhoneCommand, GuardedInput) async throws -> ActionResult)? = nil,
        isDrained: @escaping @MainActor () -> Bool = { true },
        cancel: @escaping @MainActor () -> Void,
        release: @escaping @MainActor () -> Void
    ) {
        self.phoneID = phoneID
        self.executeHandler = execute
        self.guardedExecuteHandler = guardedExecute
        self.drainHandler = isDrained
        self.cancelHandler = cancel
        self.releaseHandler = release
    }

    private func checkEntry() throws {
        try Task.checkCancellation()
        guard !cancelInvoked, !releaseInvoked else {
            throw KitError("INPUT_LEASE_INVALID", "This input lease is no longer valid.")
        }
    }

    public func execute(_ command: PhoneCommand) async throws -> ActionResult {
        try checkEntry()
        return try await executeHandler(command)
    }

    public func executeGuarded(
        _ command: PhoneCommand,
        witness: InputDispatchWitness,
        validate: @escaping @MainActor () async throws -> Void
    ) async throws -> ActionResult {
        try checkEntry()
        guard let guardedExecuteHandler else {
            throw KitError("GUARDED_INPUT_UNSUPPORTED", "This connection cannot verify the screen before input.")
        }
        witnesses[witness.id] = witness
        defer { witnesses.removeValue(forKey: witness.id) }
        return try await guardedExecuteHandler(command, GuardedInput(witness: witness, validation: validate))
    }

    public func cancel() {
        guard !cancelInvoked else { return }
        cancelInvoked = true
        for witness in witnesses.values { witness.revokeAndSnapshot() }
        cancelHandler()
    }

    public func release() {
        guard !releaseInvoked else { return }
        releaseInvoked = true
        releaseHandler()
    }
}
