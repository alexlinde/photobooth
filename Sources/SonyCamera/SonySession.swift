import Foundation
import PTPKit

/// Sony PC Remote protocol on top of any `PTPTransport`. Sequences follow libgphoto2
/// (library.c:712-765 handshake, :3912 live view, :4980-5175 capture).
@MainActor
public final class SonySession {
    public let transport: PTPTransport
    public var log: (String) -> Void = { print($0) }

    public private(set) var protocolVersion: UInt16 = 0
    public private(set) var properties: [UInt16: SonyPropertyDescriptor] = [:]
    public private(set) var connectedAt: ContinuousClock.Instant?

    /// Events from the camera; `capture()` watches this for ObjectAdded.
    private var events: [PTPEvent] = []

    public init(transport: PTPTransport) {
        self.transport = transport
    }

    public func receive(_ event: PTPEvent) { events.append(event) }

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

    // MARK: - Capture

    public struct CaptureTiming: CustomStringConvertible {
        public var focus: Duration = .zero
        public var pressToRelease: Duration = .zero
        public var releaseToReady: Duration = .zero
        public var download: Duration = .zero
        public var readySignal = ""
        public var description: String {
            "focus \(focus), press→release \(pressToRelease), release→ready \(releaseToReady) (via \(readySignal)), download \(download)"
        }
    }

    /// Fires the shutter and returns the full-resolution image bytes.
    public var focusTimeout: Duration = .seconds(3)

    public func capture() async throws -> (data: Data, filename: String?, timing: CaptureTiming) {
        var timing = CaptureTiming()

        // ZV-E10 is on libgphoto2's list of bodies needing ~3 s after connect before capture works.
        if let t = connectedAt {
            while ContinuousClock.now - t < .seconds(3) {
                try await Task.sleep(for: .milliseconds(200))
            }
        }

        // Drain any stale image left in camera RAM, or we'd download the wrong photo.
        for _ in 0..<5 {
            try await refreshProperties()
            guard let pending = currentValue(SonyProperty.objectInMemory), pending >= 0x8000 else { break }
            log("stale object in camera RAM (\(hex32(UInt32(pending)))), draining")
            _ = try await transport.transact(PTPOperation.getObjectInfo, [SonyHandle.capturedImage])
            _ = try await transport.transact(PTPOperation.getObject, [SonyHandle.capturedImage])
        }
        events.removeAll()

        let pressStart = ContinuousClock.now
        try await setControlB(SonyProperty.shutterHalfRelease, .uint(2), type: PTPDataType.uint16)

        // Half-press and wait for AF to settle. The camera is in focus-priority
        // AF-S, so a full press without focus lock is silently ignored. libgphoto2 gives up after
        // 1 s, which is too short in a dim room; the booth will half-press at countdown start.
        let manualFocus = currentValue(SonyProperty.focusMode) == 1
        var lastFocus: UInt64?
        if !manualFocus {
            while ContinuousClock.now - pressStart < focusTimeout {
                try await refreshProperties()
                let f = currentValue(SonyProperty.focusFound)
                if f != lastFocus {
                    log("FocusFound 0xD213 = \(f.map(String.init) ?? "nil") after \(ContinuousClock.now - pressStart)")
                    lastFocus = f
                }
                // config.c:7782: 2 Focus Locked, 3 No Focus (low contrast), 6 Tracking Focused,
                // 7 Tracking No Focus. Any of these means AF has settled; fire either way.
                if let f, [2, 3, 6, 7].contains(f) { break }
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        timing.focus = ContinuousClock.now - pressStart

        // Full press, held until the camera reports the image (or 3 s).
        try await setControlB(SonyProperty.shutterRelease, .uint(2), type: PTPDataType.uint16)
        let fullPress = ContinuousClock.now
        while ContinuousClock.now - fullPress < .seconds(3) {
            if events.contains(where: { $0.code == PTPEventCode.sonyObjectAdded }) { break }
            try await refreshProperties()
            if let v = currentValue(SonyProperty.objectInMemory), v >= 0x8000 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try await setControlB(SonyProperty.shutterRelease, .uint(1), type: PTPDataType.uint16)
        try await setControlB(SonyProperty.shutterHalfRelease, .uint(1), type: PTPDataType.uint16)
        let released = ContinuousClock.now
        timing.pressToRelease = released - pressStart

        // Wait for the image: ObjectAdded event or ObjectInMemory >= 0x8000.
        // (Downloading at value 1 crashes the firmware per libgphoto2 — wait for 0x8000.)
        var ready = false
        while ContinuousClock.now - released < .seconds(35) {
            if events.contains(where: { $0.code == PTPEventCode.sonyObjectAdded }) {
                timing.readySignal = "ObjectAdded event"
                // Still confirm via the property, which is what gates safe download.
            }
            try await refreshProperties()
            if let v = currentValue(SonyProperty.objectInMemory), v >= 0x8000 {
                if timing.readySignal.isEmpty { timing.readySignal = "ObjectInMemory=\(hex32(UInt32(v)))" }
                else { timing.readySignal += " + ObjectInMemory=\(hex32(UInt32(v)))" }
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard ready else { throw PTPError.captureFailed("camera never reported the image (no focus? strobe not ready?)") }
        timing.releaseToReady = ContinuousClock.now - released

        let dlStart = ContinuousClock.now
        let info = try await transport.transact(PTPOperation.getObjectInfo, [SonyHandle.capturedImage])
        let filename = Self.objectInfoFilename(info.data)
        let obj = try await transport.transact(PTPOperation.getObject, [SonyHandle.capturedImage])
        timing.download = ContinuousClock.now - dlStart
        return (obj.data, filename, timing)
    }

    /// Pulls the filename out of an ObjectInfo dataset (fixed 52-byte header, then PTP string).
    static func objectInfoFilename(_ data: Data) -> String? {
        var r = PTPReader(data, offset: 52)
        return try? r.string()
    }
}
