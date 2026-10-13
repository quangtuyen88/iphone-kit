import Foundation

@MainActor
public protocol ExclusivePhoneControlling: PhoneControlling {
    func acquireInput(phoneID: String) throws -> PhoneInputLease
}

@MainActor
public final class PhoneInputLease {
    public let phoneID: String

    private let executeHandler: @MainActor (PhoneCommand) async throws -> ActionResult
    private let cancelHandler: @MainActor () -> Void
    private let releaseHandler: @MainActor () -> Void
    private var cancelInvoked = false
    private var releaseInvoked = false

    public init(
        phoneID: String,
        execute: @escaping @MainActor (PhoneCommand) async throws -> ActionResult,
        cancel: @escaping @MainActor () -> Void,
        release: @escaping @MainActor () -> Void
    ) {
        self.phoneID = phoneID
        self.executeHandler = execute
        self.cancelHandler = cancel
        self.releaseHandler = release
    }

    public func execute(_ command: PhoneCommand) async throws -> ActionResult {
        try await executeHandler(command)
    }

    public func cancel() {
        guard !cancelInvoked else { return }
        cancelInvoked = true
        cancelHandler()
    }

    public func release() {
        guard !releaseInvoked else { return }
        releaseInvoked = true
        releaseHandler()
    }
}
