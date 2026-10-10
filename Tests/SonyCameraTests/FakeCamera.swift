import CoreGraphics
import Foundation
import ImageIO
@testable import PTPKit
@testable import SonyCamera

/// A scripted Sony body behind the `CameraTransport` protocol. It models just enough of the
/// ZV-E10 for the supervisor and capture logic: LiveViewStatus that turns on after a few
/// property polls (and a live-view GetObject that hangs before that, like the real one), AF
/// that locks a few polls after a half-press, an image that appears after a full press, and
/// the stale-object rule. It records every transaction and flags any overlap or rule breach.
///
/// Profile properties (`settings`) behave like the ZV-E10's: a SetControlDeviceA write shows up
/// in GetAllDevicePropData only after `readbackLag` (`modeReadbackLag` for the exposure mode);
/// exposure settings are display-only (isEnabled 2, empty enum) in Intelligent Auto and writes
/// to them are silently ignored, as are writes sent while a mode change is still settling.
@MainActor
final class FakeCamera: CameraTransport {
    struct Call: CustomStringConvertible {
        var code: UInt16
        var parameters: [UInt32]
        var outData: Data?
        var value: UInt64? { outData.map { d in d.reversed().reduce(0) { $0 << 8 | UInt64($1) } } }
        var description: String {
            "\(PTPOperation.name(code))(\(parameters.map(hex32).joined(separator: ",")))" + (value.map { "=\($0)" } ?? "")
        }
        func isControlB(_ prop: UInt16, _ v: UInt64) -> Bool {
            code == PTPOperation.sonySetControlDeviceB && parameters == [UInt32(prop)] && value == v
        }
        var isLiveView: Bool { code == PTPOperation.getObject && parameters == [SonyHandle.liveView] }
        var isPhotoDownload: Bool { code == PTPOperation.getObject && parameters == [SonyHandle.capturedImage] }
    }

    enum Injection {
        case fail(Error)
        case respond(UInt16)
        case hang
    }

    // CameraTransport
    var onEvent: (@MainActor (PTPEvent) -> Void)?
    var onDisconnect: (@MainActor () -> Void)?
    var traceTransactions = false

    // Scripting
    var name = "Fake ZV-E10"
    var cameraAvailable = true
    var usbAttached = false
    var openHangs = 0
    var latency: Duration = .milliseconds(1)
    var readbackLag: Duration = .milliseconds(20)
    var modeReadbackLag: Duration = .milliseconds(40)
    /// Writes to these are acknowledged but never take (e.g. flash Off in A mode on the ZV-E10).
    var ignoredWrites: Set<UInt16> = []
    /// Return an injection for a call to override the model's behaviour.
    var inject: ((Call) -> Injection?)?
    var liveViewPollsUntilOn = 2
    var focusPollsUntilLock = 3
    var imagePollsAfterPress = 2

    // Model
    var liveViewStatus: UInt64 = 0
    var focusFound: UInt64 = 1
    var objectInMemory: UInt64 = 0
    var settings: [UInt16: Setting] = FakeCamera.iAutoSettings()
    var mode: Int64 { settings[SonyProperty.exposureProgramMode]?.value ?? 0 }
    private var propertyPolls = 0
    private var halfPressed = false
    private var shotPending = false
    private var focusPolls = 0
    private var imagePolls = 0
    private var shotsTaken = 0

    // Observations
    private(set) var calls: [Call] = []
    private(set) var sessionOpen = false
    private(set) var findCount = 0
    private(set) var openCount = 0
    private(set) var closeCount = 0
    private(set) var violations: [String] = []
    /// Writes the camera dropped because a mode change was still settling.
    private(set) var droppedDuringModeChange: [UInt16] = []
    private var inFlight = 0

    let liveViewJPEG: Data = FakeCamera.makeJPEG()
    static func photo(_ n: Int) -> Data { Data("FAKE-PHOTO-\(n)".utf8) }

    func findCamera(timeout: Duration) async throws -> String {
        findCount += 1
        if cameraAvailable { return name }
        try await Task.sleep(for: timeout)
        throw PTPError.noCameraFound
    }

    func openSession(timeout: Duration) async throws {
        openCount += 1
        if openHangs > 0 {
            openHangs -= 1
            try await Task.sleep(for: .seconds(3600))
        }
        sessionOpen = true
        // A fresh session starts with live view off, like the real camera after the handshake.
        liveViewStatus = 0
        propertyPolls = 0
    }

    func closeSession() {
        if sessionOpen { closeCount += 1 }
        sessionOpen = false
    }

    func attachedUSBCameraName() -> String? { usbAttached ? name : nil }

    /// Simulates an unplug: the session dies and the browser stops reporting the camera.
    func unplug() {
        cameraAvailable = false
        sessionOpen = false
        onDisconnect?()
    }

    func send(_ code: UInt16, parameters: [UInt32], outData: Data?) async throws -> PTPResponse {
        guard sessionOpen else { throw PTPError.notConnected }
        let call = Call(code: code, parameters: parameters, outData: outData)
        if inFlight > 0 { violations.append("overlapping transaction: \(call) while another in flight") }
        inFlight += 1
        defer { inFlight -= 1 }
        calls.append(call)
        try await Task.sleep(for: latency)

        switch inject?(call) {
        case .fail(let e)?: throw e
        case .respond(let rc)?: return PTPResponse(code: rc)
        case .hang?: try await Task.sleep(for: .seconds(3600))
        case nil: break
        }
        return try await respond(call)
    }

    private func respond(_ call: Call) async throws -> PTPResponse {
        let ok = PTPResponse(code: PTPResponseCode.ok)
        switch call.code {
        case PTPOperation.sonySDIOConnect:
            return PTPResponse(code: PTPResponseCode.ok, data: Data(count: 8))
        case PTPOperation.sonyGetExtDeviceInfo:
            var w = PTPWriter()
            w.u16(0x12C)
            w.u32(3); w.u16(SonyProperty.focusFound); w.u16(SonyProperty.objectInMemory); w.u16(SonyProperty.liveViewStatus)
            w.u32(2); w.u16(SonyProperty.shutterHalfRelease); w.u16(SonyProperty.shutterRelease)
            return PTPResponse(code: PTPResponseCode.ok, data: w.data)
        case PTPOperation.sonySetControlDeviceA:
            return PTPResponse(code: controlA(call))
        case PTPOperation.sonySetControlDeviceB:
            controlB(call)
            return ok
        case PTPOperation.sonyGetAllDevicePropData:
            pollProperties()
            return PTPResponse(code: PTPResponseCode.ok, data: propertyBlob())
        case PTPOperation.getObjectInfo where call.parameters == [SonyHandle.capturedImage]:
            if objectInMemory < 0x8000 { violations.append("GetObjectInfo with ObjectInMemory=\(objectInMemory)") }
            var w = PTPWriter()
            for _ in 0..<13 { w.u32(0) }  // 52-byte fixed header
            let fname = "DSC0\(1000 + shotsTaken).JPG"
            w.u8(UInt8(fname.utf16.count + 1))
            fname.utf16.forEach { w.u16($0) }
            w.u16(0)
            return PTPResponse(code: PTPResponseCode.ok, data: w.data)
        case PTPOperation.getObject where call.isPhotoDownload:
            if objectInMemory < 0x8000 { violations.append("GetObject(C001) with ObjectInMemory=\(objectInMemory)") }
            objectInMemory = 0
            return PTPResponse(code: PTPResponseCode.ok, data: Self.photo(shotsTaken))
        case PTPOperation.getObject where call.isLiveView:
            if liveViewStatus != 1 {
                // The real camera never answers this; neither do we.
                violations.append("live-view GetObject before LiveViewStatus=1")
                try await Task.sleep(for: .seconds(3600))
            }
            // Alternate frames and not-ready answers, as observed on hardware.
            if calls.filter(\.isLiveView).count % 2 == 0 { return PTPResponse(code: PTPResponseCode.accessDenied) }
            var w = PTPWriter()
            w.u32(16); w.u32(UInt32(liveViewJPEG.count)); w.u32(0); w.u32(0)
            return PTPResponse(code: PTPResponseCode.ok, data: w.data + liveViewJPEG)
        default:
            return PTPResponse(code: PTPResponseCode.operationNotSupported)
        }
    }

    private func controlB(_ call: Call) {
        if call.isControlB(SonyProperty.shutterHalfRelease, 2) {
            halfPressed = true
            focusPolls = 0
        } else if call.isControlB(SonyProperty.shutterHalfRelease, 1) {
            halfPressed = false
            focusFound = 1
        } else if call.isControlB(SonyProperty.shutterRelease, 2) {
            // Focus priority: without settled focus the press is ignored.
            if halfPressed, [2, 3, 6, 7].contains(focusFound) {
                shotPending = true
                imagePolls = 0
            } else {
                violations.append("full press without focus (FocusFound=\(focusFound))")
            }
        }
    }

    private func controlA(_ call: Call) -> UInt16 {
        guard let code = call.parameters.first.map({ UInt16(truncatingIfNeeded: $0) }) else {
            return PTPResponseCode.parameterNotSupported
        }
        if code == SonyProperty.priorityMode { return PTPResponseCode.ok }
        guard var s = settings[code], let data = call.outData else { return PTPResponseCode.devicePropNotSupported }
        var r = PTPReader(data)
        guard let v = (try? r.value(ofType: s.type)).flatMap(\.int64) else { return PTPResponseCode.generalError }
        let modeSettling = settings[SonyProperty.exposureProgramMode]?.pending != nil
        if code != SonyProperty.exposureProgramMode, s.lockedIn(mode) || (modeSettling && s.followsMode) {
            if modeSettling { droppedDuringModeChange.append(code) }
            return PTPResponseCode.ok  // acknowledged, silently ignored
        }
        if ignoredWrites.contains(code) { return PTPResponseCode.ok }
        let lag = code == SonyProperty.exposureProgramMode ? modeReadbackLag : readbackLag
        s.pending = (v, .now + lag)
        settings[code] = s
        return PTPResponseCode.ok
    }

    /// Applies pending writes whose read-back lag has passed.
    private func settleWrites() {
        let now = ContinuousClock.now
        for (code, s) in settings {
            guard let p = s.pending, p.at <= now else { continue }
            settings[code]?.value = p.value
            settings[code]?.pending = nil
        }
    }

    private func pollProperties() {
        settleWrites()
        propertyPolls += 1
        if liveViewStatus == 0, propertyPolls >= liveViewPollsUntilOn { liveViewStatus = 1 }
        if halfPressed, focusFound == 1 {
            focusPolls += 1
            if focusPolls >= focusPollsUntilLock { focusFound = 2 }
        }
        if shotPending {
            imagePolls += 1
            if imagePolls >= imagePollsAfterPress {
                shotPending = false
                shotsTaken += 1
                objectInMemory = 0x8001
                Task { @MainActor in
                    self.onEvent?(PTPEvent(code: PTPEventCode.sonyObjectAdded, transactionID: 0, parameters: [SonyHandle.capturedImage]))
                }
            }
        }
    }

    private func propertyBlob() -> Data {
        var w = PTPWriter()
        w.u32(UInt32(4 + settings.count)); w.u32(0)
        func u8prop(_ code: UInt16, _ v: UInt64) {
            w.u16(code); w.u16(PTPDataType.uint8); w.u8(0); w.u8(1); w.u8(0); w.u8(UInt8(v)); w.u8(0)
        }
        func u16prop(_ code: UInt16, _ v: UInt64) {
            w.u16(code); w.u16(PTPDataType.uint16); w.u8(0); w.u8(1); w.u16(0); w.u16(UInt16(v)); w.u8(0)
        }
        u8prop(SonyProperty.focusFound, focusFound)
        u16prop(SonyProperty.objectInMemory, objectInMemory)
        u8prop(SonyProperty.liveViewStatus, liveViewStatus)
        for code in settings.keys.sorted() {
            let s = settings[code]!
            let locked = s.lockedIn(mode)
            w.u16(code); w.u16(s.type); w.u8(1); w.u8(locked ? 2 : 1)
            w.value(s.value, s.type); w.value(s.value, s.type)
            if s.isRange {
                w.u8(1); w.value(-1, s.type); w.value(100, s.type); w.value(1, s.type)
            } else {
                let offered = locked ? [] : s.offered
                w.u8(2); w.u16(UInt16(offered.count))
                offered.forEach { w.value($0, s.type) }
            }
        }
        return w.data
    }

    // MARK: Profile properties

    struct Setting {
        var type: UInt16
        var value: Int64
        var offered: [Int64]
        /// Display-only in Intelligent Auto (and dropped while a mode change settles).
        var followsMode = true
        /// Display-only in M too (exposure compensation).
        var lockedInManual = false
        var isRange = false
        var pending: (value: Int64, at: ContinuousClock.Instant)?

        func lockedIn(_ mode: Int64) -> Bool {
            (followsMode && mode == SonyMode.iAuto) || (lockedInManual && mode == SonyMode.manual)
        }
    }

    enum SonyMode {
        static let manual: Int64 = 0x0000_0001
        static let program: Int64 = 0x0001_0002
        static let aperture: Int64 = 0x0002_0003
        static let shutter: Int64 = 0x0003_0004
        static let iAuto: Int64 = 0x0004_8000
    }

    /// A ZV-E10 left in Intelligent Auto by someone: none of the strobe settings in place.
    static func iAutoSettings() -> [UInt16: Setting] {
        let evSteps: [Int64] = [1000, 700, 300, 0, -300, -700, -1000]
        return [
            SonyProperty.exposureProgramMode: Setting(
                type: PTPDataType.uint32, value: SonyMode.iAuto,
                offered: [SonyMode.program, SonyMode.aperture, SonyMode.shutter, SonyMode.manual, 0x78050, SonyMode.iAuto, 0x48001],
                followsMode: false),
            SonyProperty.shutterSpeed: Setting(
                type: PTPDataType.uint32, value: 0x0001_001E,  // 1/30
                offered: [0, 0x012C_000A, 0x0001_0004, 0x0001_001E, 0x0001_00A0, 0x0001_00FA, 0x0001_0FA0]),
            SonyProperty.fNumber: Setting(type: PTPDataType.uint16, value: 560, offered: [560, 800, 1100, 2200]),
            SonyProperty.iso: Setting(type: PTPDataType.uint32, value: 0xFF_FFFF, offered: [0xFF_FFFF, 100, 200, 400, 800]),
            SonyProperty.exposureBiasCompensation: Setting(type: PTPDataType.int16, value: 0, offered: evSteps,
                                                           lockedInManual: true),
            SonyProperty.flashMode: Setting(type: PTPDataType.uint16, value: 3, offered: [2, 1, 3, 0x8001, 0x8003],
                                            followsMode: false),
            SonyProperty.flashCompensation: Setting(type: PTPDataType.int16, value: 0, offered: evSteps),
            SonyProperty.focusMode: Setting(type: PTPDataType.uint16, value: 0x8004, offered: [2, 0x8005, 0x8004, 0x8006, 1],
                                            followsMode: false),
            SonyProperty.whiteBalance: Setting(type: PTPDataType.uint16, value: 2, offered: [2, 4, 0x8011, 0x8010, 6, 7]),
            SonyProperty.liveViewSettingEffect: Setting(type: PTPDataType.uint8, value: 1, offered: [1, 2]),
            SonyProperty.batteryLevel: Setting(type: PTPDataType.int8, value: 80, offered: [], followsMode: false, isRange: true),
        ]
    }

    /// The same body already set up exactly as `CameraProfile.strobes` asks.
    static func strobeSettings() -> [UInt16: Setting] {
        var s = iAutoSettings()
        s[SonyProperty.exposureProgramMode]?.value = SonyMode.manual
        s[SonyProperty.shutterSpeed]?.value = 0x0001_00A0
        s[SonyProperty.fNumber]?.value = 800
        s[SonyProperty.iso]?.value = 100
        s[SonyProperty.focusMode]?.value = 2
        s[SonyProperty.liveViewSettingEffect]?.value = 2
        return s
    }

    /// Current (read-back) value of a profile property.
    func value(_ code: UInt16) -> Int64? { settings[code]?.value }

    var controlAWrites: [Call] { calls.filter { $0.code == PTPOperation.sonySetControlDeviceA && $0.parameters != [UInt32(SonyProperty.priorityMode)] } }

    static func makeJPEG() -> Data {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

private extension PTPWriter {
    mutating func value(_ v: Int64, _ type: UInt16) {
        switch type {
        case PTPDataType.int8, PTPDataType.uint8: u8(UInt8(truncatingIfNeeded: v))
        case PTPDataType.int16, PTPDataType.uint16: u16(UInt16(truncatingIfNeeded: v))
        default: u32(UInt32(truncatingIfNeeded: v))
        }
    }
}
