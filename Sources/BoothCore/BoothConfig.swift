import Foundation

/// Booth configuration, loaded from `~/PhotoBooth/config.json` (or `--config PATH`).
/// Missing or unknown keys fall back to defaults; wrong types / out-of-range values are
/// reported as a `ConfigError` (shown on the attendant screen, never a crash).
public struct BoothConfig: Codable, Equatable, Sendable {
    public enum ButtonInput: String, Codable, Sendable { case hid, local }

    /// `"auto"` = external display if present, else main; `"main"` = the menu-bar display;
    /// an integer = index into the display list; any other string = case-insensitive
    /// substring of the display's name (e.g. "LG", "Sony TV").
    public enum DisplaySelection: Equatable, Sendable, Codable {
        case auto
        case main
        case index(Int)
        case name(String)

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .index(i); return }
            let s = try c.decode(String.self)
            switch s.lowercased() {
            case "auto", "": self = .auto
            case "main": self = .main
            default: self = Int(s).map { .index($0) } ?? .name(s)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .auto: try c.encode("auto")
            case .main: try c.encode("main")
            case .index(let i): try c.encode(i)
            case .name(let s): try c.encode(s)
            }
        }
    }

    /// USB device filter for HID mode (only presses from this device count).
    public struct DeviceFilter: Equatable, Sendable, Codable {
        public var vendorID: Int
        public var productID: Int

        enum CodingKeys: String, CodingKey { case vendorID, productID }

        init(vendorID: Int, productID: Int) {
            self.vendorID = vendorID
            self.productID = productID
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            vendorID = try Self.decodeID(c, .vendorID)
            productID = try Self.decodeID(c, .productID)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(String(format: "0x%04X", vendorID), forKey: .vendorID)
            try c.encode(String(format: "0x%04X", productID), forKey: .productID)
        }

        /// Accepts a JSON number or a string ("0x1324" or "4900").
        private static func decodeID(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Int {
            if let i = try? c.decode(Int.self, forKey: key) { return i }
            let s = try c.decode(String.self, forKey: key).trimmingCharacters(in: .whitespaces).lowercased()
            let v = s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s)
            guard let v, (0...0xFFFF).contains(v) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "expected a number or hex string like \"0x1324\", got \"\(s)\"")
            }
            return v
        }

        public var hexDescription: String {
            String(format: "vendor 0x%04X / product 0x%04X", vendorID, productID)
        }

        /// Ultimarc StealthSwitch 3 ("Button/Joystick/Trackball Interface").
        static let stealthSwitch3 = DeviceFilter(vendorID: 0x1324, productID: 0x0103)
    }

    public var eventName = "PhotoBooth"
    /// Raw config string, parsed by `KeySpec.parse` (see KeyMap.swift for the names).
    var buttonKey = "a"  // StealthSwitch 3 port 1 as shipped
    public var buttonInput = ButtonInput.hid
    /// HID mode only: only accept presses from this USB device. `null` = any keyboard.
    public var buttonDevice: DeviceFilter? = .stealthSwitch3
    var debounceMs = 400
    var countdownSeconds = 3
    var reviewSeconds = 5.0
    var shotsPerPress = 1
    var pauseBetweenShotsSeconds = 2.0
    var outputRoot = "~/PhotoBooth"
    public var albumName = "Photo Booth"
    public var display = DisplaySelection.auto
    public var mirrorPreview = true
    public var idlePrompt = "Press the button!"

    public init() {}

    enum CodingKeys: String, CodingKey, CaseIterable {
        case eventName, buttonKey, buttonInput, buttonDevice, debounceMs, countdownSeconds
        case reviewSeconds, shotsPerPress, pauseBetweenShotsSeconds, outputRoot, albumName
        case display, mirrorPreview, idlePrompt
    }

    public init(from decoder: Decoder) throws {
        let d = BoothConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventName = try c.decodeIfPresent(String.self, forKey: .eventName) ?? d.eventName
        if let i = try? c.decode(Int.self, forKey: .buttonKey) {
            buttonKey = "hid:\(i)"
        } else {
            buttonKey = try c.decodeIfPresent(String.self, forKey: .buttonKey) ?? d.buttonKey
        }
        buttonInput = try c.decodeIfPresent(ButtonInput.self, forKey: .buttonInput) ?? d.buttonInput
        if c.contains(.buttonDevice) {
            buttonDevice = try c.decodeNil(forKey: .buttonDevice) ? nil : try c.decode(DeviceFilter.self, forKey: .buttonDevice)
        } else {
            buttonDevice = d.buttonDevice
        }
        debounceMs = try c.decodeIfPresent(Int.self, forKey: .debounceMs) ?? d.debounceMs
        countdownSeconds = try c.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? d.countdownSeconds
        reviewSeconds = try c.decodeIfPresent(Double.self, forKey: .reviewSeconds) ?? d.reviewSeconds
        shotsPerPress = try c.decodeIfPresent(Int.self, forKey: .shotsPerPress) ?? d.shotsPerPress
        pauseBetweenShotsSeconds = try c.decodeIfPresent(Double.self, forKey: .pauseBetweenShotsSeconds) ?? d.pauseBetweenShotsSeconds
        outputRoot = try c.decodeIfPresent(String.self, forKey: .outputRoot) ?? d.outputRoot
        albumName = try c.decodeIfPresent(String.self, forKey: .albumName) ?? d.albumName
        display = try c.decodeIfPresent(DisplaySelection.self, forKey: .display) ?? d.display
        mirrorPreview = try c.decodeIfPresent(Bool.self, forKey: .mirrorPreview) ?? d.mirrorPreview
        idlePrompt = try c.decodeIfPresent(String.self, forKey: .idlePrompt) ?? d.idlePrompt
    }

    // MARK: Derived / validated values

    public var key: KeySpec? { KeySpec.parse(buttonKey) }
    var debounce: Double { Double(debounceMs) / 1000 }

    /// `outputRoot` with `~` expanded.
    public var outputRootURL: URL {
        URL(fileURLWithPath: (outputRoot as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Event folder name, made safe for the filesystem.
    public var eventFolderName: String {
        let cleaned = eventName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "PhotoBooth" : cleaned
    }

    public var eventDirectoryURL: URL { outputRootURL.appendingPathComponent(eventFolderName, isDirectory: true) }

    /// Returns human-readable problems; empty when valid.
    func validationErrors() -> [String] {
        var errs: [String] = []
        if key == nil {
            errs.append("buttonKey \"\(buttonKey)\" is not a known key name. Use e.g. \"space\", \"return\", \"f13\", \"b\", or a HID usage like \"hid:0x2c\". Run with --learn-key to find yours.")
        } else if buttonInput == .local, key?.keyCode == nil {
            errs.append("buttonKey \"\(buttonKey)\" has no macOS key code, so it only works with \"buttonInput\": \"hid\".")
        }
        if !(0...5000).contains(debounceMs) { errs.append("debounceMs must be 0–5000 (got \(debounceMs)).") }
        if !(0...10).contains(countdownSeconds) { errs.append("countdownSeconds must be 0–10 (got \(countdownSeconds)).") }
        if !(1...60).contains(reviewSeconds) { errs.append("reviewSeconds must be 1–60 (got \(reviewSeconds)).") }
        if !(1...10).contains(shotsPerPress) { errs.append("shotsPerPress must be 1–10 (got \(shotsPerPress)).") }
        if !(0...30).contains(pauseBetweenShotsSeconds) { errs.append("pauseBetweenShotsSeconds must be 0–30 (got \(pauseBetweenShotsSeconds)).") }
        if outputRoot.trimmingCharacters(in: .whitespaces).isEmpty { errs.append("outputRoot must not be empty.") }
        return errs
    }

    static let defaultPath = "~/PhotoBooth/config.json"

    /// Pretty JSON for the default file.
    func encodedJSON() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data("{}".utf8)
    }
}

public struct ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    var path: String
    var problems: [String]
    public var description: String { "Problem with \(path):\n" + problems.map { "• " + $0 }.joined(separator: "\n") }
}

public enum ConfigLoader {
    /// Loads config. When the file is missing at the default location, writes the defaults
    /// there first. Returns the config (defaults on error) and an optional error.
    public static func load(path: String?) -> (BoothConfig, ConfigError?) {
        let explicit = path != nil
        let p = ((path ?? BoothConfig.defaultPath) as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: p)
        let fm = FileManager.default
        if !fm.fileExists(atPath: p) {
            if explicit {
                return (BoothConfig(), ConfigError(path: p, problems: ["Config file not found."]))
            }
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try BoothConfig().encodedJSON().write(to: url, options: .atomic)
                BoothLog.info(.config, "Wrote default config to \(p)")
            } catch {
                BoothLog.error(.config, "Could not write default config to \(p): \(error)")
            }
            return (BoothConfig(), nil)
        }
        do {
            let data = try Data(contentsOf: url)
            return decode(data, path: p)
        } catch {
            return (BoothConfig(), ConfigError(path: p, problems: ["Could not read file: \(error.localizedDescription)"]))
        }
    }

    static func decode(_ data: Data, path: String = "config") -> (BoothConfig, ConfigError?) {
        do {
            let cfg = try JSONDecoder().decode(BoothConfig.self, from: data)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let known = Set(BoothConfig.CodingKeys.allCases.map(\.stringValue))
                let unknown = obj.keys.filter { !known.contains($0) }.sorted()
                if !unknown.isEmpty { BoothLog.info(.config, "Ignoring unknown config keys: \(unknown.joined(separator: ", "))") }
            }
            let problems = cfg.validationErrors()
            if !problems.isEmpty { return (BoothConfig(), ConfigError(path: path, problems: problems)) }
            return (cfg, nil)
        } catch let e as DecodingError {
            return (BoothConfig(), ConfigError(path: path, problems: [describe(e)]))
        } catch {
            return (BoothConfig(), ConfigError(path: path, problems: ["\(error)"]))
        }
    }

    private static func describe(_ e: DecodingError) -> String {
        func keyPath(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch e {
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            return "\"\(keyPath(ctx))\" has the wrong type: \(ctx.debugDescription)"
        case .dataCorrupted(let ctx):
            let k = keyPath(ctx)
            return k.isEmpty ? "The file is not valid JSON." : "\"\(k)\": \(ctx.debugDescription)"
        case .keyNotFound(let key, _):
            return "Missing \"\(key.stringValue)\"."
        @unknown default:
            return "\(e)"
        }
    }
}
