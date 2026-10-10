import Foundation
import Network
import os

private let log = Logger(subsystem: "PhotoBooth", category: "upload")

public enum UploadError: Error, Equatable {
    case transient(String)
    case permanent(String)
    case notAuthorized
}

public protocol PhotoUploading: Sendable {
    func upload(fileURL: URL) async throws
}

public struct UploadQueueSnapshot: Sendable, Equatable {
    public var pending: Int
    public var inFlight: Int
    public var uploaded: Int
    public var failedPermanently: Int
    public var lastError: String?
    public var isPausedOffline: Bool

    public init(pending: Int = 0, inFlight: Int = 0, uploaded: Int = 0, failedPermanently: Int = 0,
                lastError: String? = nil, isPausedOffline: Bool = false) {
        self.pending = pending; self.inFlight = inFlight; self.uploaded = uploaded
        self.failedPermanently = failedPermanently; self.lastError = lastError
        self.isPausedOffline = isPausedOffline
    }
}

/// Time source, injectable so tests run instantly.
public protocol QueueClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemQueueClock: QueueClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// Reports connectivity (true = online). Injectable; the default wraps NWPathMonitor.
public protocol PathMonitoring: Sendable {
    func updates() -> AsyncStream<Bool>
}

public struct NWPathMonitoring: PathMonitoring {
    public init() {}
    public func updates() -> AsyncStream<Bool> {
        AsyncStream { cont in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { cont.yield($0.status == .satisfied) }
            cont.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "PhotoBooth.pathmonitor"))
        }
    }
}

public struct BackoffPolicy: Sendable, Equatable {
    public var base: TimeInterval = 5
    public var cap: TimeInterval = 30 * 60
    public var jitterFraction: Double = 0.2
    public var notAuthorizedDelay: TimeInterval = 5 * 60
    public init(base: TimeInterval = 5, cap: TimeInterval = 30 * 60,
                jitterFraction: Double = 0.2, notAuthorizedDelay: TimeInterval = 5 * 60) {
        self.base = base; self.cap = cap
        self.jitterFraction = jitterFraction; self.notAuthorizedDelay = notAuthorizedDelay
    }

    /// `attempt` is 1 for the first failure. `unit` in 0..<1 drives jitter (+/- jitterFraction).
    public func delay(forAttempt attempt: Int, unit: Double = Double.random(in: 0..<1)) -> TimeInterval {
        let exp = min(max(attempt - 1, 0), 30)
        let raw = min(base * pow(2, Double(exp)), cap)
        let jittered = raw * (1 + jitterFraction * (unit * 2 - 1))
        return min(max(jittered, 0), cap)
    }
}

/// Persistent upload queue: survives restarts, retries with exponential backoff.
public actor UploadQueue {
    enum ItemState: String, Codable { case pending, inFlight, uploaded, failed }

    struct Item: Codable, Equatable {
        var path: String
        var state: ItemState
        var attempts: Int
        var nextAttemptAt: Date?
        var lastError: String?
    }

    private struct StateFile: Codable { var version = 1; var items: [Item] }

    private let stateURL: URL
    private let uploader: PhotoUploading
    private let clock: QueueClock
    private let backoff: BackoffPolicy
    private let pathMonitor: PathMonitoring?
    private let randomUnit: @Sendable () -> Double

    private var items: [Item] = []
    private var lastError: String?
    /// With a path monitor, start "offline" until its first report arrives (NWPathMonitor reports
    /// immediately), so we never fire an upload before knowing the network state.
    private var online: Bool
    private var runTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<UploadQueueSnapshot>.Continuation] = [:]
    private let wakeStream: AsyncStream<Void>
    private let wakeCont: AsyncStream<Void>.Continuation

    public init(stateURL: URL,
                uploader: PhotoUploading,
                clock: QueueClock = SystemQueueClock(),
                backoff: BackoffPolicy = BackoffPolicy(),
                pathMonitor: PathMonitoring? = NWPathMonitoring(),
                randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.stateURL = stateURL
        self.uploader = uploader
        self.clock = clock
        self.backoff = backoff
        self.pathMonitor = pathMonitor
        self.online = pathMonitor == nil
        self.randomUnit = randomUnit
        var c: AsyncStream<Void>.Continuation!
        self.wakeStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c = $0 }
        self.wakeCont = c
        if let data = try? Data(contentsOf: stateURL) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let f = try? dec.decode(StateFile.self, from: data) {
                self.items = f.items
            } else {
                log.error("Could not decode upload state file; starting empty")
            }
        }
    }

    // MARK: Public API

    public func enqueue(_ fileURL: URL) {
        let path = fileURL.standardizedFileURL.path
        guard !items.contains(where: { $0.path == path }) else { return }
        items.append(Item(path: path, state: .pending, attempts: 0, nextAttemptAt: nil, lastError: nil))
        changed()
        wakeCont.yield()
    }

    public func reconcile(folder: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let known = Set(items.map(\.path))
        var added = false
        for u in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where u.pathExtension.lowercased() == "jpg" {
            let p = u.standardizedFileURL.path
            if !known.contains(p) && !items.contains(where: { $0.path == p }) {
                items.append(Item(path: p, state: .pending, attempts: 0, nextAttemptAt: nil, lastError: nil))
                added = true
            }
        }
        if added { changed(); wakeCont.yield() }
    }

    public func start() {
        guard runTask == nil else { return }
        var reset = false
        for i in items.indices where items[i].state == .inFlight {
            items[i].state = .pending
            reset = true
        }
        if reset { changed() }
        if let pathMonitor {
            let stream = pathMonitor.updates()
            monitorTask = Task { [weak self] in
                for await isOnline in stream {
                    await self?.setOnline(isOnline)
                }
            }
        }
        runTask = Task { [weak self] in await self?.runLoop() }
    }

    public func stop() {
        runTask?.cancel(); runTask = nil
        monitorTask?.cancel(); monitorTask = nil
    }

    public func snapshot() -> UploadQueueSnapshot {
        UploadQueueSnapshot(
            pending: items.filter { $0.state == .pending }.count,
            inFlight: items.filter { $0.state == .inFlight }.count,
            uploaded: items.filter { $0.state == .uploaded }.count,
            failedPermanently: items.filter { $0.state == .failed }.count,
            lastError: lastError,
            isPausedOffline: !online)
    }

    public nonisolated func updates() -> AsyncStream<UploadQueueSnapshot> {
        AsyncStream { cont in
            let id = UUID()
            Task { await self.addSubscriber(id, cont) }
            cont.onTermination = { _ in Task { await self.removeSubscriber(id) } }
        }
    }

    // MARK: Internals

    private func addSubscriber(_ id: UUID, _ c: AsyncStream<UploadQueueSnapshot>.Continuation) {
        subscribers[id] = c
        c.yield(snapshot())
    }
    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func setOnline(_ v: Bool) {
        guard online != v else { return }
        online = v
        log.info("Network \(v ? "online" : "offline", privacy: .public)")
        publish()
        wakeCont.yield()
    }

    private func publish() {
        let s = snapshot()
        for c in subscribers.values { c.yield(s) }
    }

    private func changed() {
        persist()
        publish()
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try enc.encode(StateFile(items: items)).write(to: stateURL, options: .atomic)
        } catch {
            log.error("Failed to persist upload state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard online else { await idle(delay: nil); continue }
            let now = clock.now()
            if let idx = items.firstIndex(where: {
                $0.state == .pending && ($0.nextAttemptAt ?? .distantPast) <= now
            }) {
                await process(path: items[idx].path)
                continue
            }
            let next = items.filter { $0.state == .pending }.compactMap(\.nextAttemptAt).min()
            await idle(delay: next.map { max(0, $0.timeIntervalSince(now)) })
        }
    }

    /// Waits for a wake signal, or (if given) the delay to elapse, whichever is first.
    private func idle(delay: TimeInterval?) async {
        let stream = wakeStream
        let clock = self.clock
        await withTaskGroup(of: Void.self) { g in
            g.addTask { var it = stream.makeAsyncIterator(); _ = await it.next() }
            if let delay {
                g.addTask { try? await clock.sleep(seconds: delay) }
            }
            await g.next()
            g.cancelAll()
        }
    }

    private func index(of path: String) -> Int? { items.firstIndex { $0.path == path } }

    private func process(path: String) async {
        guard let i = index(of: path) else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            items[i].state = .failed
            items[i].lastError = "File missing"
            lastError = "File missing: \((path as NSString).lastPathComponent)"
            changed()
            return
        }
        items[i].state = .inFlight
        changed()

        do {
            try await uploader.upload(fileURL: URL(fileURLWithPath: path))
            guard let j = index(of: path) else { return }
            items[j].state = .uploaded
            items[j].lastError = nil
            items[j].nextAttemptAt = nil
            lastError = nil
            log.info("Uploaded \((path as NSString).lastPathComponent, privacy: .public)")
            changed()
        } catch {
            guard let j = index(of: path) else { return }
            if Task.isCancelled || error is CancellationError {
                items[j].state = .pending
                changed()
                return
            }
            let now = clock.now()
            switch error as? UploadError {
            case .permanent(let msg):
                items[j].state = .failed
                items[j].lastError = msg
                lastError = msg
                log.error("Permanent upload failure: \(msg, privacy: .public)")
            case .notAuthorized:
                items[j].state = .pending
                items[j].attempts += 1
                items[j].nextAttemptAt = now.addingTimeInterval(backoff.notAuthorizedDelay)
                let msg = "Google Photos sign-in required"
                items[j].lastError = msg
                lastError = msg
                log.error("Upload not authorized; retrying in \(self.backoff.notAuthorizedDelay)s")
            case .transient(let msg):
                retry(j, msg, now)
            case nil:
                retry(j, error.localizedDescription, now)
            }
            changed()
        }
    }

    private func retry(_ j: Int, _ msg: String, _ now: Date) {
        items[j].state = .pending
        items[j].attempts += 1
        let d = backoff.delay(forAttempt: items[j].attempts, unit: randomUnit())
        items[j].nextAttemptAt = now.addingTimeInterval(d)
        items[j].lastError = msg
        lastError = msg
        log.error("Transient upload failure (attempt \(self.items[j].attempts)); retry in \(d)s: \(msg, privacy: .public)")
    }
}
