import BoothCore
import AppKit
import SonyCamera
import SwiftUI

/// Borderless booth window. Takes key focus in single-screen kiosk mode (needed for local key
/// monitoring); never in two-screen mode, so the control panel keeps the keyboard.
final class KioskWindow: NSWindow {
    var acceptsKey = true
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { acceptsKey }
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

/// Window arrangement:
/// - `windowed` (--windowed): booth and control panel are ordinary windows (development).
/// - `kiosk`: one display. The booth covers it above the menu bar, Dock and menu bar hidden,
///   cursor hidden. ⌘, opens the panel on top; while it's open the booth drops to normal
///   level and the cursor shows (as on the attendant screen).
/// - `twoScreen`: the booth covers the TV at kiosk level but never takes key focus; the
///   panel is a normal window on the other display (normally the laptop's). Dock and menu bar
///   stay; the cursor hides only while it's over the TV.
/// The layout is recomputed on every display change, so plugging the TV in mid-event works.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
    /// Strip mode: one strip as printed (no photos), under the TV's strip column.
    private var stripBackground: CGImage?
    private var learnModel: LearnKeyModel?
    private var autoPressTimer: Timer?
    private var uploads: UploadService?
    private var cursorHidden = false
    private var kiosk: Bool { !options.windowed }

    private var layout: ScreenLayout?
    private var panelModel: ControlPanelModel?
    private var panelWindow: NSWindow?
    /// Display the panel was last placed on (so reopening it doesn't move it).
    private var panelScreenID: UInt32?
    private var printModel: PrintModel?
    private var printWindow: NSWindow?
    private var printScreenID: UInt32?
    private var pointerMonitors: [Any] = []

    private enum Presentation { case windowed, kiosk, twoScreen }
    private var presentation: Presentation {
        if !kiosk { return .windowed }
        return layout?.panel != nil ? .twoScreen : .kiosk
    }
    private var panelVisible: Bool { panelWindow?.isVisible == true }
    private var printVisible: Bool { printWindow?.isVisible == true }
    /// The control panel or the print window is open.
    private var attendantWindowVisible: Bool { panelVisible || printVisible }

    init(options: AppOptions) {
        self.options = options
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        (config, configError) = ConfigLoader.load(path: options.configPath)
        FileLog.shared.configure(directory: config.outputRootURL.appendingPathComponent("logs", isDirectory: true))
        BoothLog.info(.app, "PhotoBooth launching (\(options.windowed ? "windowed" : "kiosk"), \(options.fakeCamera ? "fake camera" : "real camera")\(options.learnKey ? ", learn-key" : ""))")
        if let e = configError { BoothLog.error(.config, e.description) }
        else { BoothLog.info(.config, "Config: event \"\(config.eventName)\", key \(config.key?.description ?? "?"), input \(config.buttonInput.rawValue), lighting \(config.lighting.rawValue)") }

        NSApp.mainMenu = makeMainMenu()
        sleepAssertion = SleepAssertion()
        layout = computeLayout()
        makeWindow()

        if options.learnKey { startLearnKey() } else { startBooth() }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enforceKiosk() }
        }
        if kiosk { installPointerMonitors() }

        switch presentation {
        case .twoScreen:
            window.orderFrontRegardless()
            showPanel()
        case .kiosk:
            window.makeKeyAndOrderFront(nil)
        case .windowed:
            window.makeKeyAndOrderFront(nil)
            if panelModel != nil {
                showPanel()
                window.makeKeyAndOrderFront(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        updateBoothLevel()
        enforceKiosk()
        if options.printWindowID {
            print("WINDOW_ID \(window.windowNumber)")
            fflush(stdout)
        }
        if options.snapshotDir != nil, panelModel != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                MainActor.assumeIsolated { self?.snapshotPanel(label: "panel-launch", full: true) }
            }
        }
    }

    /// Closing the control panel must not quit; Cmd+Q (or the attendant shortcut) does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon click: bring back the control panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard panelModel != nil else { return true }
        showPanel()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        BoothLog.info(.app, "PhotoBooth quitting")
        autoPressTimer?.invalidate()
        input?.stop()
        controller?.stop()
        uploads?.stop()
        sleepAssertion?.release()
        for m in pointerMonitors { NSEvent.removeMonitor(m) }
        pointerMonitors = []
        setCursorHidden(false)
        FileLog.shared.flush()
    }

    // MARK: Booth

    private func startBooth() {
        let clock = SystemBoothClock()
        let camera = CameraFactory.make(options: options, clock: clock)
        self.camera = camera
        // A config with errors runs on defaults; don't push the default profile onto a camera
        // someone set up by hand. Applied once the config is fixed and reloaded.
        if configError == nil { camera.setProfile(config.cameraProfile) }
        let maxPixel = Int(maxScreenPixelDimension())
        let controller = BoothController(camera: camera, sink: makeSink(config), clock: clock,
                                         settings: BoothSettings(config),
                                         decodeForReview: ImageDecoding.reviewDecoder(maxPixel: maxPixel))
        self.controller = controller
        controller.onStateChange = { [weak self] s in self?.stateChanged(s) }
        controller.onStripComplete = { [weak self] urls in self?.printStrip(urls) }

        let preview = LivePreviewNSView(mirrored: config.mirrorPreview)
        preview.attach(camera.liveViewFrames())
        self.preview = preview

        let host = KioskHostingView(rootView: boothView(controller, preview))
        host.hidesCursor = kiosk
        boothHost = host
        window.contentView = host

        let model = ControlPanelModel(controller: controller, camera: camera, config: config,
                                      configPath: ConfigLoader.resolvedPath(options.configPath))
        model.uploads = uploads
        model.loadError = configError
        model.onSave = { [weak self] cfg in self?.saveConfig(cfg) }
        model.onPrint = { [weak self] in self?.showPrint() }
        panelModel = model

        let printModel = PrintModel(config: config)
        printModel.onChoosePrinter = { [weak self] name in self?.savePrinter(name) }
        self.printModel = printModel
        model.printing = printModel
        refreshStripBackground(config)

        let input = ButtonInput(key: config.key, mode: config.buttonInput, deviceFilter: config.buttonDevice)
        input.onPress = { [weak self] in
            guard let self, let c = self.controller else { return }
            let r = c.buttonPressed()
            BoothLog.info(.input, "Button press → \(r)")
        }
        input.onShortcut = { [weak self] s in self?.handleShortcut(s) }
        input.onStatusChange = { [weak self] s in self?.inputStatusChanged(s) }
        input.isBoothEvent = { [weak self] e in e.window == nil || e.window === self?.window }
        self.input = input
        input.start()
        inputStatusChanged(input.status)

        controller.start()
        if let e = configError { controller.raiseAttendant(.config(e.description)) }
        model.refreshPhotos()

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
        if options.fakeCamera || !config.upload {
            // Never upload fake photos; `upload: false` saves locally only.
            if uploads != nil {
                uploads?.stop()
                uploads = nil
                panelModel?.uploads = nil
            }
            return LocalFolderPhotoSink(directory: config.eventDirectoryURL)
        }
        if uploads?.matches(config) != true {
            uploads?.stop()
            uploads = UploadService(config: config)
            panelModel?.uploads = uploads
        }
        return UploadingPhotoSink(local: LocalFolderPhotoSink(directory: config.eventDirectoryURL),
                                  queue: uploads?.queue)
    }

    private func boothView(_ controller: BoothController, _ preview: LivePreviewNSView) -> BoothRootView {
        BoothRootView(controller: controller, preview: preview, idlePrompt: config.idlePrompt,
                      stripMode: config.stripMode, stripBackground: stripBackground)
    }

    /// Strip mode: renders the strip column's artwork / caption (as printed) off the main thread.
    private func refreshStripBackground(_ cfg: BoothConfig) {
        guard cfg.stripMode else { stripBackground = nil; return }
        let url = cfg.printTemplateURL, caption = cfg.printCaptionText
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let art = PrintSheet.loadArtwork(url)
                if let w = art.warning { BoothLog.info(.printing, "Strip artwork: \(w)") }
                return PrintSheet.renderStrip(photos: [], artwork: art.image, caption: caption)
            }.value
            guard let self, let controller = self.controller, let preview = self.preview else { return }
            self.stripBackground = image
            self.boothHost?.rootView = self.boothView(controller, preview)
        }
    }

    /// Strip mode: a finished strip. Rendered, saved to prints/ and sent to the printer in the
    /// background; with --fake-camera only saved (unless --print-fake), to save paper.
    private func printStrip(_ urls: [URL]) {
        guard let printModel else { return }
        let skip: String? = !config.autoPrint ? "autoPrint is off"
            : options.fakeCamera && !options.printFake ? "fake camera; --print-fake prints it" : nil
        if skip != nil, !options.fakeCamera { controller?.stripMessage = "Your strip is saved" }
        printModel.printStrip(urls, skipReason: skip) { [weak self] why in
            BoothLog.error(.printing, "Strip not printed; the TV asks the guest to see the attendant (\(why))")
            guard let c = self?.controller, case .stripReview = c.state else { return }
            c.stripMessage = "Your strip is saved — ask the attendant for your print"
        }
    }

    private var snapshotIndex = 0

    /// Dev aid (--snapshot-dir): renders the booth window contents to PNG, including the
    /// live-preview layer.
    private func snapshot(label: String) {
        guard let view = window.contentView else { return }
        writeSnapshot(of: view, scale: window.backingScaleFactor, label: label, renderLayer: true)
    }

    /// Dev aid (--snapshot-dir): renders the control panel as shown and, with `full`, the
    /// whole form (disclosure expanded) in a tall offscreen window.
    private func snapshotPanel(label: String, full: Bool = false) {
        guard options.snapshotDir != nil, let panelWindow, let model = panelModel else { return }
        if panelWindow.isVisible, let view = panelWindow.contentView {
            writeSnapshot(of: view, scale: panelWindow.backingScaleFactor, label: label)
        }
        guard full else { return }
        let expanded = model.profileExpanded
        model.profileExpanded = true
        let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 520, height: 2000),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ControlPanelView(model: model))
        w.contentView = host
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated {
                self?.writeSnapshot(of: host, scale: w.backingScaleFactor, label: label + "-full")
                w.orderOut(nil)
                model.profileExpanded = expanded
            }
        }
    }

    /// `renderLayer` captures the live-preview layer; the panel's scroll views come out
    /// flipped that way, so it uses `cacheDisplay` alone.
    private func writeSnapshot(of view: NSView, scale: CGFloat, label: String, renderLayer: Bool = false) {
        guard let dir = options.snapshotDir else { return }
        snapshotIndex += 1
        let name = String(format: "%02d-%@.png", snapshotIndex, label.replacingOccurrences(of: "/", with: "of"))
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        rep.size = size
        if renderLayer { view.layer?.render(in: ctx.cgContext) }
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
                MainActor.assumeIsolated {
                    self?.snapshot(label: label)
                    self?.snapshotPanel(label: "panel-" + label)
                }
            }
        }
        if case .review = s {
            panelModel?.refreshPhotos()
            if printVisible { printModel?.refreshPhotos() }
        }
        updateBoothLevel()
    }

    private func inputStatusChanged(_ s: ButtonInput.Status) {
        panelModel?.button = s
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

    /// Control panel "Apply & Save": write config.json, then apply it exactly like a reload.
    private func saveConfig(_ cfg: BoothConfig) -> ConfigError? {
        do {
            try ConfigLoader.save(cfg, path: options.configPath)
        } catch let e as ConfigError {
            BoothLog.error(.config, "Save failed: \(e)")
            return e
        } catch {
            return ConfigError(path: ConfigLoader.resolvedPath(options.configPath), problems: ["\(error)"])
        }
        reloadConfig()
        return configError
    }

    /// Print window printer picker: saved into config.json without a full reload (that would
    /// re-apply the camera profile). With a broken config.json the choice lasts until quit.
    private func savePrinter(_ name: String) {
        var cfg = config
        cfg.printer = name
        if configError == nil {
            do {
                try ConfigLoader.save(cfg, path: options.configPath)
            } catch {
                BoothLog.error(.config, "Saving the printer choice failed: \(error)")
            }
        }
        BoothLog.info(.printing, "Printer set to \(name)")
        config = cfg
        panelModel?.configApplied(cfg)
    }

    private func reloadConfig() {
        let (cfg, err) = ConfigLoader.load(path: options.configPath)
        if let err {
            BoothLog.error(.config, "Reload failed: \(err)")
            configError = err
            panelModel?.loadError = err
            controller?.raiseAttendant(.config(err.description))
            return
        }
        // Every successful reload (Ctrl+Opt+Cmd+R, Apply & Save) re-applies the profile, which
        // also fixes settings someone changed on the camera.
        camera?.setProfile(cfg.cameraProfile)
        panelModel?.configApplied(cfg)
        printModel?.configApplied(cfg)
        refreshStripBackground(cfg)  // also picks up edited artwork
        let wasError = configError != nil
        configError = nil
        guard cfg != config || wasError else { return }
        BoothLog.info(.config, "Config reloaded (lighting \(cfg.lighting.rawValue))")
        config = cfg
        FileLog.shared.configure(directory: cfg.outputRootURL.appendingPathComponent("logs", isDirectory: true))
        if let controller {
            controller.settings = BoothSettings(cfg)
            controller.sink = makeSink(cfg)
            controller.resolveAttendant(kind: "config")
            if let preview { preview.mirrored = cfg.mirrorPreview }
            if let preview { boothHost?.rootView = boothView(controller, preview) }
        }
        input?.reconfigure(key: cfg.key, mode: cfg.buttonInput, deviceFilter: cfg.buttonDevice)
        screensChanged()
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

    // MARK: Screens / layout

    private static let kioskLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

    static func displayID(_ s: NSScreen) -> UInt32 {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private static func descriptors() -> [ScreenDescriptor] {
        NSScreen.screens.enumerated().map { i, s in
            let id = displayID(s)
            return ScreenDescriptor(id: id, name: s.localizedName, frame: s.frame,
                                    isBuiltin: CGDisplayIsBuiltin(CGDirectDisplayID(id)) != 0, isMain: i == 0)
        }
    }

    private static func screen(_ d: ScreenDescriptor) -> NSScreen? {
        NSScreen.screens.first { displayID($0) == d.id }
    }

    private func computeLayout() -> ScreenLayout? {
        let l = ScreenLayout.compute(screens: Self.descriptors(), selection: config.display)
        if let l {
            switch l {
            case .singleScreen(let b): BoothLog.info(.ui, "Layout: single screen, booth on \(b)")
            case .twoScreen(let b, let p): BoothLog.info(.ui, "Layout: two screens, booth on \(b), control panel on \(p)")
            }
        }
        return l
    }

    /// Display added/removed/rearranged (or config reloaded): re-place and re-mode the windows.
    private func screensChanged() {
        BoothLog.info(.ui, "Screens: \(NSScreen.screens.map(\.localizedName))")
        let wasTwoScreen = presentation == .twoScreen
        let new = computeLayout()
        guard kiosk else { layout = new; return }
        layout = new
        placeWindow()
        if presentation == .twoScreen {
            if !wasTwoScreen {
                // TV plugged in: the panel moves to the laptop and the booth stops taking focus.
                showPanel()
                if let printWindow, printVisible {
                    printWindow.level = .normal
                    placePrintWindow(printWindow)
                }
            } else if let p = layout?.panel {
                if let panelWindow, panelVisible, panelScreenID != p.id { placePanel(panelWindow) }
                if let printWindow, printVisible, printScreenID != p.id { placePrintWindow(printWindow) }
            }
        } else if wasTwoScreen {
            // TV gone: the booth is back on this display, under the still-open windows.
            if panelVisible { panelWindow?.level = .floating }
            if printVisible { printWindow?.level = .floating }
        }
        updateBoothLevel()
        enforceKiosk()
    }

    /// Kiosk: cover the booth display completely; take key focus only in single-screen mode.
    private func placeWindow() {
        guard kiosk, let window, let layout else { return }
        let frame = Self.screen(layout.booth)?.frame ?? layout.booth.frame
        if window.frame != frame {
            BoothLog.info(.ui, "Placing booth on display \"\(layout.booth.name)\" \(frame)")
            window.setFrame(frame, display: true)
        }
        if let k = window as? KioskWindow {
            k.acceptsKey = presentation != .twoScreen
            if !k.acceptsKey, k.isKeyWindow { panelWindow?.makeKey() }
        }
    }

    /// Booth window level: kiosk level, except in single-screen mode while the attendant needs
    /// the rest of the screen (attendant screen, control panel open).
    private func updateBoothLevel() {
        guard kiosk, let window else { return }
        var level = Self.kioskLevel
        if presentation == .kiosk {
            let attendant: Bool = { if case .attendant = controller?.state { return true } else { return false } }()
            if attendant || attendantWindowVisible { level = .normal }
        }
        if window.level != level { window.level = level }
    }

    private func makeWindow() {
        if kiosk {
            let w = KioskWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = Self.kioskLevel
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isMovable = false
            w.hasShadow = false
            w.acceptsMouseMovedEvents = true
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
        window.delegate = self
        placeWindow()
    }

    private func maxScreenPixelDimension() -> CGFloat {
        let dims = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
        return max(1920, dims.max() ?? 3840)
    }

    // MARK: Control panel window

    @objc func showControlPanel(_ sender: Any?) { showPanel() }

    private func showPanel() {
        guard let model = panelModel else { return }
        let isNew = panelWindow == nil
        let w = panelWindow ?? makePanelWindow(model)
        if isNew {
            // Don't start with the cursor in a text field: an unseized button would type into it.
            DispatchQueue.main.async { w.makeFirstResponder(nil) }
        }
        // Single-screen kiosk: float above the (lowered) booth so a click on it doesn't bury the panel.
        w.level = presentation == .kiosk ? .floating : .normal
        if !w.isVisible || presentation == .twoScreen { placePanel(w) }
        model.refreshPhotos()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panelVisibilityChanged()
    }

    private func makePanelWindow(_ model: ControlPanelModel) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 800),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "PhotoBooth Control Panel"
        w.contentMinSize = NSSize(width: 460, height: 480)
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = true
        w.collectionBehavior = [.fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: ControlPanelView(model: model))
        w.delegate = self
        panelWindow = w
        return w
    }

    /// The display attendant windows go on: the panel display (two screens), else the booth's.
    private var attendantScreen: NSScreen? {
        switch presentation {
        case .twoScreen: return layout?.panel.flatMap(Self.screen)
        case .kiosk: return layout.flatMap { Self.screen($0.booth) }
        case .windowed: return window.screen ?? NSScreen.main
        }
    }

    /// Two-screen: centred on the panel display (once per display, so the attendant can move
    /// it). Single-screen: centred on the booth display. Windowed: beside the booth window.
    private func placePanel(_ w: NSWindow) {
        guard let target = attendantScreen else { return }
        let id = Self.displayID(target)
        if panelScreenID == id, w.frame.intersects(target.visibleFrame) { return }
        panelScreenID = id
        let vf = target.visibleFrame
        let size = NSSize(width: min(520, vf.width - 40), height: min(800, vf.height - 40))
        var origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
        if presentation == .windowed, window.frame.maxX + 12 + size.width <= vf.maxX {
            origin = NSPoint(x: window.frame.maxX + 12, y: max(vf.minY, window.frame.maxY - size.height))
        }
        BoothLog.info(.ui, "Placing control panel on display \"\(target.localizedName)\"")
        w.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: Print window

    @objc func showPrintWindow(_ sender: Any?) { showPrint() }

    /// Opened like the control panel (same display and levels); status polling runs only while
    /// it's open.
    private func showPrint() {
        guard let model = printModel else { return }
        let isNew = printWindow == nil
        let w = printWindow ?? makePrintWindow(model)
        if isNew {
            DispatchQueue.main.async { w.makeFirstResponder(nil) }
        }
        w.level = presentation == .kiosk ? .floating : .normal
        if !w.isVisible || presentation == .twoScreen { placePrintWindow(w) }
        model.opened()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panelVisibilityChanged()
    }

    private func makePrintWindow(_ model: PrintModel) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "PhotoBooth Print"
        w.contentMinSize = NSSize(width: 900, height: 640)
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = true
        w.collectionBehavior = [.fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: PrintView(model: model))
        w.delegate = self
        printWindow = w
        return w
    }

    /// Centred on the attendant display (once per display, like the panel).
    private func placePrintWindow(_ w: NSWindow) {
        guard let target = attendantScreen else { return }
        let id = Self.displayID(target)
        if printScreenID == id, w.frame.intersects(target.visibleFrame) { return }
        printScreenID = id
        let vf = target.visibleFrame
        let size = NSSize(width: min(1100, vf.width - 40), height: min(760, vf.height - 40))
        BoothLog.info(.ui, "Placing print window on display \"\(target.localizedName)\"")
        w.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === printWindow {
            printModel?.closed()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.panelVisibilityChanged() }
            }
        } else if w === panelWindow {
            // isVisible is still true during this callback.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.panelVisibilityChanged() }
            }
        } else if w === window, !kiosk {
            NSApp.terminate(nil)  // --windowed: closing the booth window quits, as before
        }
    }

    /// Panel or print window opened/closed. Single-screen kiosk: lower the booth and show the
    /// cursor while one is open; restore kiosk mode when the last one closes.
    private func panelVisibilityChanged() {
        updateBoothLevel()
        enforceKiosk()
        if presentation == .kiosk, !attendantWindowVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Cursor / kiosk presentation

    /// Re-assert the presentation for the current mode (after activation / screen changes).
    private func enforceKiosk() {
        guard kiosk else { return }
        switch presentation {
        case .kiosk:
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            boothHost?.hidesCursor = !attendantWindowVisible
            if attendantWindowVisible {
                setCursorHidden(false)
            } else {
                // Unhide + hide: macOS can show the cursor again after activation.
                setCursorHidden(false)
                setCursorHidden(true)
            }
        case .twoScreen:
            // The laptop stays usable: Dock and menu bar remain.
            NSApp.presentationOptions = []
            boothHost?.hidesCursor = true
            updatePointerCursor()
        case .windowed:
            break
        }
        if let v = window.contentView { window.invalidateCursorRects(for: v) }
    }

    /// Balanced hide/unhide (NSCursor keeps a count).
    private func setCursorHidden(_ hide: Bool) {
        guard hide != cursorHidden else { return }
        if hide { NSCursor.hide() } else { NSCursor.unhide() }
        cursorHidden = hide
    }

    /// Two-screen: the cursor is hidden only while it's over the TV.
    private func updatePointerCursor() {
        guard presentation == .twoScreen, let layout else { return }
        let frame = Self.screen(layout.booth)?.frame ?? layout.booth.frame
        setCursorHidden(NSMouseInRect(NSEvent.mouseLocation, frame, false))
    }

    /// Mouse-moved monitors: global (pointer over other apps' windows) and local (ours).
    private func installPointerMonitors() {
        guard pointerMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointerCursor() }
        }) {
            pointerMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointerCursor() }
            return event
        }) {
            pointerMonitors.append(l)
        }
    }

    // MARK: Menu

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        if !options.learnKey {
            let panel = NSMenuItem(title: "Control Panel…", action: #selector(showControlPanel(_:)), keyEquivalent: ",")
            panel.target = self
            appMenu.addItem(panel)
            let printItem = NSMenuItem(title: "Print…", action: #selector(showPrintWindow(_:)), keyEquivalent: "p")
            printItem.target = self
            appMenu.addItem(printItem)
            appMenu.addItem(.separator())
        }
        appMenu.addItem(withTitle: "Quit PhotoBooth", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Standard editing commands for the control panel's text fields.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = win
        return main
    }
}
