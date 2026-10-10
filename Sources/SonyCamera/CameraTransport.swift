import Foundation
import PTPKit

/// Everything `SonyBoothCamera`'s supervisor needs from the device layer: discovery, session
/// lifecycle, raw PTP transactions and events. `ICCTransport` implements it over
/// ImageCaptureCore; tests use a scripted fake, so the supervisor never touches ICC types.
///
/// Implementations do not need to serialize or time out transactions themselves;
/// `GatedTransport` does both. They must, however, deliver callbacks on the main actor.
@MainActor
public protocol CameraTransport: PTPTransport {
    var onEvent: (@MainActor (PTPEvent) -> Void)? { get set }
    /// Called when the device with the open session goes away (unplug, power-off).
    var onDisconnect: (@MainActor () -> Void)? { get set }
    var traceTransactions: Bool { get set }

    /// Waits up to `timeout` for a camera that accepts PTP pass-through and selects it for
    /// `openSession`. Returns its display name. Throws `PTPError.noCameraFound` on timeout.
    func findCamera(timeout: Duration) async throws -> String
    /// Opens a session on the camera selected by `findCamera`.
    func openSession(timeout: Duration) async throws
    /// Closes the session (if any). Idempotent; never throws.
    func closeSession()
    /// Name of a still-image (PTP class) USB device that is physically attached, if any. Used
    /// to tell "nothing plugged in" apart from "plugged in but ImageCaptureCore won't hand it
    /// to us" (the Removable Volumes privacy permission).
    func attachedUSBCameraName() -> String?
}
