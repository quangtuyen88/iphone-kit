import Foundation

/// A single worker provides FIFO ordering across callers, unlike a reentrant async actor method.
@MainActor
final class CommandQueue {
    private struct Pending {
        let operation: @MainActor () async throws -> ActionResult
        let continuation: CheckedContinuation<ActionResult, any Error>
    }
    private var pending: [Pending] = []
    private var worker: Task<Void, Never>?
    var depth: Int { pending.count + (worker == nil ? 0 : 1) }

    func submit(_ operation: @escaping @MainActor () async throws -> ActionResult) async throws -> ActionResult {
        try Task.checkCancellation()
        guard depth < 64 else { throw KitError("QUEUE_FULL", "This phone has too many pending actions.") }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(operation: operation, continuation: continuation))
            if worker == nil { startWorker() }
        }
    }

    func cancel() {
        worker?.cancel()
        let removed = pending
        pending.removeAll()
        for item in removed { item.continuation.resume(throwing: KitError("CANCELLED", "Action cancelled.")) }
    }

    private func startWorker() {
        worker = Task { @MainActor in
            while !pending.isEmpty && !Task.isCancelled {
                let item = pending.removeFirst()
                do { item.continuation.resume(returning: try await item.operation()) }
                catch is CancellationError { item.continuation.resume(throwing: KitError("CANCELLED", "Action cancelled; held inputs released.")) }
                catch { item.continuation.resume(throwing: error) }
            }
            worker = nil
            if !pending.isEmpty { startWorker() }
        }
    }
}
