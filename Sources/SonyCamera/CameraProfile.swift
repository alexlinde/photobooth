import Foundation

/// Exposure, flash and focus settings the booth applies to the camera on every (re)connect,
/// so the booth doesn't depend on how someone left the camera's menus.
///
/// Every field is optional: `nil` means "leave whatever the camera has". The ZV-E10 only
/// accepts most of these in an exposure mode that exposes them (e.g. shutter speed is locked
/// in Intelligent Auto and aperture priority), so `exposureMode` is applied first.
public struct CameraProfile: Sendable, Equatable {
    public enum ExposureMode: String, Sendable, Equatable, CaseIterable {
        case manual, aperturePriority, shutterPriority, program
    }

    public enum ISO: Sendable, Equatable {
        case auto
        case value(Int)
    }

    public enum FlashMode: String, Sendable, Equatable, CaseIterable {
        case off, fill, auto, slowSync, rearSync
    }

    public enum FocusMode: String, Sendable, Equatable, CaseIterable {
        /// AF-S
        case single
        /// AF-C
        case continuous
        /// AF-A
        case automatic
        /// DMF
        case directManual
        /// MF
        case manual
    }

    public enum WhiteBalance: String, Sendable, Equatable, CaseIterable {
        case auto, daylight, shade, cloudy, tungsten, flash
    }

    /// Shutter speed as a fraction of a second: 1/160 s is `(1, 160)`, 2.5 s is `(25, 10)`.
    public struct ShutterSpeed: Sendable, Equatable, CustomStringConvertible {
        public var numerator: Int
        public var denominator: Int
        public init(_ numerator: Int, _ denominator: Int) {
            self.numerator = numerator
            self.denominator = denominator
        }
        public var seconds: Double { Double(numerator) / Double(denominator) }
        public var description: String {
            if numerator == 1 { return "1/\(denominator)" }
            let s = seconds
            return s == s.rounded() ? "\(Int(s))\"" : String(format: "%.1f\"", s)
        }
    }

    /// Shown in logs and the control panel, e.g. "Strobes".
    public var name: String
    public var exposureMode: ExposureMode?
    public var shutterSpeed: ShutterSpeed?
    /// f-number, e.g. 8.0.
    public var aperture: Double?
    public var iso: ISO?
    /// EV, e.g. -0.3. Only meaningful outside manual mode.
    public var exposureCompensation: Double?
    public var flashMode: FlashMode?
    /// EV, e.g. -1.0.
    public var flashCompensation: Double?
    public var focusMode: FocusMode?
    public var whiteBalance: WhiteBalance?
    /// Live View Display "Setting Effect". `false` (Off) keeps the preview bright at strobe
    /// exposures, which would otherwise render it nearly black.
    public var liveViewSettingEffect: Bool?

    public init(name: String, exposureMode: ExposureMode? = nil, shutterSpeed: ShutterSpeed? = nil,
                aperture: Double? = nil, iso: ISO? = nil, exposureCompensation: Double? = nil,
                flashMode: FlashMode? = nil, flashCompensation: Double? = nil, focusMode: FocusMode? = nil,
                whiteBalance: WhiteBalance? = nil, liveViewSettingEffect: Bool? = nil) {
        self.name = name
        self.exposureMode = exposureMode
        self.shutterSpeed = shutterSpeed
        self.aperture = aperture
        self.iso = iso
        self.exposureCompensation = exposureCompensation
        self.flashMode = flashMode
        self.flashCompensation = flashCompensation
        self.focusMode = focusMode
        self.whiteBalance = whiteBalance
        self.liveViewSettingEffect = liveViewSettingEffect
    }

    /// Off-camera strobes on the hot-shoe trigger: fixed exposure, the strobes light the shot.
    public static let strobes = CameraProfile(
        name: "Strobes", exposureMode: .manual, shutterSpeed: ShutterSpeed(1, 160), aperture: 8, iso: .value(100),
        flashMode: .fill, flashCompensation: 0, focusMode: .single, whiteBalance: .auto,
        liveViewSettingEffect: false)

    /// No strobes: the camera meters the room. Preview shows the real exposure.
    public static let ambient = CameraProfile(
        name: "Ambient", exposureMode: .aperturePriority, aperture: 5.6, iso: .auto, exposureCompensation: 0,
        flashMode: .off, focusMode: .single, whiteBalance: .auto, liveViewSettingEffect: true)
}

/// What happened when a profile was applied, one item per requested setting.
public struct CameraProfileReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Written and read back with the requested value.
        case applied
        /// The camera already had the requested value; nothing written.
        case alreadySet
        /// Written, but the camera reads back something else (e.g. f/4 on a lens whose
        /// minimum at this focal length is f/5.6).
        case mismatch(actual: String)
        /// Not changeable in the camera's current state (greyed out / display-only).
        case locked
        /// The camera doesn't report this setting at all, or doesn't offer the requested value.
        case unsupported
        case failed(String)

        public var isOK: Bool {
            switch self {
            case .applied, .alreadySet: return true
            default: return false
            }
        }
    }

    public struct Item: Sendable, Equatable {
        /// Human-readable setting name, e.g. "Shutter speed".
        public var setting: String
        /// Requested value, human-readable, e.g. "1/160".
        public var requested: String
        public var outcome: Outcome
        public init(setting: String, requested: String, outcome: Outcome) {
            self.setting = setting
            self.requested = requested
            self.outcome = outcome
        }
    }

    public var profileName: String
    public var items: [Item]
    public var finishedAt: Date

    public init(profileName: String, items: [Item], finishedAt: Date) {
        self.profileName = profileName
        self.items = items
        self.finishedAt = finishedAt
    }

    public var allOK: Bool { items.allSatisfy(\.outcome.isOK) }
    public var problems: [Item] { items.filter { !$0.outcome.isOK } }
}

/// Current camera values for display, all human-readable. `nil` = not known.
public struct CameraReadout: Sendable, Equatable {
    public var exposureMode: String?
    public var shutterSpeed: String?
    public var aperture: String?
    public var iso: String?
    public var flashMode: String?
    public var focusMode: String?
    public var batteryPercent: Int?

    public init(exposureMode: String? = nil, shutterSpeed: String? = nil, aperture: String? = nil, iso: String? = nil,
                flashMode: String? = nil, focusMode: String? = nil, batteryPercent: Int? = nil) {
        self.exposureMode = exposureMode
        self.shutterSpeed = shutterSpeed
        self.aperture = aperture
        self.iso = iso
        self.flashMode = flashMode
        self.focusMode = focusMode
        self.batteryPercent = batteryPercent
    }
}

/// Profile and readout state, published for the control panel.
public struct CameraStatus: Sendable, Equatable {
    /// The profile currently requested (applied on every connect). `nil` = leave camera alone.
    public var profile: CameraProfile?
    /// True while a profile is being written.
    public var applyingProfile = false
    /// Result of the most recent apply, cleared when the camera disconnects.
    public var lastReport: CameraProfileReport?
    /// Refreshed after connect, after each apply and after each capture. `nil` when not connected.
    public var readout: CameraReadout?

    public init(profile: CameraProfile? = nil, applyingProfile: Bool = false,
                lastReport: CameraProfileReport? = nil, readout: CameraReadout? = nil) {
        self.profile = profile
        self.applyingProfile = applyingProfile
        self.lastReport = lastReport
        self.readout = readout
    }
}
