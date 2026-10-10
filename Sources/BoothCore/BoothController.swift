import CoreGraphics
import Foundation
import Observation
import SonyCamera

/// Settings the state machine needs (a subset of `BoothConfig`, in seconds).
public struct BoothSettings: Equatable, Sendable {
    var countdownSeconds = 3
    var reviewSeconds = 5.0
    var shotsPerPress = 1
    var pauseBetweenShotsSeconds = 2.0
    /// Three photos per press, built into a strip and printed (`shotsPerPress` is ignored).
    var stripMode = false
    var debounceSeconds = 0.4
    /// How long the "Oops" message stays up after a failed capture.
    var noticeSeconds = 3.0
    /// Consecutive capture failures before the attendant screen.
    var maxConsecutiveFailures = 3
    /// Retry interval for saving photos while on the storage attendant screen.
    var storageRetrySeconds = 15.0

    init() {}

    public init(_ c: BoothConfig) {
        countdownSeconds = c.countdownSeconds
        reviewSeconds = c.reviewSeconds
        shotsPerPress = c.shotsPerPress
        pauseBetweenShotsSeconds = c.pauseBetweenShotsSeconds
        stripMode = c.stripMode
        debounceSeconds = c.debounce
    }

    /// Strip mode: each photo's full-screen review (at most `reviewSeconds`) before it flies
    /// into its slot. No pause between shots: the review and the fly-in are the breather.
    public static let stripShotReviewSeconds = 2.5
    /// Strip mode: how long the photo takes to fly from the review into its slot on the strip.
    public static let stripFlyInSeconds = 0.8

    var shotReviewSeconds: Double { stripMode ? min(reviewSeconds, Self.stripShotReviewSeconds) : reviewSeconds }
}

/// Why the attendant is needed.
public enum AttendantIssue: Equatable, Sendable {
    case config(String)
    case captureFailures(String)
    case storage(String)
    case inputPermission(String)
    case other(String)

    public var title: String {
        switch self {
        case .config: return "Settings problem"
        case .captureFailures: return "The camera isn't taking photos"
        case .storage: return "Photos can't be saved"
        case .inputPermission: return "Button permission needed"
        case .other: return "Attendant needed"
        }
    }

    public var detail: String {
        switch self {
        case .config(let s), .captureFailures(let s), .storage(let s), .inputPermission(let s), .other(let s): return s
        }
    }

    var kind: String {
        switch self {
        case .config: return "config"
        case .captureFailures: return "captureFailures"
        case .storage: return "storage"
        case .inputPermission: return "inputPermission"
        case .other: return "other"
        }
    }
}

/// A captured photo ready for the review screen.
public struct ReviewPhoto: Equatable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    /// Downsampled to screen size off the main thread (nil if decoding failed).
    public let image: CGImage?
    public static func == (a: ReviewPhoto, b: ReviewPhoto) -> Bool { a.id == b.id }

    public init(url: URL, image: CGImage?) {
        self.url = url
        self.image = image
    }
}

public enum BoothState: Equatable {
    case waitingForCamera(status: String)
    case idle
    case countdown(remaining: Int, shot: Int, of: Int)
    case capturing(shot: Int, of: Int)
    case review(ReviewPhoto, shot: Int, of: Int)
    /// Pause between shots of a multi-shot press (not in strip mode).
    case betweenShots(next: Int, of: Int)
    /// Strip mode: the reviewed photo shrinks into its slot on the strip (`stripFlyInSeconds`).
    case flyIn(ReviewPhoto, shot: Int, of: Int)
    /// Strip mode: the finished strip, large, while it prints (`reviewSeconds`).
    case stripReview([ReviewPhoto])
    /// Brief friendly message (e.g. after a failed capture), then back to idle.
    case notice(String)
    case attendant(AttendantIssue)
    /// Paused by the attendant (control panel): "Back in a moment", presses ignored.
    case paused

    /// Compact label for logs and the self-test.
    public var label: String {
        switch self {
        case .waitingForCamera: return "waiting"
        case .idle: return "idle"
        case let .countdown(r, k, n): return "countdown(\(r),\(k)/\(n))"
        case let .capturing(k, n): return "capturing(\(k)/\(n))"
        case let .review(_, k, n): return "review(\(k)/\(n))"
        case let .betweenShots(k, n): return "between(\(k)/\(n))"
        case let .flyIn(_, k, n): return "flyin(\(k)/\(n))"
        case .stripReview: return "strip-review"
        case .notice: return "notice"
        case .attendant(let i): return "attendant(\(i.kind))"
        case .paused: return "paused"
        }
    }
}

public enum PressResult: Equatable {
    case accepted
    case debounced
    case ignored(String)
}

/// The booth state machine. Pure logic: no AppKit/SwiftUI; time comes from an injected
/// `BoothClock`, photos go to an injected `PhotoSink`, review images come from an injected
/// decoder. Views observe `state`.
@MainActor
@Observable
public final class BoothController {
    public typealias ReviewDecoder = @Sendable (Data) async -> CGImage?

    public private(set) var state: BoothState
    private(set) var cameraState: CameraConnectionState
    /// Non-blocking notice shown small at the bottom (e.g. "Using keyboard fallback").
    public var inputBanner: String?
    /// Set when the configured button device is missing (HID device filter).
    public var buttonStatus: String?
    /// Paused from the control panel. While paused the state is `.paused` (except while a
    /// capture already in flight finishes and saves).
    public private(set) var isPaused = false
    /// Strip mode: the photos taken so far this press, in slot order (top first). Cleared when the
    /// session ends or is aborted (the files stay saved).
    public private(set) var stripPhotos: [ReviewPhoto] = []
    /// Strip mode: replaces "Printing your strip…" under the finished strip (set by the app when
    /// it can't print). Cleared at the start of each press.
    public var stripMessage: String?

    @ObservationIgnored public var settings: BoothSettings
    @ObservationIgnored public var sink: PhotoSink
    @ObservationIgnored public var onStateChange: ((BoothState) -> Void)?
    /// Strip mode: called once per finished strip with its three saved photos, top to bottom.
    /// The app renders and prints the sheet; an aborted strip never gets here.
    @ObservationIgnored public var onStripComplete: (([URL]) -> Void)?

    @ObservationIgnored private let camera: BoothCamera
    @ObservationIgnored private let clock: BoothClock
    @ObservationIgnored private let decodeForReview: ReviewDecoder
    @ObservationIgnored private var lastRawPress: Date?
    @ObservationIgnored private(set) var consecutiveFailures = 0
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var sessionID = 0
    @ObservationIgnored private var cameraTask: Task<Void, Never>?
    @ObservationIgnored private var storageRetryTask: Task<Void, Never>?
    @ObservationIgnored private(set) var unsavedPhotos: [CapturedPhoto] = []
    @ObservationIgnored private var cameraDroppedSinceAttendant = false
    @ObservationIgnored private var prepareOutstanding = false
    @ObservationIgnored private(set) var savedURLs: [URL] = []

    public init(camera: BoothCamera, sink: PhotoSink, clock: BoothClock, settings: BoothSettings,
         decodeForReview: @escaping ReviewDecoder) {
        self.camera = camera
        self.sink = sink
        self.clock = clock
        self.settings = settings
        self.decodeForReview = decodeForReview
        self.cameraState = camera.state
        self.state = .waitingForCamera(status: Self.statusText(camera.state))
    }

    // MARK: Lifecycle

    public func start() {
        guard cameraTask == nil else { return }
        let stream = camera.stateUpdates()
        cameraTask = Task { [weak self] in
            for await s in stream {
                guard let self else { return }
                self.cameraStateChanged(s)
            }
        }
        camera.start()
        BoothLog.info(.booth, "Booth started; camera state \(camera.state)")
    }

    public func stop() {
        sessionTask?.cancel()
        cameraTask?.cancel()
        storageRetryTask?.cancel()
        cameraTask = nil
        camera.stop()
    }

    // MARK: Inputs

    /// The guest button. Debounced; ignored outside idle.
    @discardableResult
    public func buttonPressed() -> PressResult {
        let now = clock.now()
        if let last = lastRawPress, now.timeIntervalSince(last) < settings.debounceSeconds {
            BoothLog.debug(.input, "Press debounced")
            return .debounced
        }
        lastRawPress = now
        guard case .idle = state else {
            BoothLog.info(.input, "Press ignored in state \(state.label)")
            return .ignored(state.label)
        }
        guard camera.state.isReady else {
            // Shouldn't happen (idle implies ready), but be safe.
            set(.waitingForCamera(status: Self.statusText(camera.state)))
            return .ignored("camera not ready")
        }
        BoothLog.info(.booth, settings.stripMode ? "Button pressed: starting a strip (\(PrintLayout.photosPerStrip) shots)"
                                                 : "Button pressed: starting \(settings.shotsPerPress)-shot session")
        sessionID += 1
        let id = sessionID
        sessionTask = Task { [weak self] in await self?.runSession(id: id) }
        return .accepted
    }

    /// Pause the booth (control panel). A countdown or review in progress is aborted cleanly
    /// (half-press released); a capture already in flight is saved first. Attendant issues
    /// raised while paused wait in `attendantIssue` and show on resume.
    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        BoothLog.info(.booth, "Booth paused (state \(state.label))")
        switch state {
        case .capturing:
            break // runSession saves the photo, then lands on .paused via returnToIdle().
        case .countdown, .betweenShots, .review, .flyIn, .stripReview, .notice:
            abortSession()
            set(.paused)
        case .attendant(let issue):
            storageRetryTask?.cancel()
            pendingAttendant = issue
            set(.paused)
        case .idle, .waitingForCamera:
            set(.paused)
        case .paused:
            break
        }
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        BoothLog.info(.booth, "Booth resumed")
        if case .paused = state { returnToIdle() }
    }

    /// The issue on the attendant screen, or one waiting to be shown (deferred mid-session,
    /// or raised while paused). For the control panel.
    public var attendantIssue: AttendantIssue? {
        if case .attendant(let i) = state { return i }
        return pendingAttendant
    }

    /// Attendant key: retry/clear the current attendant issue.
    public func attendantReset() {
        if case .paused = state, let issue = pendingAttendant {
            // Paused with an issue waiting: clear it (storage first retries its unsaved photos).
            BoothLog.info(.booth, "Attendant reset while paused (\(issue.kind))")
            if case .storage = issue {
                Task {
                    await self.retryUnsaved()
                    if self.unsavedPhotos.isEmpty, case .storage = self.pendingAttendant { self.pendingAttendant = nil }
                }
            } else {
                consecutiveFailures = 0
                pendingAttendant = nil
            }
            return
        }
        guard case .attendant(let issue) = state else { return }
        BoothLog.info(.booth, "Attendant reset (\(issue.kind))")
        switch issue {
        case .storage:
            Task { await self.retryUnsaved() }
        default:
            consecutiveFailures = 0
            returnToIdle()
        }
    }

    /// Show the attendant screen for an external cause (config, input permission, ...).
    /// Ignored mid-session; the caller may retry later.
    public func raiseAttendant(_ issue: AttendantIssue) {
        switch state {
        case .countdown, .capturing, .review, .betweenShots, .flyIn, .stripReview:
            BoothLog.info(.booth, "Deferring attendant (\(issue.kind)) until session ends")
            pendingAttendant = issue
            return
        default:
            enterAttendant(issue)
        }
    }
    private var pendingAttendant: AttendantIssue?

    /// Clears an attendant issue of the given kind when its cause has resolved.
    public func resolveAttendant(kind: String) {
        if pendingAttendant?.kind == kind { pendingAttendant = nil }
        if case .attendant(let i) = state, i.kind == kind {
            BoothLog.info(.booth, "Attendant issue \(kind) resolved")
            returnToIdle()
        }
    }

    // MARK: Camera state

    private func cameraStateChanged(_ s: CameraConnectionState) {
        let wasReady = cameraState.isReady
        cameraState = s
        if wasReady != s.isReady || !s.isReady { BoothLog.info(.camera, "Camera state: \(s)") }
        switch state {
        case .waitingForCamera:
            if s.isReady { set(.idle) } else { set(.waitingForCamera(status: Self.statusText(s))) }
        case .idle:
            if !s.isReady { set(.waitingForCamera(status: Self.statusText(s))) }
        case .countdown, .betweenShots:
            if !s.isReady {
                BoothLog.info(.booth, "Camera lost during countdown; aborting session")
                abortSession()
                set(.waitingForCamera(status: Self.statusText(s)))
            }
        case .capturing, .review, .flyIn, .stripReview, .notice:
            break // finishes on its own; returnToIdle() checks readiness.
        case .attendant(let issue):
            if !s.isReady { cameraDroppedSinceAttendant = true }
            if case .captureFailures = issue, s.isReady, cameraDroppedSinceAttendant {
                // The camera reconnected: the likely cause is fixed.
                BoothLog.info(.booth, "Camera reconnected; clearing capture-failure attendant screen")
                consecutiveFailures = 0
                returnToIdle()
            }
        case .paused:
            break // resume() picks idle or waiting from the camera state at that point.
        }
    }

    static func statusText(_ s: CameraConnectionState) -> String {
        switch s {
        case .searching: return "Looking for the camera…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .ready(let name): return "\(name) ready"
        case .recovering(let reason): return "Reconnecting… (\(reason))"
        }
    }

    // MARK: Session

    private func isCurrent(_ id: Int) -> Bool { id == sessionID && !Task.isCancelled }

    private func abortSession() {
        discardStrip()
        sessionID += 1
        sessionTask?.cancel()
        sessionTask = nil
        if prepareOutstanding {
            prepareOutstanding = false
            Task { await camera.cancelPrepare() }
        }
    }

    private func runSession(id: Int) async {
        let strip = settings.stripMode
        let n = strip ? PrintLayout.photosPerStrip : max(1, settings.shotsPerPress)
        stripPhotos = []
        stripMessage = nil
        do {
            var shot = 1
            // Strip mode retries a failed shot (after the "Oops" notice) instead of ending the press.
            var retrying = false
            while shot <= n {
                if shot > 1, !strip, !retrying {
                    set(.betweenShots(next: shot, of: n))
                    try await clock.sleep(seconds: settings.pauseBetweenShotsSeconds)
                    guard isCurrent(id) else { return }
                    guard camera.state.isReady else { returnToIdle(); return }
                }
                retrying = false
                // Countdown, with half-press at its start so AF has settled at the end.
                prepareOutstanding = true
                let prepare = Task { await camera.prepareCapture() }
                for remaining in stride(from: settings.countdownSeconds, through: 1, by: -1) {
                    set(.countdown(remaining: remaining, shot: shot, of: n))
                    try await clock.sleep(seconds: 1)
                    guard isCurrent(id) else { return }
                }
                await prepare.value
                guard isCurrent(id) else { return }
                prepareOutstanding = false

                set(.capturing(shot: shot, of: n))
                let photo: CapturedPhoto
                do {
                    photo = try await camera.capture()
                } catch {
                    guard id == sessionID else { return }
                    if await captureFailed(error, id: id, retry: strip) {
                        retrying = true
                        continue
                    }
                    return
                }
                guard id == sessionID else { return }
                consecutiveFailures = 0
                BoothLog.info(.booth, "Captured shot \(shot)/\(n): \(photo.jpeg.count) bytes (\(photo.cameraFilename ?? "?"))")

                // Save first (source of truth) while decoding the review image in parallel.
                let decode = decodeForReview
                let jpeg = photo.jpeg
                let decodeTask = Task.detached(priority: .userInitiated) { await decode(jpeg) }
                let url: URL
                do {
                    url = try await sink.store(photo)
                } catch {
                    decodeTask.cancel()
                    guard id == sessionID else { return }
                    BoothLog.error(.storage, "Saving photo failed: \(error)")
                    unsavedPhotos.append(photo)
                    enterAttendant(.storage(Self.describe(error)))
                    return
                }
                savedURLs.append(url)
                BoothLog.info(.storage, "Saved \(url.path)")
                if isPaused {
                    // Paused while this shot was in flight: it's saved; skip review and the rest.
                    decodeTask.cancel()
                    returnToIdle()
                    return
                }
                let image = await decodeTask.value
                guard id == sessionID else { return }
                let review = ReviewPhoto(url: url, image: image)
                set(.review(review, shot: shot, of: n))
                try await clock.sleep(seconds: settings.shotReviewSeconds)
                guard isCurrent(id) else { return }
                if strip {
                    set(.flyIn(review, shot: shot, of: n))
                    try await clock.sleep(seconds: BoothSettings.stripFlyInSeconds)
                    guard isCurrent(id) else { return }
                    // Landed: the slot takes over from the flying photo in the same update.
                    stripPhotos.append(review)
                    if shot == n {
                        BoothLog.info(.booth, "Strip complete: \(stripPhotos.map(\.url.lastPathComponent))")
                        set(.stripReview(stripPhotos))
                        onStripComplete?(stripPhotos.map(\.url))
                        try await clock.sleep(seconds: settings.reviewSeconds)
                        guard isCurrent(id) else { return }
                    } else if !camera.state.isReady {
                        returnToIdle()  // camera lost during the review: the strip is abandoned
                        return
                    }
                }
                shot += 1
            }
            returnToIdle()
        } catch {
            // Cancelled (camera lost during countdown): abortSession() already set state.
            BoothLog.debug(.booth, "Session \(id) ended: \(error)")
        }
    }

    /// Returns true when the session should try the same shot again (strip mode, after the
    /// notice); otherwise the session is over (idle, paused or attendant).
    private func captureFailed(_ error: Error, id: Int, retry: Bool) async -> Bool {
        let cameraOK = camera.state.isReady
        if cameraOK { consecutiveFailures += 1 }
        BoothLog.error(.camera, "Capture failed (\(consecutiveFailures) in a row, camera \(camera.state)): \(error)")
        if isPaused, consecutiveFailures < settings.maxConsecutiveFailures {
            returnToIdle()
            return false
        }
        if consecutiveFailures >= settings.maxConsecutiveFailures {
            enterAttendant(.captureFailures("\(consecutiveFailures) photos in a row failed. Last error: \(Self.describe(error)). Check the camera (battery, memory card, lens cap, settings)."))
            return false
        }
        set(.notice("Oops — let's try that again"))
        do { try await clock.sleep(seconds: settings.noticeSeconds) } catch { return false }
        guard id == sessionID else { return false }
        if retry, case .notice = state, !isPaused, camera.state.isReady {
            BoothLog.info(.booth, "Retrying the shot")
            return true
        }
        returnToIdle()
        return false
    }

    /// Strip mode: forget the photos taken so far (the files stay saved; nothing prints).
    private func discardStrip() {
        guard !stripPhotos.isEmpty else { return }
        if case .stripReview = state {} else {
            BoothLog.info(.booth, "Strip abandoned with \(stripPhotos.count) of \(PrintLayout.photosPerStrip) photos (they stay saved)")
        }
        stripPhotos = []
    }

    // MARK: Attendant / storage

    private func enterAttendant(_ issue: AttendantIssue) {
        BoothLog.error(.booth, "Attendant needed: \(issue.title) — \(issue.detail)")
        if isPaused {
            // Stays on "Back in a moment"; the panel shows the issue and resume() raises it.
            pendingAttendant = issue
            set(.paused)
            return
        }
        discardStrip()
        cameraDroppedSinceAttendant = false
        set(.attendant(issue))
        if case .storage = issue { scheduleStorageRetry() }
    }

    private func scheduleStorageRetry() {
        storageRetryTask?.cancel()
        storageRetryTask = Task { [weak self] in
            while let self, case .attendant(.storage) = self.state {
                do { try await self.clock.sleep(seconds: self.settings.storageRetrySeconds) } catch { return }
                guard case .attendant(.storage) = self.state else { return }
                await self.retryUnsaved()
            }
        }
    }

    @ObservationIgnored private var retryingUnsaved = false

    private func retryUnsaved() async {
        guard !retryingUnsaved else { return }
        retryingUnsaved = true
        defer { retryingUnsaved = false }
        while let photo = unsavedPhotos.first {
            do {
                let url = try await sink.store(photo)
                unsavedPhotos.removeFirst()
                savedURLs.append(url)
                BoothLog.info(.storage, "Saved previously unsaved photo to \(url.path)")
            } catch {
                BoothLog.error(.storage, "Retry save failed: \(error)")
                if case .attendant(.storage) = state {
                    set(.attendant(.storage(Self.describe(error))))
                }
                return
            }
        }
        if case .attendant(.storage) = state {
            storageRetryTask?.cancel()
            returnToIdle()
        }
    }

    private func returnToIdle() {
        discardStrip()
        if isPaused {
            set(.paused)
            return
        }
        if let issue = pendingAttendant {
            pendingAttendant = nil
            enterAttendant(issue)
            return
        }
        if camera.state.isReady { set(.idle) } else { set(.waitingForCamera(status: Self.statusText(camera.state))) }
    }

    private func set(_ s: BoothState) {
        guard s != state else { return }
        if s.label != state.label { BoothLog.info(.booth, "State: \(state.label) → \(s.label)") }
        state = s
        onStateChange?(s)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? BoothCameraError {
            switch e {
            case .notReady: return "camera not ready"
            case .captureInProgress: return "a capture was already in progress"
            case .captureFailed(let s): return s
            }
        }
        return (error as NSError).localizedDescription
    }
}
