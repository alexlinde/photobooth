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
        debounceSeconds = c.debounce
    }
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
}

public enum BoothState: Equatable {
    case waitingForCamera(status: String)
    case idle
    case countdown(remaining: Int, shot: Int, of: Int)
    case capturing(shot: Int, of: Int)
    case review(ReviewPhoto, shot: Int, of: Int)
    /// Pause between shots of a multi-shot press.
    case betweenShots(next: Int, of: Int)
    /// Brief friendly message (e.g. after a failed capture), then back to idle.
    case notice(String)
    case attendant(AttendantIssue)

    /// Compact label for logs and the self-test.
    public var label: String {
        switch self {
        case .waitingForCamera: return "waiting"
        case .idle: return "idle"
        case let .countdown(r, k, n): return "countdown(\(r),\(k)/\(n))"
        case let .capturing(k, n): return "capturing(\(k)/\(n))"
        case let .review(_, k, n): return "review(\(k)/\(n))"
        case let .betweenShots(k, n): return "between(\(k)/\(n))"
        case .notice: return "notice"
        case .attendant(let i): return "attendant(\(i.kind))"
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

    @ObservationIgnored public var settings: BoothSettings
    @ObservationIgnored public var sink: PhotoSink
    @ObservationIgnored public var onStateChange: ((BoothState) -> Void)?

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
        BoothLog.info(.booth, "Button pressed: starting \(settings.shotsPerPress)-shot session")
        sessionID += 1
        let id = sessionID
        sessionTask = Task { [weak self] in await self?.runSession(id: id) }
        return .accepted
    }

    /// Attendant key: retry/clear the current attendant issue.
    public func attendantReset() {
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
        case .countdown, .capturing, .review, .betweenShots:
            BoothLog.info(.booth, "Deferring attendant (\(issue.kind)) until session ends")
            pendingAttendant = issue
            return
        default:
            enterAttendant(issue)
        }
    }
    @ObservationIgnored private var pendingAttendant: AttendantIssue?

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
        case .capturing, .review, .notice:
            break // finishes on its own; returnToIdle() checks readiness.
        case .attendant(let issue):
            if !s.isReady { cameraDroppedSinceAttendant = true }
            if case .captureFailures = issue, s.isReady, cameraDroppedSinceAttendant {
                // The camera reconnected: the likely cause is fixed.
                BoothLog.info(.booth, "Camera reconnected; clearing capture-failure attendant screen")
                consecutiveFailures = 0
                returnToIdle()
            }
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
        sessionID += 1
        sessionTask?.cancel()
        sessionTask = nil
        if prepareOutstanding {
            prepareOutstanding = false
            Task { await camera.cancelPrepare() }
        }
    }

    private func runSession(id: Int) async {
        let n = max(1, settings.shotsPerPress)
        do {
            for shot in 1...n {
                if shot > 1 {
                    set(.betweenShots(next: shot, of: n))
                    try await clock.sleep(seconds: settings.pauseBetweenShotsSeconds)
                    guard isCurrent(id) else { return }
                    guard camera.state.isReady else { returnToIdle(); return }
                }
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
                var photo: CapturedPhoto
                do {
                    photo = try await camera.capture()
                } catch {
                    guard id == sessionID else { return }
                    await captureFailed(error, id: id)
                    return
                }
                guard id == sessionID else { return }
                consecutiveFailures = 0
                let original = photo.jpeg
                photo.jpeg = await Task.detached(priority: .userInitiated) { JPEGOrientation.upright(original) }.value
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
                let image = await decodeTask.value
                guard id == sessionID else { return }
                set(.review(ReviewPhoto(url: url, image: image), shot: shot, of: n))
                try await clock.sleep(seconds: settings.reviewSeconds)
                guard isCurrent(id) else { return }
            }
            returnToIdle()
        } catch {
            // Cancelled (camera lost during countdown): abortSession() already set state.
            BoothLog.debug(.booth, "Session \(id) ended: \(error)")
        }
    }

    private func captureFailed(_ error: Error, id: Int) async {
        let cameraOK = camera.state.isReady
        if cameraOK { consecutiveFailures += 1 }
        BoothLog.error(.camera, "Capture failed (\(consecutiveFailures) in a row, camera \(camera.state)): \(error)")
        if consecutiveFailures >= settings.maxConsecutiveFailures {
            enterAttendant(.captureFailures("\(consecutiveFailures) photos in a row failed. Last error: \(Self.describe(error)). Check the camera (battery, memory card, lens cap, settings)."))
            return
        }
        set(.notice("Oops — let's try that again"))
        do { try await clock.sleep(seconds: settings.noticeSeconds) } catch { return }
        guard id == sessionID else { return }
        returnToIdle()
    }

    // MARK: Attendant / storage

    private func enterAttendant(_ issue: AttendantIssue) {
        BoothLog.error(.booth, "Attendant needed: \(issue.title) — \(issue.detail)")
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
