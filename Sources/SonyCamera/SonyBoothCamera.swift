import CoreGraphics
import Foundation
import ImageIO
import os
import PTPKit

/// The real `BoothCamera`: a Sony body in PC Remote mode over ImageCaptureCore.
///
/// A supervisor task owns the connection: searching → connecting (open session, handshake,
/// drain stale object, optional Setting Effect off, wait for live view) → ready (live view
/// loop) → on any failure: recovering, close, back off, start over. Every PTP transaction of
/// a session goes through one `GatedTransport`, so live view, focus polling and capture
/// never overlap, and a transaction that never completes poisons only that session.
@MainActor
public final class SonyBoothCamera: BoothCamera {
    public struct Options {
        /// How long to wait for AF after the half-press before firing anyway.
        public var focusTimeout: Duration = .seconds(3)
        /// Try to turn Live View Display "Setting Effect" off (0xD231 = 2). The ZV-E10 reports
        /// the property as display-only, so this is best-effort and failure is only logged.
        public var disableLiveViewSettingEffect = true
        /// Keep live view running between half-press and full press, so the countdown plays
        /// over a live picture. Live view always pauses from the full press until download.
        public var liveViewDuringFocus = true
        /// Log every PTP command/response (very chatty: ~30 transactions/s in live view).
        public var traceTransactions = false
        /// Receives every log line (also sent to os.Logger, subsystem "PhotoBooth", category "camera").
        public var log: @MainActor (String) -> Void = { _ in }

        // Tunables; the defaults suit the ZV-E10. Tests shrink them.
        public var transactionTimeout: Duration = .seconds(10)
        /// A live-view GetObject normally takes ~30 ms; one that hangs means the session is wedged.
        public var liveViewTransactionTimeout: Duration = .seconds(3)
        public var openSessionTimeout: Duration = .seconds(10)
        public var liveViewStartTimeout: Duration = .seconds(10)
        /// No live-view frame for this long while not paused → reconnect.
        public var liveViewStallTimeout: Duration = .seconds(10)
        /// Camera attached on USB but not delivered by ImageCaptureCore for this long → hint.
        public var undeliveredCameraHintAfter: Duration = .seconds(15)
        public var maxShutterHold: Duration = .seconds(3)
        public var imageReadyTimeout: Duration = .seconds(10)
        public var postConnectSettle: Duration = .seconds(3)
        public var pollInterval: Duration = .milliseconds(30)
        public var liveViewRetryDelay: Duration = .milliseconds(10)
        public var discoveryPollTimeout: Duration = .seconds(5)
        public var initialBackoff: Duration = .milliseconds(500)
        public var maxBackoff: Duration = .seconds(10)

        public init() {}
    }

    /// Faults the soak test can inject to prove recovery without unplugging.
    public enum SimulatedFault: Sendable {
        /// Close the ImageCaptureCore session behind the supervisor's back.
        case sessionClosed
        /// Drop the completion of the next transaction so it can only time out.
        case transactionHang
    }

    public private(set) var state: CameraConnectionState = .searching
    public var traceTransactions: Bool {
        didSet { transport.traceTransactions = traceTransactions }
    }

    // Diagnostics (not part of BoothCamera).
    public private(set) var liveViewFramesFetched = 0
    public private(set) var liveViewFramesDecoded = 0
    public private(set) var liveViewNotReady = 0
    public private(set) var lastCaptureTiming: SonySession.CaptureTiming?
    public private(set) var connectCount = 0

    private let options: Options
    private let transport: CameraTransport
    private let states = Broadcaster<CameraConnectionState>()
    private let frames = Broadcaster<CGImage>()
    private static let logger = Logger(subsystem: "PhotoBooth", category: "camera")

    private var supervisor: Task<Void, Never>?
    /// Bumped by start/stop so a supervisor that is still unwinding can't touch a newer one's state.
    private var generation = 0
    private var current: Connection?
    private var nextConnectionID = 1
    private var capturing = false
    private var decodeInFlight = false
    private var pendingJPEG: Data?

    public convenience init(options: Options = Options()) {
        let icc = ICCTransport()
        self.init(transport: icc, options: options)
        icc.log = { [weak self] in self?.log($0) }
    }

    /// Designated initializer; tests pass a fake transport.
    init(transport: CameraTransport, options: Options) {
        self.options = options
        self.transport = transport
        traceTransactions = options.traceTransactions
        transport.traceTransactions = options.traceTransactions
    }

    // MARK: - BoothCamera

    public func stateUpdates() -> AsyncStream<CameraConnectionState> { states.subscribe(initial: state) }
    public func liveViewFrames() -> AsyncStream<CGImage> { frames.subscribe() }

    public func start() {
        guard supervisor == nil else { return }
        generation += 1
        let gen = generation
        transport.onEvent = { [weak self] ev in self?.current?.session.receive(ev) }
        transport.onDisconnect = { [weak self] in self?.current?.fault("camera disconnected") }
        log("camera supervisor starting")
        supervisor = Task { [weak self] in await self?.supervise(gen) }
    }

    public func stop() {
        guard let task = supervisor else { return }
        generation += 1
        supervisor = nil
        task.cancel()
        teardown("stopped")
        log("camera supervisor stopped")
        setState(.searching)
    }

    public func prepareCapture() async {
        guard state.isReady, let conn = current, conn.isAlive, !capturing, conn.halfPressedAt == nil else { return }
        conn.halfPressedAt = .now
        if !options.liveViewDuringFocus { conn.beginPrepareHold() }
        do {
            try await conn.session.halfPress()
            log("half-press (prepare)")
        } catch {
            conn.halfPressedAt = nil
            conn.endPrepareHold()
            log("prepare: half-press failed: \(Self.describe(error))", .error)
        }
    }

    public func cancelPrepare() async {
        guard let conn = current, !capturing, conn.halfPressedAt != nil else { return }
        conn.halfPressedAt = nil
        conn.endPrepareHold()
        do {
            try await conn.session.releaseHalfPress()
            log("half-press released (prepare cancelled)")
        } catch {
            log("cancelPrepare: release failed: \(Self.describe(error))", .error)
        }
    }

    public func capture() async throws -> CapturedPhoto {
        guard !capturing else { throw BoothCameraError.captureInProgress }
        guard state.isReady, let conn = current, conn.isAlive else { throw BoothCameraError.notReady }
        capturing = true
        let s = conn.session
        var timing = SonySession.CaptureTiming()
        let start = ContinuousClock.now
        var holdingLiveView = false
        func pauseLiveView() {
            if !holdingLiveView { conn.liveViewHolds += 1; holdingLiveView = true }
        }
        defer {
            if holdingLiveView { conn.liveViewHolds -= 1 }
            conn.endPrepareHold()
            capturing = false
        }

        do {
            if !options.liveViewDuringFocus { pauseLiveView() }
            try await s.waitForPostConnectSettle(options.postConnectSettle)
            let drained = try await s.drainStaleObjects()
            if drained > 0 { log("drained \(drained) stale object(s) before capture") }

            let halfAt: ContinuousClock.Instant
            if let t = conn.halfPressedAt {
                halfAt = t
            } else {
                halfAt = .now
                conn.halfPressedAt = halfAt
                try await s.halfPress()
            }
            let focusStart = ContinuousClock.now
            let focus = try await s.waitForFocus(until: halfAt + options.focusTimeout, poll: options.pollInterval)
            timing.focusWait = ContinuousClock.now - focusStart
            timing.focusResult = focus.map { SonySession.focusSettled($0) ? "FocusFound=\($0)" : "not settled (FocusFound=\($0))" }
                ?? "manual focus"

            pauseLiveView()
            s.clearEvents()
            let fullPress = ContinuousClock.now
            timing.toFullPress = fullPress - start
            try await s.fullPressAndHold(maxHold: options.maxShutterHold, poll: options.pollInterval)
            try await s.releaseShutter()
            conn.halfPressedAt = nil
            let released = ContinuousClock.now
            timing.hold = released - fullPress

            timing.readySignal = try await s.waitForImage(timeout: options.imageReadyTimeout, poll: options.pollInterval)
            timing.releaseToReady = ContinuousClock.now - released

            let dl = ContinuousClock.now
            let (data, filename) = try await s.downloadCapturedImage()
            timing.download = ContinuousClock.now - dl
            timing.total = ContinuousClock.now - start
            lastCaptureTiming = timing
            log("captured \(filename ?? "?") (\(data.count / 1024) KB): \(timing)")
            return CapturedPhoto(jpeg: data, cameraFilename: filename, capturedAt: Date())
        } catch {
            // Never leave the shutter held, whatever failed. Best-effort: on a dead session
            // these fail immediately.
            conn.halfPressedAt = nil
            if conn.isAlive { try? await s.releaseShutter() }
            let reason = conn.faultReason.map { "connection lost: \($0)" } ?? Self.describe(error)
            log("capture failed: \(reason)", .error)
            throw BoothCameraError.captureFailed(reason)
        }
    }

    // MARK: - Fault injection

    public func simulateFault(_ fault: SimulatedFault) {
        log("⚠️ simulating fault: \(fault)")
        switch fault {
        case .sessionClosed:
            transport.closeSession()
        case .transactionHang:
            (transport as? ICCTransport)?.dropNextCompletion = true
        }
    }

    // MARK: - Supervisor

    private func supervise(_ gen: Int) async {
        var backoff = options.initialBackoff
        while gen == generation, !Task.isCancelled {
            var reason: String
            do {
                let name = try await search(gen)
                let conn = try await establish(name, gen)
                backoff = options.initialBackoff
                reason = await conn.waitForFault()
            } catch {
                reason = current?.faultReason ?? Self.describe(error)
            }
            guard gen == generation, !Task.isCancelled else { break }
            log("connection lost: \(reason); reconnecting in \(SonySession.CaptureTiming.ms(backoff))", .error)
            setState(.recovering(reason: reason))
            teardown(reason)
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, options.maxBackoff)
        }
    }

    private func search(_ gen: Int) async throws -> String {
        guard gen == generation else { throw CancellationError() }
        setState(.searching)
        let t0 = ContinuousClock.now
        var hinted = false
        while true {
            try Task.checkCancellation()
            do {
                let poll = options.discoveryPollTimeout
                return try await withTimeout(poll + .seconds(1), "camera discovery") { [transport] in
                    try await transport.findCamera(timeout: poll)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Not found yet. If something is on USB but never delivered, it's almost always
                // the Removable Volumes privacy permission: ptpcamerad leaves the device in
                // "starting" and the browser never reports it.
                if !hinted, ContinuousClock.now - t0 >= options.undeliveredCameraHintAfter,
                   let usb = transport.attachedUSBCameraName() {
                    hinted = true
                    let hint = "camera visible but not delivered (\(usb) is on USB) — check System Settings → "
                        + "Privacy & Security → Files & Folders → Removable Volumes for this app"
                    log(hint, .error)
                    if gen == generation { setState(.recovering(reason: hint)) }
                }
            }
        }
    }

    private func establish(_ name: String, _ gen: Int) async throws -> Connection {
        // A supervisor from before a stop()/start() must not claim the new one's session.
        guard gen == generation else { throw CancellationError() }
        setState(.connecting(name: name))
        let link = GatedTransport(base: transport, timeout: options.transactionTimeout,
                                  liveViewTimeout: options.liveViewTransactionTimeout)
        let session = SonySession(transport: link)
        session.log = { [weak self] in self?.log($0) }
        session.focusTimeout = options.focusTimeout
        let conn = Connection(id: nextConnectionID, name: name, link: link, session: session)
        nextConnectionID += 1
        link.onFatal = { [weak conn] error in conn?.fault("transaction failed: \(Self.describe(error))") }
        current = conn

        let t0 = ContinuousClock.now
        log("connecting to \(name) (connection #\(conn.id))")
        let openTimeout = options.openSessionTimeout
        try await withTimeout(openTimeout + .seconds(1), "the camera session to open") { [transport] in
            try await transport.openSession(timeout: openTimeout)
        }
        try await session.connect()
        let drained = try await session.drainStaleObjects()
        if drained > 0 { log("drained \(drained) stale object(s) left in camera RAM") }

        if options.disableLiveViewSettingEffect {
            do {
                let v = try await session.disableLiveViewSettingEffect()
                log("Live View Setting Effect is now \(v.map(String.init) ?? "?") (2 = Off)")
            } catch {
                // A refusal is a normal response; a transport failure has already faulted `conn`
                // and the next step will throw.
                log("Live View Setting Effect not changed (non-fatal): \(Self.describe(error))")
            }
        }
        try await session.waitForLiveView(timeout: options.liveViewStartTimeout)

        guard gen == generation, conn.isAlive else { throw CancellationError() }
        connectCount += 1
        log("ready: \(name) after \(SonySession.CaptureTiming.ms(ContinuousClock.now - t0))")
        setState(.ready(name: name))
        conn.liveViewTask = Task { [weak self] in await self?.runLiveView(conn) }
        return conn
    }

    /// Ends the current session (if any): faults it so every waiter and the live-view loop
    /// unwind, and closes the ICC session.
    private func teardown(_ reason: String) {
        if let conn = current {
            current = nil
            conn.fault(reason)
        }
        transport.closeSession()
    }

    // MARK: - Live view

    private func runLiveView(_ conn: Connection) async {
        var lastFrame = ContinuousClock.now
        var oddResponses = 0
        while conn.isAlive, !Task.isCancelled {
            do {
                if conn.liveViewHolds > 0 {
                    try await Task.sleep(for: .milliseconds(20))
                    lastFrame = .now
                    continue
                }
                if let jpeg = try await conn.session.liveViewFrame() {
                    lastFrame = .now
                    liveViewFramesFetched += 1
                    submitFrame(jpeg)
                    continue
                }
                liveViewNotReady += 1
            } catch is CancellationError {
                return
            } catch PTPError.deviceResponse(let code, _) {
                // Unexpected but not transport-level: treat as not-ready; the stall watchdog
                // below catches it if it persists.
                oddResponses += 1
                if oddResponses <= 5 || oddResponses % 100 == 0 {
                    log("live view: camera answered \(PTPResponseCode.name(code)) (\(hex16(code))) [\(oddResponses)]")
                }
            } catch {
                conn.fault("live view: \(Self.describe(error))")
                return
            }
            if ContinuousClock.now - lastFrame > options.liveViewStallTimeout {
                conn.fault("live view stalled (no frame for \(SonySession.CaptureTiming.ms(options.liveViewStallTimeout)))")
                return
            }
            try? await Task.sleep(for: options.liveViewRetryDelay)
        }
    }

    /// Decodes off the main actor, at most one decode in flight; frames arriving meanwhile
    /// replace each other so the display always gets the newest.
    private func submitFrame(_ jpeg: Data) {
        guard frames.subscriberCount > 0 else { return }
        if decodeInFlight {
            pendingJPEG = jpeg
            return
        }
        decodeInFlight = true
        Task {
            var next: Data? = jpeg
            while let j = next {
                let image = await Task.detached(priority: .userInitiated) { Self.decode(j) }.value
                if let image {
                    liveViewFramesDecoded += 1
                    frames.yield(image)
                }
                next = pendingJPEG
                pendingJPEG = nil
            }
            decodeInFlight = false
        }
    }

    nonisolated static func decode(_ jpeg: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        // Force the decode here rather than lazily on the main thread at first draw.
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: - Helpers

    private func setState(_ s: CameraConnectionState) {
        guard s != state else { return }
        state = s
        log("state → \(s)")
        states.yield(s)
    }

    private func log(_ message: String, _ level: OSLogType = .default) {
        Self.logger.log(level: level, "\(message, privacy: .public)")
        options.log(message)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as PTPError: return e.description
        case is CancellationError: return "cancelled"
        case let e as BoothCameraError: return "\(e)"
        default:
            let ns = error as NSError
            return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        }
    }
}

/// One camera session: its gated transport, protocol state and fault latch.
@MainActor
final class Connection {
    let id: Int
    let name: String
    let link: GatedTransport
    let session: SonySession
    private(set) var faultReason: String?
    private var faultWaiters: [CheckedContinuation<String, Never>] = []
    var liveViewTask: Task<Void, Never>?
    /// Set while the shutter button is half-pressed (by prepare or capture).
    var halfPressedAt: ContinuousClock.Instant?
    /// > 0 pauses the live-view loop (between transactions; the gate keeps them apart anyway).
    var liveViewHolds = 0
    private var prepareHolding = false

    var isAlive: Bool { faultReason == nil }

    init(id: Int, name: String, link: GatedTransport, session: SonySession) {
        self.id = id
        self.name = name
        self.link = link
        self.session = session
    }

    func beginPrepareHold() {
        guard !prepareHolding else { return }
        prepareHolding = true
        liveViewHolds += 1
    }

    func endPrepareHold() {
        guard prepareHolding else { return }
        prepareHolding = false
        liveViewHolds -= 1
    }

    /// Latches the first fault: poisons the gate, stops live view, wakes the supervisor.
    func fault(_ reason: String) {
        guard faultReason == nil else { return }
        faultReason = reason
        link.gate.invalidate(PTPError.notConnected)
        liveViewTask?.cancel()
        let w = faultWaiters
        faultWaiters.removeAll()
        w.forEach { $0.resume(returning: reason) }
    }

    func waitForFault() async -> String {
        if let faultReason { return faultReason }
        return await withCheckedContinuation { faultWaiters.append($0) }
    }
}
