import Foundation

/// Time source for the booth state machine and the fake camera, injectable so tests and
/// `--self-test` run instantly and deterministically.
@MainActor
public protocol BoothClock: AnyObject {
    func now() -> Date
    /// Suspends for `seconds`. Throws `CancellationError` if the calling task is cancelled.
    func sleep(seconds: Double) async throws
}

/// Wall-clock implementation.
@MainActor
public final class SystemBoothClock: BoothClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws {
        if seconds <= 0 { try Task.checkCancellation(); return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Manually advanced clock. Sleepers suspend until `advance(by:)` moves time past their
/// deadline. Everything runs on the main actor, so after resuming sleepers we yield a
/// number of times to let dependent main-actor work settle.
@MainActor
public final class ManualBoothClock: BoothClock {
    private struct Sleeper {
        let id: Int
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private var current: Date
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    public func now() -> Date { current }

    var pendingSleepers: Int { sleepers.count }

    public func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        if seconds <= 0 {
            await Task.yield()
            try Task.checkCancellation()
            return
        }
        nextID += 1
        let id = nextID
        let deadline = current.addingTimeInterval(seconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                sleepers.append(Sleeper(id: id, deadline: deadline, continuation: cont))
            }
        } onCancel: {
            Task { @MainActor in self.cancelSleeper(id) }
        }
    }

    private func cancelSleeper(_ id: Int) {
        guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return }
        let s = sleepers.remove(at: i)
        s.continuation.resume(throwing: CancellationError())
    }

    /// Lets pending main-actor work run (stream deliveries, task continuations).
    func settle(_ rounds: Int = 60) async {
        for _ in 0..<rounds { await Task.yield() }
    }

    /// Advances time, waking sleepers in deadline order and settling after each wake-up so
    /// that sleeps started as a consequence (within the window) are honoured too.
    func advance(by seconds: Double) async {
        let target = current.addingTimeInterval(seconds)
        await settle()
        while true {
            let due = sleepers.filter { $0.deadline <= target }.min { $0.deadline < $1.deadline }
            guard let next = due else { break }
            sleepers.removeAll { $0.id == next.id }
            if next.deadline > current { current = next.deadline }
            next.continuation.resume()
            await settle()
        }
        current = target
        await settle()
    }
}
