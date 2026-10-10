import Foundation
import PTPKit

/// Writes a `CameraProfile` to a Sony body over an established `SonySession` and reports what
/// stuck. Used by `SonyBoothCamera` (on connect and on `setProfile`) and by the spike.
///
/// Behaviour observed on the ZV-E10 (protocol 0x12C) that shapes the sequence:
/// - Every write is SetControlDeviceA with the descriptor's data type; the new value shows up in
///   GetAllDevicePropData only 0.7–1.5 s later (~2 s for an exposure-mode change), so read-back
///   is polled, never a single read after a fixed delay.
/// - Shutter/aperture writes sent while a mode change is still settling are silently dropped,
///   so the mode is written and polled until it reads back before anything else is touched.
/// - Settability follows the mode: in Intelligent Auto, exposure, ISO, WB, flash comp and
///   Setting Effect are all isEnabled = 2 (display only) with empty enum lists; in M they are 1.
///
/// Device-level refusals (a non-OK response) are reported per item and the apply carries on.
/// Transport-level errors propagate; `GatedTransport` has already faulted the connection.
@MainActor
public struct ProfileApplier {
    public let session: SonySession
    /// How long to poll for an exposure-mode change to read back (observed ~2 s).
    public var modeSettleTimeout: Duration = .seconds(5)
    /// How long to poll for the remaining writes to read back (observed 0.7–1.5 s).
    public var settleTimeout: Duration = .seconds(3)
    public var pollInterval: Duration = .milliseconds(200)
    public var log: (String) -> Void

    public init(session: SonySession, log: ((String) -> Void)? = nil) {
        self.session = session
        self.log = log ?? session.log
    }

    public func apply(_ profile: CameraProfile) async throws -> CameraProfileReport {
        let t0 = ContinuousClock.now
        log("applying camera profile \"\(profile.name)\"")
        try await session.refreshProperties()
        var items: [CameraProfileReport.Item] = []

        // 1. Exposure mode first, on its own, polled until it reads back.
        if let mode = profile.exposureMode {
            let r = SettingRequest.exposureMode(mode)
            items.append(try await applyAlone(r, timeout: modeSettleTimeout))
        }

        // 2. Everything else: classify against the (post-mode) descriptors, write the rest,
        //    then poll until all of them read back.
        let requests = SettingRequest.all(in: profile)
        var outcomes: [CameraProfileReport.Outcome?] = Array(repeating: nil, count: requests.count)
        var requestedText = requests.map(\.requested)
        var toWrite: [(index: Int, raw: Int64)] = []
        for (i, r) in requests.enumerated() {
            switch classify(r) {
            case .done(let outcome, let text):
                outcomes[i] = outcome
                if let text { requestedText[i] = text }
            case .write(let raw):
                toWrite.append((i, raw))
            }
        }
        var written: [(index: Int, raw: Int64)] = []
        for w in toWrite {
            if let refusal = try await write(requests[w.index], w.raw) {
                outcomes[w.index] = .failed(refusal)
            } else {
                written.append(w)
            }
        }
        if !written.isEmpty {
            try await pollUntil(timeout: settleTimeout) {
                written.allSatisfy { current(requests[$0.index].code) == $0.raw }
            }
            for w in written {
                let actual = current(requests[w.index].code)
                outcomes[w.index] = actual == w.raw
                    ? .applied : .mismatch(actual: actual.map(requests[w.index].name) ?? "?")
            }
        }
        for (i, r) in requests.enumerated() {
            let item = CameraProfileReport.Item(setting: r.setting, requested: requestedText[i],
                                                outcome: outcomes[i] ?? .failed("not attempted"))
            logItem(item)
            items.append(item)
        }

        let report = CameraProfileReport(profileName: profile.name, items: items, finishedAt: Date())
        log("camera profile \"\(profile.name)\" "
            + (report.allOK ? "applied" : "applied with \(report.problems.count) problem(s)")
            + " in \(SonySession.CaptureTiming.ms(ContinuousClock.now - t0))")
        return report
    }

    // MARK: - Steps

    private enum Classification {
        /// Nothing to write. `text` replaces the requested string (e.g. with what's on offer).
        case done(CameraProfileReport.Outcome, text: String?)
        case write(Int64)
    }

    private func classify(_ r: SettingRequest) -> Classification {
        guard let d = session.properties[r.code] else { return .done(.unsupported, text: nil) }
        let offered = d.enumValues
        let raw = r.target(offered)
        if d.currentValue.int64 == raw { return .done(.alreadySet, text: nil) }
        // 0 greyed out, 2 display only (e.g. anything exposure-related in Intelligent Auto).
        if d.isEnabled != 1 { return .done(.locked, text: nil) }
        if !offered.isEmpty, !offered.contains(raw) {
            return .done(.unsupported, text: "\(r.requested) (\(r.offeredBy) offers \(r.describe(offered)))")
        }
        return .write(raw)
    }

    /// Writes one setting and polls until it reads back (used for the exposure mode).
    private func applyAlone(_ r: SettingRequest, timeout: Duration) async throws -> CameraProfileReport.Item {
        var item = CameraProfileReport.Item(setting: r.setting, requested: r.requested, outcome: .unsupported)
        switch classify(r) {
        case .done(let outcome, let text):
            item.outcome = outcome
            if let text { item.requested = text }
        case .write(let raw):
            if let refusal = try await write(r, raw) {
                item.outcome = .failed(refusal)
            } else {
                let t0 = ContinuousClock.now
                try await pollUntil(timeout: timeout) { current(r.code) == raw }
                let actual = current(r.code)
                item.outcome = actual == raw ? .applied : .mismatch(actual: actual.map(r.name) ?? "?")
                log("\(r.setting) read back after \(SonySession.CaptureTiming.ms(ContinuousClock.now - t0))")
            }
        }
        logItem(item)
        return item
    }

    /// SetControlDeviceA with the descriptor's data type. Returns a description of a device
    /// refusal; transport failures throw.
    private func write(_ r: SettingRequest, _ raw: Int64) async throws -> String? {
        guard let d = session.properties[r.code] else { return "not reported by camera" }
        let value: PTPValue = d.dataType.isSignedPTPType ? .int(raw) : .uint(UInt64(bitPattern: raw))
        do {
            log("writing \(r.setting) \(hex16(r.code)) = \(r.name(raw)) (\(value))")
            try await session.setControlA(r.code, value, type: d.dataType)
            return nil
        } catch PTPError.deviceResponse(let code, _) {
            return "camera refused (\(PTPResponseCode.name(code)) \(hex16(code)))"
        }
    }

    private func pollUntil(timeout: Duration, _ done: () -> Bool) async throws {
        let t0 = ContinuousClock.now
        while true {
            try await session.refreshProperties()
            if done() || ContinuousClock.now - t0 >= timeout { return }
            try await Task.sleep(for: pollInterval)
        }
    }

    private func current(_ code: UInt16) -> Int64? { session.properties[code]?.currentValue.int64 }

    private func logItem(_ item: CameraProfileReport.Item) {
        log("  \(item.setting) \(item.requested): \(Self.describe(item.outcome))")
    }

    public static func describe(_ outcome: CameraProfileReport.Outcome) -> String {
        switch outcome {
        case .applied: return "applied"
        case .alreadySet: return "already set"
        case .mismatch(let actual): return "MISMATCH (camera reads \(actual))"
        case .locked: return "LOCKED (not settable in the camera's current mode)"
        case .unsupported: return "UNSUPPORTED"
        case .failed(let why): return "FAILED: \(why)"
        }
    }
}

// MARK: - Readout

extension SonySession {
    /// Current camera values for display, from the last property refresh (no transaction).
    public var readout: CameraReadout {
        func v(_ code: UInt16) -> Int64? { properties[code]?.currentValue.int64 }
        let battery = v(SonyProperty.batteryLevel).flatMap { (0...100).contains($0) ? Int($0) : nil }
        return CameraReadout(
            exposureMode: v(SonyProperty.exposureProgramMode).map(SonyValues.exposureModeName),
            shutterSpeed: v(SonyProperty.shutterSpeed).map(SonyValues.shutterName),
            aperture: v(SonyProperty.fNumber).map(SonyValues.apertureName),
            iso: v(SonyProperty.iso).map(SonyValues.isoName),
            flashMode: v(SonyProperty.flashMode).map(SonyValues.flashName),
            focusMode: v(SonyProperty.focusMode).map(SonyValues.focusName),
            batteryPercent: battery)
    }
}

// MARK: - Requests

/// One requested setting: which property, the raw value to write and how to show values.
struct SettingRequest {
    var setting: String
    var requested: String
    var code: UInt16
    /// Raw value to write, given the values the camera currently offers (may be empty).
    var target: ([Int64]) -> Int64
    var name: (Int64) -> String
    /// "camera" or "lens", for the unsupported hint.
    var offeredBy = "camera"
    /// Orders offered values for the unsupported hint; nil = list them in camera order.
    var order: ((Int64) -> Double)?

    func describe(_ offered: [Int64]) -> String {
        if let order {
            let sorted = offered.filter { order($0).isFinite }.sorted { order($0) < order($1) }
            guard let lo = sorted.first, let hi = sorted.last else { return "nothing" }
            return lo == hi ? name(lo) : "\(name(lo))–\(name(hi).replacingOccurrences(of: "f/", with: ""))"
        }
        return offered.map(name).joined(separator: ", ")
    }

    static func exact(_ raw: Int64) -> ([Int64]) -> Int64 { { _ in raw } }

    static func exposureMode(_ m: CameraProfile.ExposureMode) -> SettingRequest {
        let raw = SonyValues.exposureModeRaw(m)
        return SettingRequest(setting: "Exposure mode", requested: SonyValues.exposureModeName(raw),
                              code: SonyProperty.exposureProgramMode, target: exact(raw),
                              name: SonyValues.exposureModeName)
    }

    /// Everything except the exposure mode, in write order.
    static func all(in p: CameraProfile) -> [SettingRequest] {
        var out: [SettingRequest] = []
        if let s = p.shutterSpeed {
            // Long exposures are reported as tenths (30" = 300/10): match by value, not encoding.
            let fallback = Int64(s.numerator) << 16 | Int64(s.denominator)
            out.append(SettingRequest(
                setting: "Shutter speed", requested: s.description, code: SonyProperty.shutterSpeed,
                target: { offered in
                    offered.first { v in
                        let (x, y) = (v >> 16, v & 0xFFFF)
                        return y != 0 && x * Int64(s.denominator) == Int64(s.numerator) * y
                    } ?? fallback
                },
                name: SonyValues.shutterName,
                order: { v in v == 0 ? .infinity : Double(v >> 16) / Double(max(v & 0xFFFF, 1)) }))
        }
        if let f = p.aperture {
            let raw = Int64((f * 100).rounded())
            out.append(SettingRequest(setting: "Aperture", requested: SonyValues.apertureName(raw),
                                      code: SonyProperty.fNumber, target: exact(raw), name: SonyValues.apertureName,
                                      offeredBy: "lens", order: { Double($0) }))
        }
        if let iso = p.iso {
            let raw = SonyValues.isoRaw(iso)
            out.append(SettingRequest(setting: "ISO", requested: SonyValues.isoName(raw), code: SonyProperty.iso,
                                      target: exact(raw), name: SonyValues.isoName,
                                      order: { $0 & 0xFFFFFF == 0xFFFFFF ? 0 : Double($0 & 0xFFFFFF) }))
        }
        if let ev = p.exposureCompensation {
            out.append(evRequest("Exposure compensation", ev, SonyProperty.exposureBiasCompensation))
        }
        if let m = p.flashMode {
            let raw = SonyValues.flashRaw(m)
            out.append(SettingRequest(setting: "Flash mode", requested: SonyValues.flashName(raw),
                                      code: SonyProperty.flashMode, target: exact(raw), name: SonyValues.flashName))
        }
        if let ev = p.flashCompensation {
            out.append(evRequest("Flash compensation", ev, SonyProperty.flashCompensation))
        }
        if let m = p.focusMode {
            let raw = SonyValues.focusRaw(m)
            out.append(SettingRequest(setting: "Focus mode", requested: SonyValues.focusName(raw),
                                      code: SonyProperty.focusMode, target: exact(raw), name: SonyValues.focusName))
        }
        if let wb = p.whiteBalance {
            let raw = SonyValues.whiteBalanceRaw(wb)
            out.append(SettingRequest(setting: "White balance", requested: SonyValues.whiteBalanceName(raw),
                                      code: SonyProperty.whiteBalance, target: exact(raw),
                                      name: SonyValues.whiteBalanceName))
        }
        if let on = p.liveViewSettingEffect {
            let raw: Int64 = on ? 1 : 2
            out.append(SettingRequest(setting: "Live view Setting Effect", requested: SonyValues.settingEffectName(raw),
                                      code: SonyProperty.liveViewSettingEffect, target: exact(raw),
                                      name: SonyValues.settingEffectName))
        }
        return out
    }

    /// EV × 1000, snapped to the nearest step the camera offers (it uses 300/700 for 1/3 and 2/3).
    private static func evRequest(_ setting: String, _ ev: Double, _ code: UInt16) -> SettingRequest {
        let wanted = Int64((ev * 1000).rounded())
        return SettingRequest(setting: setting, requested: SonyValues.evName(wanted), code: code,
                              target: { offered in offered.min { abs($0 - wanted) < abs($1 - wanted) } ?? wanted },
                              name: SonyValues.evName, order: { Double($0) })
    }
}

// MARK: - Value tables

/// Raw values and display names for the properties a profile touches. Tables follow
/// libgphoto2 config.c (see `SonyProperty` for line references); encodings verified on the ZV-E10.
enum SonyValues {
    // 0x500E, uint32. config.c:4492-4557.
    static func exposureModeRaw(_ m: CameraProfile.ExposureMode) -> Int64 {
        switch m {
        case .manual: return 0x0000_0001
        case .program: return 0x0001_0002
        case .aperturePriority: return 0x0002_0003
        case .shutterPriority: return 0x0003_0004
        }
    }

    static func exposureModeName(_ raw: Int64) -> String {
        switch raw {
        case 0x0000_0001: return "M"
        case 0x0001_0002: return "P"
        case 0x0002_0003: return "A"
        case 0x0003_0004: return "S"
        case 0x0004_8000: return "Intelligent Auto"
        case 0x0004_8001: return "Superior Auto"
        case 0x0006_8041: return "Sweep Panorama"
        case 0x0009_8060: return "Intelligent Auto Flash Off"
        default:
            // The high half groups the modes: 5 scene, 7 movie, 8 HFR / S&Q, 9 movie S&Q.
            switch raw >> 16 {
            case 5: return "Scene"
            case 7: return "Movie"
            case 8, 9: return "S&Q / HFR"
            default: return "mode \(hex32(UInt32(truncatingIfNeeded: raw)))"
            }
        }
    }

    // 0xD20D, uint32 (numerator << 16) | denominator; 0 = Bulb. config.c:5979-6020.
    static func shutterName(_ raw: Int64) -> String {
        if raw == 0 { return "Bulb" }
        let (x, y) = (Int(raw >> 16), Int(raw & 0xFFFF))
        guard y != 0 else { return "?" }
        return CameraProfile.ShutterSpeed(x, y).description
    }

    // 0x5007, uint16 f × 100.
    static func apertureName(_ raw: Int64) -> String { String(format: "f/%g", Double(raw) / 100) }

    // 0xD21E, uint32: low 24 bits, 0xFFFFFF = Auto. config.c:3674.
    static func isoRaw(_ iso: CameraProfile.ISO) -> Int64 {
        switch iso {
        case .auto: return 0x00FF_FFFF
        case .value(let v): return Int64(v)
        }
    }

    static func isoName(_ raw: Int64) -> String {
        let base = raw & 0xFF_FFFF
        return base == 0xFF_FFFF ? "Auto" : "\(base)"
    }

    // 0x500C, uint16. config.c:5087-5115 (standard rows + PTP_VENDOR_SONY rows).
    static func flashRaw(_ m: CameraProfile.FlashMode) -> Int64 {
        switch m {
        case .auto: return 1
        case .off: return 2
        case .fill: return 3
        case .slowSync: return 0x8001
        case .rearSync: return 0x8003
        }
    }

    static func flashName(_ raw: Int64) -> String {
        switch raw {
        case 1: return "Auto"
        case 2: return "Off"
        case 3: return "Fill"
        case 0x8001: return "Slow sync"
        case 0x8003: return "Rear sync"
        case 0x8004: return "Wireless"
        default: return "flash \(hex16(UInt16(truncatingIfNeeded: raw)))"
        }
    }

    // 0x500A, uint16. config.c:6746-6765 (2 is the standard "Automatic", AF-S on Sony).
    static func focusRaw(_ m: CameraProfile.FocusMode) -> Int64 {
        switch m {
        case .manual: return 1
        case .single: return 2
        case .continuous: return 0x8004
        case .automatic: return 0x8005
        case .directManual: return 0x8006
        }
    }

    static func focusName(_ raw: Int64) -> String {
        switch raw {
        case 1: return "MF"
        case 2: return "AF-S"
        case 0x8004: return "AF-C"
        case 0x8005: return "AF-A"
        case 0x8006: return "DMF"
        default: return "focus \(hex16(UInt16(truncatingIfNeeded: raw)))"
        }
    }

    // 0x5005, uint16. config.c:1454-1495 (standard rows + PTP_VENDOR_SONY rows).
    static func whiteBalanceRaw(_ wb: CameraProfile.WhiteBalance) -> Int64 {
        switch wb {
        case .auto: return 2
        case .daylight: return 4
        case .tungsten: return 6
        case .flash: return 7
        case .cloudy: return 0x8010
        case .shade: return 0x8011
        }
    }

    static func whiteBalanceName(_ raw: Int64) -> String {
        switch raw {
        case 2: return "Auto"
        case 4: return "Daylight"
        case 6: return "Tungsten"
        case 7: return "Flash"
        case 0x8010: return "Cloudy"
        case 0x8011: return "Shade"
        case 0x8001...0x8004: return "Fluorescent"
        case 0x8012: return "Color temperature"
        case 0x8020...0x8023: return "Custom"
        case 0x8030: return "Underwater auto"
        default: return "WB \(hex16(UInt16(truncatingIfNeeded: raw)))"
        }
    }

    // 0x5010 / 0xD200, int16 EV × 1000.
    static func evName(_ raw: Int64) -> String { String(format: "%+.1f EV", Double(raw) / 1000) }

    // 0xD231, uint8. config.c:7763.
    static func settingEffectName(_ raw: Int64) -> String {
        switch raw {
        case 1: return "On"
        case 2: return "Off"
        default: return "\(raw)"
        }
    }
}

// MARK: - Helpers

extension PTPValue {
    /// The value as a signed integer (unsigned values keep their bit pattern), nil for
    /// strings and arrays.
    var int64: Int64? {
        switch self {
        case .int(let v): return v
        case .uint(let v): return Int64(bitPattern: v)
        default: return nil
        }
    }
}

extension SonyPropertyDescriptor {
    /// The enumeration form's values; empty for range / none / an empty list.
    var enumValues: [Int64] {
        if case .enumeration(let vs) = form { return vs.compactMap(\.int64) }
        return []
    }
}

extension UInt16 {
    var isSignedPTPType: Bool {
        [PTPDataType.int8, PTPDataType.int16, PTPDataType.int32, PTPDataType.int64, PTPDataType.int128].contains(self)
    }
}
