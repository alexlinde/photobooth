import BoothCore
import AppKit
import SonyCamera
import SwiftUI

/// Borderless window that can take key focus (needed for local key monitoring).
final class KioskWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Hosting view that shows a blank cursor over the whole window in kiosk mode.
final class KioskHostingView<Content: View>: NSHostingView<Content> {
    var hidesCursor = false { didSet { window?.invalidateCursorRects(for: self) } }

    static var blankCursor: NSCursor {
        NSCursor(image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }, hotSpot: .zero)
    }

    override func resetCursorRects() {
        if hidesCursor { addCursorRect(bounds, cursor: Self.blankCursor) } else { super.resetCursorRects() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: AppOptions
    private var config = BoothConfig()
    private var configError: ConfigError?

    private var window: NSWindow!
    private var sleepAssertion: SleepAssertion?
    private var camera: BoothCamera?
    private var controller: BoothController?
    private var input: ButtonInput?
    private var preview: LivePreviewNSView?
    private var boothHost: KioskHostingView<BoothRootView>?
    private var learnModel: LearnKeyModel?
    private var autoPressTimer: Timer?
    private var uploads: UploadService?
    private var cursorHidden = false
    private var kiosk: Bool { !options.windowed }

    init(options: AppOptions) {
        self.options = options
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        (config, configError) = ConfigLoader.load(path: options.configPath)
        FileLog.shared.configure(directory: config.outputRootURL.appendingPathComponent("logs", isDirectory: true))
        BoothLog.info(.app, "PhotoBooth launching (\(options.windowed ? "windowed" : "kiosk"), \(options.fakeCamera ? "fake camera" : "real camera")\(options.learnKey ? ", learn-key" : ""))")
        if let e = configError { BoothLog.error(.config, e.description) }
        else { BoothLog.info(.config, "Config: event \"\(config.eventName)\", key \(config.key?.description ?? "?"), input \(config.buttonInput.rawValue)") }

        NSApp.mainMenu = makeMainMenu()
        sleepAssertion = SleepAssertion()
        makeWindow()

        if options.learnKey { startLearnKey() } else { startBooth() }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                BoothLog.info(.ui, "Screen configuration changed: \(NSScreen.screens.map(\.localizedName))")
                self?.placeWindow()
                self?.enforceKiosk()
            }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enforceKiosk() }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        enforceKiosk()
        if options.printWindowID {
            print("WINDOW_ID \(window.windowNumber)")
            fflush(stdout)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        BoothLog.info(.app, "PhotoBooth quitting")
        autoPressTimer?.invalidate()
        input?.stop()
        controller?.stop()
        uploads?.stop()
        sleepAssertion?.release()
        if cursorHidden { NSCursor.unhide() }
        FileLog.shared.flush()
    }

    // MARK: Booth

    private func startBooth() {
        let clock = SystemBoothClock()
        let camera = CameraFactory.make(options: options, clock: clock)
        self.camera = camera
        let maxPixel = Int(maxScreenPixelDimension())
        let controller = BoothController(camera: camera, sink: makeSink(config), clock: clock,
                                         settings: BoothSettings(config),
                                         decodeForReview: ImageDecoding.reviewDecoder(maxPixel: maxPixel))
        self.controller = controller
        controller.onStateChange = { [weak self] s in self?.stateChanged(s) }

        let preview = LivePreviewNSView(mirrored: config.mirrorPreview)
        preview.attach(camera.liveViewFrames())
        self.preview = preview

        let host = KioskHostingView(rootView: BoothRootView(controller: controller, preview: preview, idlePrompt: config.idlePrompt))
        host.hidesCursor = kiosk
        boothHost = host
        window.contentView = host

        let input = ButtonInput(key: config.key, mode: config.buttonInput, deviceFilter: config.buttonDevice)
        input.onPress = { [weak self] in
            guard let self, let c = self.controller else { return }
            let r = c.buttonPressed()
            BoothLog.info(.input, "Button press → \(r)")
        }
        input.onShortcut = { [weak self] s in self?.handleShortcut(s) }
        input.onStatusChange = { [weak self] s in self?.inputStatusChanged(s) }
        self.input = input
        input.start()
        inputStatusChanged(input.status)

        controller.start()
        if let e = configError { controller.raiseAttendant(.config(e.description)) }

        if let every = options.autoPress {
            autoPressTimer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let c = self?.controller else { return }
                    BoothLog.info(.input, "Auto-press → \(c.buttonPressed())")
                }
            }
        }
    }

    /// Local save + Google Photos upload queue. The queue is per event folder/album, so a config
    /// reload that changes either starts a new one (the old one's state file keeps its progress).
    private func makeSink(_ config: BoothConfig) -> PhotoSink {
        if options.fakeCamera {
            return LocalFolderPhotoSink(directory: config.eventDirectoryURL)  // never upload fake photos
        }
        if uploads?.matches(config) != true {
            uploads?.stop()
            uploads = UploadService(config: config)
        }
        return UploadingPhotoSink(local: LocalFolderPhotoSink(directory: config.eventDirectoryURL),
                                  queue: uploads?.queue)
    }

    private var snapshotIndex = 0

    /// Dev aid (--snapshot-dir): renders the window contents to PNG, including the
    /// live-preview layer.
    private func snapshot(label: String) {
        guard let dir = options.snapshotDir, let view = window.contentView else { return }
        snapshotIndex += 1
        let name = String(format: "%02d-%@.png", snapshotIndex, label.replacingOccurrences(of: "/", with: "of"))
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        rep.size = size
        view.layer?.render(in: ctx.cgContext)
        // Fallback for content not captured by layer rendering.
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    private func stateChanged(_ s: BoothState) {
        if options.snapshotDir != nil {
            let label = s.label
            let delay = { if case .capturing = s { return 0.08 } else { return 0.6 } }()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.snapshot(label: label) }
            }
        }
        // Drop below other windows' level while the attendant needs to use System Settings etc.
        guard kiosk else { return }
        if case .attendant = s { window.level = .normal } else { window.level = Self.kioskLevel }
    }

    private func inputStatusChanged(_ s: ButtonInput.Status) {
        guard let controller else { return }
        if let reason = s.fallbackReason {
            controller.inputBanner = "Button works only while this window is focused — " + reason
            controller.raiseAttendant(.inputPermission(reason + "\n\n" + ButtonInput.permissionHelp + "\n\nPress Ctrl+Option+Command+R to continue in focused-window mode."))
        } else {
            controller.inputBanner = nil
            controller.resolveAttendant(kind: "inputPermission")
        }
        if s.deviceConnected == false {
            controller.buttonStatus = "Button not connected (\(s.deviceDescription ?? "configured device"))"
        } else {
            controller.buttonStatus = nil
        }
    }

    private func handleShortcut(_ s: ButtonInput.Shortcut) {
        switch s {
        case .quit:
            BoothLog.info(.app, "Attendant quit shortcut")
            NSApp.terminate(nil)
        case .attendantReset:
            reloadConfig()
            controller?.attendantReset()
        case .simulateDisconnect:
            if let fake = camera as? FakeBoothCamera { fake.simulateDisconnect() }
            else { BoothLog.info(.app, "Simulated disconnect is only available with --fake-camera") }
        }
    }

    private func reloadConfig() {
        let (cfg, err) = ConfigLoader.load(path: options.configPath)
        if let err {
            BoothLog.error(.config, "Reload failed: \(err)")
            configError = err
            controller?.raiseAttendant(.config(err.description))
            return
        }
        let wasError = configError != nil
        configError = nil
        guard cfg != config || wasError else { return }
        BoothLog.info(.config, "Config reloaded")
        config = cfg
        FileLog.shared.configure(directory: cfg.outputRootURL.appendingPathComponent("logs", isDirectory: true))
        if let controller {
            controller.settings = BoothSettings(cfg)
            controller.sink = makeSink(cfg)
            controller.resolveAttendant(kind: "config")
            if let preview { preview.mirrored = cfg.mirrorPreview }
            boothHost?.rootView = BoothRootView(controller: controller, preview: preview!, idlePrompt: cfg.idlePrompt)
        }
        input?.reconfigure(key: cfg.key, mode: cfg.buttonInput, deviceFilter: cfg.buttonDevice)
        placeWindow()
    }

    // MARK: Learn key

    private func startLearnKey() {
        let model = LearnKeyModel()
        learnModel = model
        let host = KioskHostingView(rootView: LearnKeyView(model: model))
        host.hidesCursor = kiosk
        window.contentView = host
        let input = ButtonInput(key: nil, mode: .hid, deviceFilter: nil, learn: true)
        input.onShortcut = { s in if case .quit = s { NSApp.terminate(nil) } }
        input.onRaw = { [weak model] p in
            var line: String
            switch p.source {
            case .hid:
                let u = p.hidUsage ?? 0
                line = String(format: "HID usage 0x%02X (%d)  →  \"buttonKey\": \"%@\"", u, u, p.configString ?? "?")
                if let d = p.device { line += "\n    device: \(d)" }
            case .nsevent:
                let kc = p.keyCode ?? 0
                let chars = (p.characters ?? "").unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F || $0.value >= 0xF700 ? String(format: "U+%04X", $0.value) : String($0) }.joined()
                line = "NSEvent keyCode \(kc) chars \"\(chars)\"  →  \"buttonKey\": \"\(p.configString ?? "(unknown; use HID mode)")\""
            }
            BoothLog.info(.input, "learn-key: " + line.replacingOccurrences(of: "\n", with: " "))
            print(line); fflush(stdout)
            model?.add(line)
        }
        input.onStatusChange = { [weak model] s in
            model?.status = s.fallbackReason.map { $0 + " Only focused-window key presses are shown. " + ButtonInput.permissionHelp } ?? "Listening to all keyboards via HID (works in the background)."
        }
        self.input = input
        input.start()
        model.status = input.status.mode == .hid ? "Listening to all keyboards via HID (works in the background)." : (input.status.fallbackReason ?? "") + " " + ButtonInput.permissionHelp
    }

    // MARK: Window / kiosk

    private static let kioskLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

    private func makeWindow() {
        if kiosk {
            let w = KioskWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = Self.kioskLevel
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isMovable = false
            w.hasShadow = false
            window = w
        } else {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = options.learnKey ? "PhotoBooth — Learn key" : "PhotoBooth"
            w.contentMinSize = NSSize(width: 480, height: 270)
            w.center()
            window = w
        }
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        placeWindow()
    }

    /// Kiosk: cover the configured display (falling back to main) completely.
    private func placeWindow() {
        guard kiosk, let window else { return }
        guard let screen = Self.pickScreen(config.display) ?? NSScreen.screens.first else { return }
        if window.frame != screen.frame {
            BoothLog.info(.ui, "Placing booth on display \"\(screen.localizedName)\" \(screen.frame)")
            window.setFrame(screen.frame, display: true)
        }
    }

    static func pickScreen(_ sel: BoothConfig.DisplaySelection) -> NSScreen? {
        let screens = NSScreen.screens
        switch sel {
        case .main:
            return screens.first
        case .index(let i):
            return screens.indices.contains(i) ? screens[i] : nil
        case .name(let n):
            return screens.first { $0.localizedName.localizedCaseInsensitiveContains(n) }
        case .auto:
            let external = screens.filter { !isBuiltin($0) }
            // Prefer an external display that isn't the menu-bar one (Mac mini + monitor + TV).
            return external.first { $0 != screens.first } ?? external.first ?? screens.first
        }
    }

    private static func isBuiltin(_ s: NSScreen) -> Bool {
        guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(n.uint32Value)) != 0
    }

    private func maxScreenPixelDimension() -> CGFloat {
        let dims = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
        return max(1920, dims.max() ?? 3840)
    }

    /// Re-assert kiosk presentation and hide the cursor (after activation / screen changes).
    private func enforceKiosk() {
        guard kiosk else { return }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        if cursorHidden { NSCursor.unhide() }
        NSCursor.hide()
        cursorHidden = true
        window.invalidateCursorRects(for: window.contentView!)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit PhotoBooth", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        return main
    }
}
