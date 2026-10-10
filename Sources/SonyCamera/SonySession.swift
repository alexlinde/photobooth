import Foundation
import PTPKit

/// Sony PC Remote protocol on top of any `PTPTransport`. Sequences follow libgphoto2
/// (library.c:712-765 handshake, :3912 live view, :4980-5175 capture).
///
/// The capture sequence is exposed as individual steps so `SonyBoothCamera` can interleave
/// them with live view and the booth countdown; `capture()` composes them for the spike.
/// This type does no serialization of its own: the transport it is given must (see
/// `GatedTransport`).
@MainActor
public final class SonySession {
    public let transport: PTPTransport
    public var log: (String) -> Void = { print($0) }

    public private(set) var protocolVersion: UInt16 = 0
    public private(set) var properties: [UInt16: SonyPropertyDescriptor] = [:]
    public private(set) var connectedAt: ContinuousClock.Instant?

    /// Recent events from the camera; the capture steps watch this for ObjectAdded. Bounded
    /// because DevicePropChanged arrives continuously during a long-running session.
    private var events: [PTPEvent] = []
    private static let maxEvents = 64

    public init(transport: PTPTransport) {
        self.transport = transport
    }

    public func receive(_ event: PTPEvent) {
        events.append(event)
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
    }

    public func clearEvents() { events.removeAll() }

    var sawObjectAdded: Bool { events.contains { $0.code == PTPEventCode.sonyObjectAdded } }

    // MARK: - Handshake

    public func connect() async throws {
        try await transport.transact(PTPOperation.sonySDIOConnect, [1, 0, 0])
        try await transport.transact(PTPOperation.sonySDIOConnect, [2, 0, 0])

        // libgphoto2 retries up to 20 times until the camera returns a non-empty list.
        var info: (version: UInt16, properties: [UInt16], controls: [UInt16])?
        for attempt in 1...20 {
            let r = try await transport.transact(PTPOperation.sonyGetExtDeviceInfo, [SonyProtocol.version3, 1])
            if !r.data.isEmpty {
                info = try SonyExtDeviceInfo.parse(r.data)
                break
            }
            log("GetExtDeviceInfo returned no data (attempt \(attempt)); retrying")
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let info else { throw PTPError.handshakeFailed("GetExtDeviceInfo never returned data") }
        protocolVersion = info.version
        log("Sony protocol version \(hex16(info.version)), \(info.properties.count) properties, \(info.controls.count) controls")

        try await transport.transact(PTPOperation.sonySDIOConnect, [3, 0, 0])

        // libgphoto2 sets PriorityMode = 1 ("application") so the host, not the dials, wins.
        do {
            try await setControlA(SonyProperty.priorityMode, .int(1), type: PTPDataType.int8)
        } catch {
            log("PriorityMode not set (non-fatal): \(error)")
        }
        connectedAt = .now
        try await refreshProperties()
    }

    // MARK: - Properties

    @discardableResult
    public func refreshProperties() async throws -> [UInt16: SonyPropertyDescriptor] {
        let r = try await transport.transact(PTPOperation.sonyGetAllDevicePropData)
        let parsed = SonyPropertyParser.parse(r.data)
        if !parsed.isEmpty { properties = parsed }
        return parsed
    }

    public func currentValue(_ code: UInt16) -> UInt64? { properties[code]?.currentValue.uint64 }

    public func setControlA(_ code: UInt16, _ value: PTPValue, type: UInt16) async throws {
        try await transport.transact(PTPOperation.sonySetControlDeviceA, [UInt32(code)], outData: value.encoded(as: type))
    }

    public func setControlB(_ code: UInt16, _ value: PTPValue, type: UInt16) async throws {
        try await transport.transact(PTPOperation.sonySetControlDeviceB, [UInt32(code)], outData: value.encoded(as: type))
    }

    /// Tries to turn Live View Display "Setting Effect" off (config.c:7763: uint8, 1 On, 2 Off)
    /// so the preview isn't dark at strobe exposure. The ZV-E10 reports the property as
    /// display-only, so this may well be refused; callers treat failure as non-fatal.
    /// Returns the value read back afterwards.
    public func disableLiveViewSettingEffect() async throws -> UInt64? {
        try await setControlA(SonyProperty.liveViewSettingEffect, .uint(2), type: PTPDataType.uint8)
        try await refreshProperties()
        return currentValue(SonyProperty.liveViewSettingEffect)
    }

    // MARK: - Live view

    /// Waits until LiveViewStatus (0xD221) reports 1. Right after the handshake it reads 0, and a
    /// GetObject on the live-view handle in that state never completes (observed on ZV-E10).
    public func waitForLiveView(timeout: Duration = .seconds(10)) async throws {
        let t0 = ContinuousClock.now
        while ContinuousClock.now - t0 < timeout {
            try await refreshProperties()
            if currentValue(SonyProperty.liveViewStatus) == 1 {
                log("live view available after \(ContinuousClock.now - t0)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PTPError.timeout("live view to become available (LiveViewStatus 0xD221 = 1)")
    }

    /// Fetches one live-view JPEG. Returns nil when the camera isn't ready yet
    /// (InvalidObjectHandle / AccessDenied — "we get those when we are too fast").
    public func liveViewFrame() async throws -> Data? {
        let r = try await transport.send(PTPOperation.getObject, parameters: [SonyHandle.liveView], outData: nil)
        switch r.code {
        case PTPResponseCode.ok:
            return SonyLiveView.extractJPEG(from: r.data)
        case PTPResponseCode.invalidObjectHandle, PTPResponseCode.accessDenied, PTPResponseCode.deviceBusy:
            return nil
        default:
            throw PTPError.deviceResponse(code: r.code, operation: PTPOperation.getObject)
        }
    }

    // MARK: - Capture steps

    public struct CaptureTiming: CustomStringConvertible, Sendable {
        /// Time spent in the capture call waiting for AF (short if the half-press came earlier).
        public var focusWait: Duration = .zero
        public var focusResult = ""
        /// From the start of the capture call to the full press: the shutter lag a guest sees.
        public var toFullPress: Duration = .zero
        /// Full press held until the camera reported the image.
        public var hold: Duration = .zero
        public var releaseToReady: Duration = .zero
        public var download: Duration = .zero
        public var readySignal = ""
        public var total: Duration = .zero
        public init() {}
        public var description: String {
            "focus wait \(Self.ms(focusWait)) (\(focusResult)), call→full press \(Self.ms(toFullPress)), "
                + "hold \(Self.ms(hold)), release→ready \(Self.ms(releaseToReady)) (via \(readySignal)), "
                + "download \(Self.ms(download)), total \(Self.ms(total))"
        }
        static func ms(_ d: Duration) -> String {
            let c = d.components
            return String(format: "%.0f ms", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
        }
    }

    /// Default focus wait for `capture()`.
    public var focusTimeout: Duration = .seconds(3)

    /// libgphoto2 (library.c:4985-4995) waits ~3 s after connect before the first capture on a list
    /// of bodies that includes the ZV-E10.
    public func waitForPostConnectSettle(_ settle: Duration = .seconds(3)) async throws {
        guard let t = connectedAt else { return }
        while ContinuousClock.now - t < settle {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Drains any image left in camera RAM (ObjectInMemory >= 0x8000), or the next capture
    /// would download the wrong photo. Returns how many were drained.
    @discardableResult
    public func drainStaleObjects(maxObjects: Int = 5) async throws -> Int {
        var drained = 0
        for _ in 0..<maxObjects {
            try await refreshProperties()
            guard let pending = currentValue(SonyProperty.objectInMemory), pending >= 0x8000 else { break }
            log("stale object in camera RAM (ObjectInMemory \(hex32(UInt32(truncatingIfNeeded: pending)))), draining")
            _ = try await transport.transact(PTPOperation.getObjectInfo, [SonyHandle.capturedImage])
            _ = try await transport.transact(PTPOperation.getObject, [SonyHandle.capturedImage])
            drained += 1
        }
        return drained
    }

    public func halfPress() async throws {
        try await setControlB(SonyProperty.shutterHalfRelease, .uint(2), type: PTPDataType.uint16)
    }

    /// Polls FocusFound (0xD213) until AF settles or `deadline`. The camera is
    /// focus-priority: a full press before focus settles is silently ignored. libgphoto2 gives
    /// up after 1 s, which is too short in a dim room. Returns the last FocusFound value.
    public func waitForFocus(until deadline: ContinuousClock.Instant,
                             poll: Duration = .milliseconds(30)) async throws -> UInt64? {
        if currentValue(SonyProperty.focusMode) == 1 { return nil }  // manual focus: nothing to wait for
        var last: UInt64?
        let t0 = ContinuousClock.now
        repeat {
            try await refreshProperties()
            let f = currentValue(SonyProperty.focusFound)
            if f != last {
                log("FocusFound 0xD213 = \(f.map(String.init) ?? "nil") after \(SonySession.CaptureTiming.ms(ContinuousClock.now - t0))")
                last = f
            }
            // config.c:7782: 2 Focus Locked, 3 No Focus (low contrast), 6 Tracking Focused,
            // 7 Tracking No Focus. Any of these means AF has settled; fire either way.
            if let f, Self.focusSettled(f) { return f }
            try await Task.sleep(for: poll)
        } while ContinuousClock.now < deadline
        return last
    }

    nonisolated static func focusSettled(_ v: UInt64) -> Bool { [2, 3, 6, 7].contains(v) }

    /// Full press, held until the camera reports the image (ObjectAdded or ObjectInMemory
    /// >= 0x8000) or `maxHold`. Releasing earlier can lose the shot.
    public func fullPressAndHold(maxHold: Duration = .seconds(3),
                                 poll: Duration = .milliseconds(30)) async throws {
        try await setControlB(SonyProperty.shutterRelease, .uint(2), type: PTPDataType.uint16)
        let t0 = ContinuousClock.now
        while ContinuousClock.now - t0 < maxHold {
            if sawObjectAdded { return }
            try await refreshProperties()
            if let v = currentValue(SonyProperty.objectInMemory), v >= 0x8000 { return }
            try await Task.sleep(for: poll)
        }
    }

    /// Releases full press, then half press (library.c:5119-5125 order).
    public func releaseShutter() async throws {
        try await setControlB(SonyProperty.shutterRelease, .uint(1), type: PTPDataType.uint16)
        try await setControlB(SonyProperty.shutterHalfRelease, .uint(1), type: PTPDataType.uint16)
    }

    public func releaseHalfPress() async throws {
        try await setControlB(SonyProperty.shutterHalfRelease, .uint(1), type: PTPDataType.uint16)
    }

    /// Waits for ObjectInMemory >= 0x8000. Downloading below 0x8000 crashes the firmware per
    /// libgphoto2 (library.c:5156), so the property, not the event, gates the download.
    /// Returns a description of the signal(s) seen.
    public func waitForImage(timeout: Duration = .seconds(10),
                             poll: Duration = .milliseconds(50)) async throws -> String {
        let t0 = ContinuousClock.now
        while ContinuousClock.now - t0 < timeout {
            try await refreshProperties()
            if let v = currentValue(SonyProperty.objectInMemory), v >= 0x8000 {
                let prop = "ObjectInMemory=\(hex32(UInt32(truncatingIfNeeded: v)))"
                return sawObjectAdded ? "ObjectAdded event + \(prop)" : prop
            }
            try await Task.sleep(for: poll)
        }
        throw PTPError.captureFailed("camera never reported the image (no focus? strobe not ready?)")
    }

    public func downloadCapturedImage() async throws -> (data: Data, filename: String?) {
        let info = try await transport.transact(PTPOperation.getObjectInfo, [SonyHandle.capturedImage])
        let obj = try await transport.transact(PTPOperation.getObject, [SonyHandle.capturedImage])
        return (obj.data, Self.objectInfoFilename(info.data))
    }

    // MARK: - One-shot capture (spike)

    /// Fires the shutter and returns the full-resolution image bytes. Used by the spike;
    /// `SonyBoothCamera` composes the same steps with live view and countdown handling.
    public func capture() async throws -> (data: Data, filename: String?, timing: CaptureTiming) {
        var timing = CaptureTiming()
        let start = ContinuousClock.now
        try await waitForPostConnectSettle()
        try await drainStaleObjects()
        clearEvents()

        let pressStart = ContinuousClock.now
        try await halfPress()
        let fullPress: ContinuousClock.Instant
        do {
            let f = try await waitForFocus(until: pressStart + focusTimeout)
            timing.focusWait = ContinuousClock.now - pressStart
            timing.focusResult = f.map { "FocusFound=\($0)" } ?? "n/a"
            fullPress = ContinuousClock.now
            timing.toFullPress = fullPress - start
            try await fullPressAndHold()
        } catch {
            try? await releaseShutter()
            throw error
        }
        try await releaseShutter()
        let released = ContinuousClock.now
        timing.hold = released - fullPress

        timing.readySignal = try await waitForImage(timeout: .seconds(35))
        timing.releaseToReady = ContinuousClock.now - released

        let dlStart = ContinuousClock.now
        let (data, filename) = try await downloadCapturedImage()
        timing.download = ContinuousClock.now - dlStart
        timing.total = ContinuousClock.now - start
        return (data, filename, timing)
    }

    /// Pulls the filename out of an ObjectInfo dataset (fixed 52-byte header, then PTP string).
    static func objectInfoFilename(_ data: Data) -> String? {
        var r = PTPReader(data, offset: 52)
        return try? r.string()
    }
}
