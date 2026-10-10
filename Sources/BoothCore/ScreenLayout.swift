import CoreGraphics
import Foundation

/// A display, as plain data (the app builds these from `NSScreen`), so the layout decision
/// can be unit-tested without AppKit.
public struct ScreenDescriptor: Equatable, Sendable, CustomStringConvertible {
    /// `CGDirectDisplayID`.
    public var id: UInt32
    public var name: String
    public var frame: CGRect
    /// The laptop's own panel.
    public var isBuiltin: Bool
    /// The menu-bar display (`NSScreen.screens.first`).
    public var isMain: Bool

    public init(id: UInt32, name: String, frame: CGRect, isBuiltin: Bool, isMain: Bool) {
        self.id = id
        self.name = name
        self.frame = frame
        self.isBuiltin = isBuiltin
        self.isMain = isMain
    }

    public var description: String { "\"\(name)\" #\(id)\(isBuiltin ? " built-in" : "")\(isMain ? " main" : "")" }
}

/// Where the booth (guest-facing, full screen) and the control panel go.
public enum ScreenLayout: Equatable, Sendable {
    /// One display: the booth is a kiosk; the panel opens on top of it on demand (⌘,).
    case singleScreen(booth: ScreenDescriptor)
    /// The booth fills one display; the panel lives on another (normally the laptop's).
    case twoScreen(booth: ScreenDescriptor, panel: ScreenDescriptor)

    public var booth: ScreenDescriptor {
        switch self {
        case .singleScreen(let b), .twoScreen(let b, _): return b
        }
    }

    public var panel: ScreenDescriptor? {
        if case .twoScreen(_, let p) = self { return p }
        return nil
    }

    /// Decides the layout. `screens` is in `NSScreen.screens` order (main first).
    /// The booth goes on the display `selection` picks (falling back to the first one when it
    /// matches nothing); the panel goes on a different display, preferring the built-in one.
    /// Returns nil only when there are no screens at all.
    public static func compute(screens: [ScreenDescriptor], selection: BoothConfig.DisplaySelection) -> ScreenLayout? {
        guard let first = screens.first else { return nil }
        let booth = boothScreen(screens, selection) ?? first
        let others = screens.filter { $0.id != booth.id }
        guard let panel = others.first(where: \.isBuiltin) ?? others.first(where: \.isMain) ?? others.first else {
            return .singleScreen(booth: booth)
        }
        return .twoScreen(booth: booth, panel: panel)
    }

    /// The display `config.display` selects, or nil when it matches nothing.
    static func boothScreen(_ screens: [ScreenDescriptor], _ sel: BoothConfig.DisplaySelection) -> ScreenDescriptor? {
        switch sel {
        case .main:
            return screens.first(where: \.isMain) ?? screens.first
        case .index(let i):
            return screens.indices.contains(i) ? screens[i] : nil
        case .name(let n):
            return screens.first { $0.name.localizedCaseInsensitiveContains(n) }
        case .auto:
            let external = screens.filter { !$0.isBuiltin }
            // Prefer an external display that isn't the menu-bar one (Mac mini + monitor + TV).
            return external.first { !$0.isMain } ?? external.first ?? screens.first
        }
    }
}
