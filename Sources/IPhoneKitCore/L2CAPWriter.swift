import Foundation
@preconcurrency import IOBluetooth

/// Serializes reports on one L2CAP channel: one native write in flight, a bounded FIFO, and a watchdog per write.
/// `writeAsync` returns success only after IOBluetooth buffered the bytes, so buffers can be freed with the write.
@MainActor
final class L2CAPWriter {
    private final class PendingWrite {
        let buffer: UnsafeMutableRawPointer
        let length: UInt16
        var continuation: CheckedContinuation<Void, any Error>?
        var timeout: Task<Void, Never>?

        init(_ bytes: [UInt8], continuation: CheckedContinuation<Void, any Error>?) {
            buffer = .allocate(byteCount: bytes.count, alignment: 1)
            length = UInt16(bytes.count)
            self.continuation = continuation
            bytes.withUnsafeBytes { source in buffer.copyMemory(from: source.baseAddress!, byteCount: bytes.count) }
        }

        func settle(_ result: Result<Void, any Error>, cancelTimeout: Bool = true) {
            if cancelTimeout {
                timeout?.cancel()
                timeout = nil
            }
            let waiter = continuation
            continuation = nil
            waiter?.resume(with: result)
        }

        deinit { buffer.deallocate() }
    }

    private static var nextIdentifier: UInt = 0
    private let submit: (UnsafeMutableRawPointer, UInt16, UnsafeMutableRawPointer) -> IOReturn
    private let timeout: Duration
    private var isOpen = true
    private var pending: [UInt: PendingWrite] = [:]
    private var queue: [UInt] = []
    private var inFlight: UInt?
    var failed: (() -> Void)?
    var drained: (() -> Void)?
    var pendingCount: Int { pending.count }

    init(
        timeout: Duration = .seconds(2),
        submit: @escaping (UnsafeMutableRawPointer, UInt16, UnsafeMutableRawPointer) -> IOReturn
    ) {
        self.timeout = timeout
        self.submit = submit
    }

    /// Tokens are unique across writers, so a completion can be offered to every writer of a connection.
    private static func identifier() -> UInt {
        nextIdentifier += 1
        return nextIdentifier
    }

    func write(_ bytes: [UInt8], maximumWait: Duration? = nil) async throws {
        try Task.checkCancellation()
        let identifier = Self.identifier()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                do {
                    try start(bytes, identifier: identifier, maximumWait: maximumWait, continuation: continuation)
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(identifier: identifier) }
        }
        try Task.checkCancellation()
    }

    func enqueue(_ bytes: [UInt8]) throws {
        try start(bytes, identifier: Self.identifier(), maximumWait: nil, continuation: nil)
    }

    private func start(
        _ bytes: [UInt8], identifier: UInt, maximumWait: Duration?, continuation: CheckedContinuation<Void, any Error>?
    ) throws {
        guard isOpen else { throw KitError("BLUETOOTH_DISCONNECTED", "Bluetooth input disconnected.") }
        guard pending.count < 32 else {
            throw KitError("BLUETOOTH_BUSY", "Bluetooth input is not draining. Inspect the phone before retrying.")
        }
        guard !bytes.isEmpty, bytes.count <= Int(UInt16.max) else {
            throw KitError("INVALID_REPORT", "Invalid Bluetooth report size.")
        }
        let write = PendingWrite(bytes, continuation: continuation)
        pending[identifier] = write
        queue.append(identifier)
        let wait = min(timeout, maximumWait ?? timeout)
        write.timeout = Task { [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            guard let self, pending[identifier] != nil else { return }
            invalidate(
                error: KitError(
                    "BLUETOOTH_TIMEOUT",
                    "Bluetooth input timed out. Inspect the phone before reconnecting; the action was not replayed."))
            failed?()
        }
        pump()
    }

    private func pump() {
        guard isOpen, inFlight == nil, !queue.isEmpty else { return }
        let identifier = queue.removeFirst()
        guard let write = pending[identifier] else { return }
        inFlight = identifier
        let status = submit(write.buffer, write.length, UnsafeMutableRawPointer(bitPattern: identifier)!)
        if status != kIOReturnSuccess { complete(identifier: identifier, status: status) }
    }

    private func cancel(identifier: UInt) {
        if inFlight == identifier {
            // Already handed to IOBluetooth: release the caller but keep the watchdog for the native write.
            pending[identifier]?.settle(.failure(CancellationError()), cancelTimeout: false)
        } else {
            queue.removeAll { queued in queued == identifier }
            pending.removeValue(forKey: identifier)?.settle(.failure(CancellationError()))
        }
    }

    func complete(identifier: UInt, status: IOReturn) {
        guard inFlight == identifier, let write = pending.removeValue(forKey: identifier) else { return }
        inFlight = nil
        if status == kIOReturnSuccess {
            let becameEmpty = pending.isEmpty
            write.settle(.success(()))
            pump()
            if becameEmpty, pending.isEmpty { drained?() }
        } else {
            let error = KitError("ACTION_INTERRUPTED", "Input delivery failed. Inspect the phone before retrying.")
            write.settle(.failure(error))
            invalidate(error: error)
            failed?()
        }
    }

    func invalidate(error: any Error = KitError("BLUETOOTH_DISCONNECTED", "Bluetooth input disconnected.")) {
        guard isOpen else { return }
        isOpen = false
        let writes = Array(pending.values)
        pending.removeAll()
        queue.removeAll()
        inFlight = nil
        for write in writes { write.settle(.failure(error)) }
    }
}
