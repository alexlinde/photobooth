import Foundation

/// Multicast `AsyncStream` source on the main actor. Each subscriber gets its own stream
/// buffering only the newest value, so a slow consumer (e.g. a UI busy laying out) sees the
/// latest frame rather than a backlog. Streams are never finished: they outlive reconnects.
@MainActor
final class Broadcaster<Element> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    var subscriberCount: Int { continuations.count }

    func subscribe(initial: Element? = nil) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        if let initial { continuation.yield(initial) }
        return stream
    }

    func yield(_ value: Element) {
        for c in continuations.values { c.yield(value) }
    }
}
