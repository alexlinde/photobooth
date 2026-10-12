import Foundation

/// Command-line flags.
struct AppOptions {
    var windowed = false
    var fakeCamera = false
    var fakeFailRate = 0.0
    /// Fake camera in strip mode: really print the sheets (default: render and save only, to
    /// save paper).
    var printFake = false
    var configPath: String?
    var learnKey = false
    var selfTest = false
    var googleLogin = false
    /// Dev: simulate a button press every N seconds (presses outside idle are ignored).
    var autoPress: Double?
    /// Dev: print the window number to stdout (for `screencapture -l`).
    var printWindowID = false
    /// Dev: save a PNG of the window into this directory shortly after each state change.
    var snapshotDir: String?
    /// Hidden: `--render-print A B C --out FILE` renders a print sheet and exits.
    var renderPrint: [String]?
    /// Hidden: `--render-strip-screen A B C --out DIR` renders strip-mode TV frames as PNGs and exits.
    var renderStripScreen: [String]?
    var renderOut: String?

    static let usage = """
    Usage: PhotoBooth [options]
      --windowed              Normal resizable window, cursor visible (development)
      --fake-camera           Use the built-in fake camera (no hardware)
      --fake-fail-rate X      Fake camera: fraction of captures that fail (0–1)
      --print-fake            Fake camera: really print strip-mode sheets (default: save only)
      --config PATH           Config file (default ~/PhotoBooth/config.json)
      --learn-key             Show HID usage / key code / config string for each key press
      --google-login          Sign in to Google Photos once (opens the browser) and exit
      --self-test             Run the state-machine scenarios and exit (non-zero on failure)
      --auto-press SECONDS    Dev: simulate a button press every SECONDS
      --print-window-id       Dev: print the booth window's number on launch
      --snapshot-dir DIR      Dev: save a PNG of the window after each state change
    Attendant keys: Ctrl+Opt+Cmd+Q quit, Ctrl+Opt+Cmd+R retry / reload config,
                    Ctrl+Opt+Cmd+D simulate camera disconnect (fake camera only). Cmd+Q also quits.
                    Q and R work system-wide, even when PhotoBooth isn't the frontmost app.
    """

    static func parse(_ args: [String]) throws -> AppOptions {
        var o = AppOptions()
        var it = args.dropFirst().makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw OptionError("\(flag) needs a value") }
            return v
        }
        while let a = it.next() {
            switch a {
            case "--windowed": o.windowed = true
            case "--fake-camera": o.fakeCamera = true
            case "--fake-fail-rate":
                guard let v = Double(try value(a)), (0...1).contains(v) else { throw OptionError("--fake-fail-rate needs a number 0–1") }
                o.fakeFailRate = v
            case "--print-fake": o.printFake = true
            case "--config": o.configPath = try value(a)
            case "--learn-key": o.learnKey = true
            case "--self-test": o.selfTest = true
            case "--google-login": o.googleLogin = true
            case "--auto-press":
                guard let v = Double(try value(a)), v > 0 else { throw OptionError("--auto-press needs seconds > 0") }
                o.autoPress = v
            case "--print-window-id": o.printWindowID = true
            case "--snapshot-dir": o.snapshotDir = try value(a)
            case "--render-print": o.renderPrint = [try value(a), try value(a), try value(a)]
            case "--render-strip-screen": o.renderStripScreen = [try value(a), try value(a), try value(a)]
            case "--out": o.renderOut = try value(a)
            case "-h", "--help": throw OptionError(nil)
            default:
                // Ignore Xcode/LaunchServices noise like -NSDocumentRevisionsDebugMode / -psn_.
                if a.hasPrefix("-psn_") { continue }
                if a.hasPrefix("-NS") || a.hasPrefix("-Apple") { _ = it.next(); continue }
                throw OptionError("Unknown option \(a)")
            }
        }
        if o.renderPrint != nil, o.renderOut == nil { throw OptionError("--render-print needs --out FILE") }
        if o.renderStripScreen != nil, o.renderOut == nil { throw OptionError("--render-strip-screen needs --out DIR") }
        if o.renderOut != nil, o.renderPrint == nil, o.renderStripScreen == nil {
            throw OptionError("--out is only used with --render-print or --render-strip-screen")
        }
        if o.printFake, !o.fakeCamera { throw OptionError("--print-fake is only used with --fake-camera") }
        return o
    }

    struct OptionError: Error {
        var message: String?
        init(_ m: String?) { message = m }
    }
}
