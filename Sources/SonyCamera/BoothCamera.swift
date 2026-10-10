import CoreGraphics
import Foundation

/// Connection lifecycle as seen by the booth UI.
public enum CameraConnectionState: Sendable, Equatable {
    /// Browsing for a camera; none found yet (or it went away and we're waiting for it).
    case searching
    /// Camera found; opening session / handshake / waiting for live view.
    case connecting(name: String)
    /// Ready: live view flowing, capture allowed.
    case ready(name: String)
    /// Something went wrong; the camera layer is retrying on its own. `reason` is for the
    /// attendant screen / logs.
    case recovering(reason: String)

    public var isReady: Bool { if case .ready = self { return true } else { return false } }
}

/// A captured full-resolution photo, exactly as the camera produced it.
public struct CapturedPhoto: Sendable {
    public var jpeg: Data
    /// Camera's own filename, e.g. "DSC01028.JPG", when reported.
    public var cameraFilename: String?
    public var capturedAt: Date

    public init(jpeg: Data, cameraFilename: String?, capturedAt: Date) {
        self.jpeg = jpeg
        self.cameraFilename = cameraFilename
        self.capturedAt = capturedAt
    }
}

public enum BoothCameraError: Error, Sendable, Equatable {
    case notReady
    case captureInProgress
    case captureFailed(String)
}

/// The camera API the booth UI is written against. `SonyBoothCamera` is the real
/// implementation; the UI also ships a fake for running without hardware.
///
/// Contract:
/// - `start()` begins discovery and keeps the camera connected forever: on unplug, power-off
///   or protocol errors it tears down and reconnects by itself, publishing state changes.
/// - Live view runs continuously while `.ready`, except while a capture is in flight.
/// - `prepareCapture()` is called at countdown start: half-press so AF has settled by the
///   time `capture()` is called. Safe to call when not ready (no-op).
/// - `capture()` fires the shutter (releasing the half-press) and returns the image. It
///   throws `notReady` if not `.ready`, `captureInProgress` if called concurrently.
/// - `cancelPrepare()` releases a half-press without firing (e.g. countdown aborted).
/// - `setProfile(_:)` stores the profile; it is applied on every (re)connect and, if the
///   camera is ready, straight away (after any capture in flight). Results are published
///   through `status` / `statusUpdates()`. Applying a profile never faults the connection:
///   settings the camera refuses are reported, not thrown.
@MainActor
public protocol BoothCamera: AnyObject {
    var state: CameraConnectionState { get }
    /// Emits the current state immediately, then every change. Multiple subscribers allowed.
    func stateUpdates() -> AsyncStream<CameraConnectionState>
    /// Latest live-view frames. Slow consumers get the newest frame (older ones dropped).
    /// Multiple subscribers allowed. The stream stays open across reconnects.
    func liveViewFrames() -> AsyncStream<CGImage>

    func start()
    func stop()

    func prepareCapture() async
    func cancelPrepare() async
    func capture() async throws -> CapturedPhoto

    var status: CameraStatus { get }
    /// Emits the current status immediately, then every change. Multiple subscribers allowed.
    func statusUpdates() -> AsyncStream<CameraStatus>
    func setProfile(_ profile: CameraProfile?)
}
