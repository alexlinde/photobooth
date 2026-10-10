import Foundation
import PTPKit

/// Async FIFO mutex on the main actor. PTP has one transaction in flight at a time per
/// session (ISO 15740 §9.3); live view, focus polling and capture all share the gate, and
/// waiters are served strictly in arrival order so a capture step queues behind at most the
/// one live-view fetch already in flight.
///
/// The gate is per session. `invalidate()` poisons it: current and future waiters throw,
/// so nothing can be sent behind a transaction that never completed.
@MainActor
final class TransactionGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private(set) var invalidation: Error?

    func acquire() async throws {
        if let invalidation { throw invalidation }
        if !busy {
            busy = true
            return
        }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    /// Hands ownership straight to the next waiter (if any), preserving FIFO order.
    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func invalidate(_ error: Error) {
        guard invalidation == nil else { return }
        invalidation = error
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume(throwing: error) }
    }
}

/// Wraps a `CameraTransport` for one session: serializes every transaction through a
/// `TransactionGate` and bounds it with a timeout. Any transport-level failure (thrown error,
/// as opposed to a PTP response code) or timeout is connection-fatal: the gate is poisoned
/// and `onFatal` fires so the supervisor tears the session down.
@MainActor
final class GatedTransport: PTPTransport {
    let base: CameraTransport
    let gate = TransactionGate()
    var timeout: Duration
    var liveViewTimeout: Duration
    var onFatal: ((Error) -> Void)?

    init(base: CameraTransport, timeout: Duration, liveViewTimeout: Duration) {
        self.base = base
        self.timeout = timeout
        self.liveViewTimeout = liveViewTimeout
    }

    func send(_ code: UInt16, parameters: [UInt32], outData: Data?) async throws -> PTPResponse {
        try await gate.acquire()
        defer { gate.release() }
        if let e = gate.invalidation { throw e }  // invalidated while we held/were handed the gate

        let isLiveView = code == PTPOperation.getObject && parameters.first == SonyHandle.liveView
        let label = "\(PTPOperation.name(code))(\(hex16(code)))"
        do {
            // Not cancellable: abandoning a transaction mid-flight would let the next one overlap
            // it. The timeout bounds it instead.
            return try await withTimeout(isLiveView ? liveViewTimeout : timeout, label, cancellable: false) {
                [base] in try await base.send(code, parameters: parameters, outData: outData)
            }
        } catch {
            gate.invalidate(PTPError.notConnected)
            onFatal?(error)
            throw error
        }
    }
}

/// Runs `body`, failing with `PTPError.timeout(what)` if it hasn't finished within `timeout`.
/// The body is not awaited after a timeout (it may never finish, e.g. an ICC transaction whose
/// completion never comes); it is cancelled and abandoned. If `cancellable`, cancelling the
/// caller abandons the body too; otherwise the caller waits for result or timeout.
@MainActor
func withTimeout<T>(_ timeout: Duration, _ what: String, cancellable: Bool = true,
                    _ body: @escaping @MainActor () async throws -> T) async throws -> T {
    let once = OnceContinuation<T>()
    let work = Task { @MainActor in
        do { once.resume(returning: try await body()) } catch { once.resume(throwing: error) }
    }
    let timer = Task {
        try? await Task.sleep(for: timeout)
        if !Task.isCancelled { once.resume(throwing: PTPError.timeout(what)) }
    }
    defer {
        timer.cancel()
        work.cancel()
    }
    if cancellable {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { once.set($0) }
        } onCancel: {
            once.resume(throwing: CancellationError())
        }
    }
    return try await withCheckedThrowingContinuation { once.set($0) }
}
