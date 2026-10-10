import Foundation
import SonyCamera

// Lighting profiles in config.json: `"lighting"` picks a built-in `CameraProfile` and
// `"profiles"` overrides individual fields of it, using friendly JSON values:
//
//   "profiles": {
//     "strobes": {"shutter": "1/160", "aperture": 8, "iso": 100, "flashCompensation": -0.3},
//     "ambient": {"aperture": 4, "iso": "auto"}
//   }
//
// `ProfileField` is the single source of truth for each field's JSON name, accepted values,
// display text and picker choices, so the decoder, the encoder and the control panel agree.

/// Which camera profile the booth applies on every (re)connect.
public enum Lighting: String, Codable, Sendable, CaseIterable {
    case strobes, ambient
    /// Don't touch the camera's settings.
    case none

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = Lighting(rawValue: s.lowercased()) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected \"strobes\", \"ambient\" or \"none\", got \"\(s)\"")
        }
        self = v
    }

    /// The built-in profile overrides apply to (nil for `.none`).
    public var builtin: CameraProfile? {
        switch self {
        case .strobes: return .strobes
        case .ambient: return .ambient
        case .none: return nil
        }
    }

    public var title: String {
        switch self {
        case .strobes: return "Strobes"
        case .ambient: return "Ambient"
        case .none: return "Don't change camera"
        }
    }
}

/// Per-field overrides on top of a built-in profile. `nil` = use the built-in value.
public struct ProfileOverride: Equatable, Sendable {
    public var exposureMode: CameraProfile.ExposureMode?
    public var shutter: CameraProfile.ShutterSpeed?
    public var aperture: Double?
    public var iso: CameraProfile.ISO?
    public var exposureCompensation: Double?
    public var flash: CameraProfile.FlashMode?
    public var flashCompensation: Double?
    public var focus: CameraProfile.FocusMode?
    public var whiteBalance: CameraProfile.WhiteBalance?
    public var settingEffect: Bool?

    public init() {}

    public var isEmpty: Bool { self == ProfileOverride() }

    /// `base` with every non-nil override applied.
    public func applied(to base: CameraProfile) -> CameraProfile {
        var p = base
        if let v = exposureMode { p.exposureMode = v }
        if let v = shutter { p.shutterSpeed = v }
        if let v = aperture { p.aperture = v }
        if let v = iso { p.iso = v }
        if let v = exposureCompensation { p.exposureCompensation = v }
        if let v = flash { p.flashMode = v }
        if let v = flashCompensation { p.flashCompensation = v }
        if let v = focus { p.focusMode = v }
        if let v = whiteBalance { p.whiteBalance = v }
        if let v = settingEffect { p.liveViewSettingEffect = v }
        return p
    }
}

/// `"profiles"`: overrides for each built-in profile.
public struct ProfileOverrides: Equatable, Sendable {
    public var strobes = ProfileOverride()
    public var ambient = ProfileOverride()

    public init() {}

    public var isEmpty: Bool { strobes.isEmpty && ambient.isEmpty }

    public subscript(lighting: Lighting) -> ProfileOverride {
        get { lighting == .ambient ? ambient : strobes }
        set {
            switch lighting {
            case .strobes: strobes = newValue
            case .ambient: ambient = newValue
            case .none: break
            }
        }
    }
}

/// A bad friendly value; becomes a `DecodingError` (and so a `ConfigError`) with this text.
struct ProfileValueError: Error {
    var message: String
}

/// One editable profile field: JSON key, parsing, display text and picker choices. Values are
/// handled as "friendly strings" (the JSON spelling, e.g. "1/160", "8", "auto", "-0.3", "af-s",
/// "on"), which is also what the control panel uses as picker tags.
public enum ProfileField: String, CaseIterable, Sendable, CodingKey {
    case exposureMode, shutter, aperture, iso, exposureCompensation, flash, flashCompensation
    case focus, whiteBalance, settingEffect

    public var title: String {
        switch self {
        case .exposureMode: return "Exposure mode"
        case .shutter: return "Shutter speed"
        case .aperture: return "Aperture"
        case .iso: return "ISO"
        case .exposureCompensation: return "Exposure compensation"
        case .flash: return "Flash mode"
        case .flashCompensation: return "Flash compensation"
        case .focus: return "Focus mode"
        case .whiteBalance: return "White balance"
        case .settingEffect: return "Live view Setting Effect"
        }
    }

    // MARK: Choices (picker lists)

    /// Standard third-stop shutter speeds, fastest first.
    static let shutterChoices = [
        "1/4000", "1/3200", "1/2500", "1/2000", "1/1600", "1/1250", "1/1000", "1/800", "1/640", "1/500",
        "1/400", "1/320", "1/250", "1/200", "1/160", "1/125", "1/100", "1/80", "1/60", "1/50", "1/40",
        "1/30", "1/25", "1/20", "1/15", "1/13", "1/10", "1/8", "1/6", "1/5", "1/4", "1/3",
        "0.4", "0.5", "0.6", "0.8", "1", "1.3", "1.6", "2", "2.5", "3.2", "4", "5", "6", "8", "10", "13",
        "15", "20", "25", "30",
    ]
    static let apertureChoices = ["1.8", "2", "2.2", "2.5", "2.8", "3.2", "3.5", "4", "4.5", "5", "5.6", "6.3",
                                  "7.1", "8", "9", "10", "11", "13", "14", "16", "18", "20", "22"]
    static let isoChoices = ["auto", "100", "125", "160", "200", "250", "320", "400", "500", "640", "800",
                             "1000", "1250", "1600", "2000", "2500", "3200", "4000", "5000", "6400", "8000",
                             "10000", "12800"]
    /// -3…+3 EV in 1/3 steps, written to one decimal like the camera shows them (-0.3, +0.7).
    static func evChoices(_ range: ClosedRange<Int>) -> [String] {
        range.map { formatNumber((Double($0) / 3 * 10).rounded() / 10) }
    }

    /// Friendly values offered in the control panel, in display order.
    public var choices: [String] {
        switch self {
        case .exposureMode: return Self.exposureModes.map(\.0)
        case .shutter: return Self.shutterChoices
        case .aperture: return Self.apertureChoices
        case .iso: return Self.isoChoices
        case .exposureCompensation, .flashCompensation: return Self.evChoices(-9...9)
        case .flash: return CameraProfile.FlashMode.allCases.map(\.rawValue)
        case .focus: return Self.focusModes.map(\.0)
        case .whiteBalance: return CameraProfile.WhiteBalance.allCases.map(\.rawValue)
        case .settingEffect: return ["off", "on"]
        }
    }

    /// Human-readable text for a friendly value, e.g. "1/160", "f/8", "+0.3 EV", "AF-S".
    public func display(_ value: String) -> String {
        switch self {
        case .exposureMode:
            return ["manual": "Manual (M)", "aperture": "Aperture priority (A)", "shutter": "Shutter priority (S)",
                    "program": "Program (P)"][value] ?? value
        case .shutter:
            return value.contains("/") ? value : value + "\""
        case .aperture: return "f/" + value
        case .iso: return value == "auto" ? "Auto" : value
        case .exposureCompensation, .flashCompensation:
            guard let d = Double(value) else { return value }
            return d == 0 ? "0 EV" : (d > 0 ? "+" : "−") + Self.formatNumber(abs(d)) + " EV"
        case .flash:
            return ["off": "Off", "fill": "Fill flash", "auto": "Auto", "slowSync": "Slow sync",
                    "rearSync": "Rear sync"][value] ?? value
        case .focus: return value.uppercased()
        case .whiteBalance: return value.prefix(1).uppercased() + value.dropFirst()
        case .settingEffect: return value == "on" ? "On (preview shows exposure)" : "Off (bright preview)"
        }
    }

    // MARK: Reading / writing friendly values

    /// The field's value in a full profile, as a friendly string (nil = not set).
    public func value(in p: CameraProfile) -> String? {
        switch self {
        case .exposureMode: return p.exposureMode.map(Self.name)
        case .shutter: return p.shutterSpeed.map(Self.format)
        case .aperture: return p.aperture.map(Self.formatNumber)
        case .iso: return p.iso.map(Self.format)
        case .exposureCompensation: return p.exposureCompensation.map(Self.formatNumber)
        case .flash: return p.flashMode?.rawValue
        case .flashCompensation: return p.flashCompensation.map(Self.formatNumber)
        case .focus: return p.focusMode.map(Self.name)
        case .whiteBalance: return p.whiteBalance?.rawValue
        case .settingEffect: return p.liveViewSettingEffect.map { $0 ? "on" : "off" }
        }
    }

    /// The override's value as a friendly string (nil = not overridden).
    public func value(in o: ProfileOverride) -> String? {
        var p = CameraProfile(name: "")
        p = o.applied(to: p)
        return value(in: p)
    }

    /// Sets (or with nil, clears) the override from a friendly string.
    func set(_ value: String?, in o: inout ProfileOverride) throws {
        guard let value else {
            switch self {
            case .exposureMode: o.exposureMode = nil
            case .shutter: o.shutter = nil
            case .aperture: o.aperture = nil
            case .iso: o.iso = nil
            case .exposureCompensation: o.exposureCompensation = nil
            case .flash: o.flash = nil
            case .flashCompensation: o.flashCompensation = nil
            case .focus: o.focus = nil
            case .whiteBalance: o.whiteBalance = nil
            case .settingEffect: o.settingEffect = nil
            }
            return
        }
        switch self {
        case .exposureMode: o.exposureMode = try Self.parseEnum(value, Self.exposureModes)
        case .shutter: o.shutter = try Self.parseShutter(value)
        case .aperture: o.aperture = try Self.parseAperture(value)
        case .iso: o.iso = try Self.parseISO(value)
        case .exposureCompensation: o.exposureCompensation = try Self.parseEV(value, limit: 5)
        case .flash: o.flash = try Self.parseEnum(value, CameraProfile.FlashMode.allCases.map { ($0.rawValue, $0) })
        case .flashCompensation: o.flashCompensation = try Self.parseEV(value, limit: 3)
        case .focus: o.focus = try Self.parseEnum(value, Self.focusModes)
        case .whiteBalance: o.whiteBalance = try Self.parseEnum(value, CameraProfile.WhiteBalance.allCases.map { ($0.rawValue, $0) })
        case .settingEffect:
            switch value.lowercased() {
            case "on", "true": o.settingEffect = true
            case "off", "false": o.settingEffect = false
            default: throw ProfileValueError(message: "expected true or false, got \"\(value)\"")
            }
        }
    }

    /// Public, non-throwing setter for the control panel (its pickers only offer valid values).
    public func setOverride(_ value: String?, in o: inout ProfileOverride) {
        try? set(value, in: &o)
    }

    // MARK: Parsing / formatting

    static let exposureModes: [(String, CameraProfile.ExposureMode)] = [
        ("manual", .manual), ("aperture", .aperturePriority), ("shutter", .shutterPriority), ("program", .program),
    ]
    static let focusModes: [(String, CameraProfile.FocusMode)] = [
        ("af-s", .single), ("af-c", .continuous), ("af-a", .automatic), ("dmf", .directManual), ("mf", .manual),
    ]

    static func name(_ m: CameraProfile.ExposureMode) -> String { exposureModes.first { $0.1 == m }!.0 }
    static func name(_ m: CameraProfile.FocusMode) -> String { focusModes.first { $0.1 == m }!.0 }

    static func parseEnum<T>(_ s: String, _ table: [(String, T)]) throws -> T {
        if let v = table.first(where: { $0.0.lowercased() == s.lowercased() }) { return v.1 }
        throw ProfileValueError(message: "expected one of " + table.map { "\"\($0.0)\"" }.joined(separator: ", ") + ", got \"\(s)\"")
    }

    /// "1/160" → 1/160 s; "0.5", "2", "2.5", "30" (optionally with a trailing `"` or `s`) → seconds.
    static func parseShutter(_ raw: String) throws -> CameraProfile.ShutterSpeed {
        let bad = ProfileValueError(message: "expected a shutter speed like \"1/160\", \"0.5\" or \"2\" (1/8000 to 30 seconds), got \"\(raw)\"")
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("\"") || s.hasSuffix("s") { s.removeLast() }
        let speed: CameraProfile.ShutterSpeed
        if let slash = s.firstIndex(of: "/") {
            guard let n = Int(s[..<slash]), let d = Int(s[s.index(after: slash)...]), n > 0, d > 0 else { throw bad }
            speed = .init(n, d)
        } else {
            guard let secs = Double(s), secs > 0 else { throw bad }
            // Tenths of a second, like the camera: 0.5" is 5/10, 2.5" is 25/10, 2" is 2/1.
            let tenths = Int((secs * 10).rounded())
            guard tenths > 0 else { throw bad }
            speed = tenths % 10 == 0 ? .init(tenths / 10, 1) : .init(tenths, 10)
        }
        guard speed.seconds >= 1.0 / 8000 - 1e-9, speed.seconds <= 30 else { throw bad }
        return speed
    }

    static func format(_ s: CameraProfile.ShutterSpeed) -> String {
        if s.numerator == 1 && s.denominator != 1 { return "1/\(s.denominator)" }
        return formatNumber(s.seconds)
    }

    static func parseAperture(_ s: String) throws -> Double {
        guard let v = Double(s), (1...32).contains(v) else {
            throw ProfileValueError(message: "expected an f-number between 1 and 32 (e.g. 8 or 5.6), got \(s)")
        }
        return v
    }

    static func parseISO(_ s: String) throws -> CameraProfile.ISO {
        if s.lowercased() == "auto" { return .auto }
        guard let v = Int(s), (50...409_600).contains(v) else {
            throw ProfileValueError(message: "expected \"auto\" or an ISO number like 100 or 800, got \(s)")
        }
        return .value(v)
    }

    static func parseEV(_ s: String, limit: Double) throws -> Double {
        guard let v = Double(s), abs(v) <= limit else {
            throw ProfileValueError(message: "expected a number of EV between \(formatNumber(-limit)) and \(formatNumber(limit)) (e.g. -0.3), got \(s)")
        }
        return v
    }

    static func format(_ iso: CameraProfile.ISO) -> String {
        if case .value(let v) = iso { return "\(v)" }
        return "auto"
    }

    /// "8", "5.6", "-0.3": shortest form, at most 2 decimals.
    static func formatNumber(_ d: Double) -> String {
        let r = (d * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(format: "%g", r)
    }

    /// Whether the JSON spelling is a number (aperture, ISO values, EV) or a Bool.
    fileprivate enum JSONKind { case string, number, numberOrString, bool }
    fileprivate var jsonKind: JSONKind {
        switch self {
        case .aperture, .exposureCompensation, .flashCompensation: return .number
        case .iso: return .numberOrString
        case .settingEffect: return .bool
        default: return .string
        }
    }
}

extension ProfileOverride: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ProfileField.self)
        self.init()
        for field in ProfileField.allCases where c.contains(field) {
            if try c.decodeNil(forKey: field) { continue }
            let raw: String
            switch field.jsonKind {
            case .bool:
                raw = try c.decode(Bool.self, forKey: field) ? "on" : "off"
            case .number:
                raw = ProfileField.formatNumber(try c.decode(Double.self, forKey: field))
            case .numberOrString:
                if let d = try? c.decode(Double.self, forKey: field) {
                    raw = d == d.rounded() ? String(Int(d)) : String(d)
                } else {
                    raw = try c.decode(String.self, forKey: field)
                }
            case .string:
                // Accept a bare number for shutter seconds (`"shutter": 2`).
                if field == .shutter, let d = try? c.decode(Double.self, forKey: field) {
                    raw = String(d)
                } else {
                    raw = try c.decode(String.self, forKey: field)
                }
            }
            do {
                try field.set(raw, in: &self)
            } catch let e as ProfileValueError {
                throw DecodingError.dataCorruptedError(forKey: field, in: c, debugDescription: e.message)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ProfileField.self)
        for field in ProfileField.allCases {
            guard let v = field.value(in: self) else { continue }
            switch field.jsonKind {
            case .bool: try c.encode(v == "on", forKey: field)
            case .number: try c.encode(Double(v)!, forKey: field)
            case .numberOrString:
                if let i = Int(v) { try c.encode(i, forKey: field) } else { try c.encode(v, forKey: field) }
            case .string: try c.encode(v, forKey: field)
            }
        }
    }
}

extension ProfileOverrides: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case strobes, ambient }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strobes = try c.decodeIfPresent(ProfileOverride.self, forKey: .strobes) ?? ProfileOverride()
        ambient = try c.decodeIfPresent(ProfileOverride.self, forKey: .ambient) ?? ProfileOverride()
    }

    /// Only profiles with overrides are written.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !strobes.isEmpty { try c.encode(strobes, forKey: .strobes) }
        if !ambient.isEmpty { try c.encode(ambient, forKey: .ambient) }
    }
}
