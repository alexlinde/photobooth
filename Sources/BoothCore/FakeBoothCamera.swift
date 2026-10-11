import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SonyCamera
import UniformTypeIdentifiers

/// A `BoothCamera` that needs no hardware (`--fake-camera`). Generates animated 1024x576
/// live-view frames at 30 fps, connects after ~1 s, and returns a generated full-res JPEG
/// from `capture()` after ~300 ms. Failure and disconnect can be simulated.
@MainActor
public final class FakeBoothCamera: BoothCamera {
    public struct Options {
        public init() {}
        var connectDelay = 1.0
        var captureDelay = 0.3
        /// Probability that a capture throws (`--fake-fail-rate`).
        public var failRate = 0.0
        /// Generate live-view frames (off in the self-test).
        var generateFrames = true
        var frameSize = CGSize(width: 1024, height: 576)
        var captureSize = CGSize(width: 6000, height: 3376)
        var name = "Fake ZV-E10"
    }

    public private(set) var state: CameraConnectionState = .searching
    var options: Options
    /// Fail the next N captures regardless of `failRate` (tests).
    var scriptedFailures = 0
    /// Return an all-black JPEG for the next N captures, like a missed flash (tests).
    var scriptedBlackFrames = 0
    private(set) var prepareCount = 0
    private(set) var cancelPrepareCount = 0
    private(set) var captureCount = 0
    private var halfPressed = false
    private var capturing = false { didSet { updateLiveView() } }

    /// Live view runs while ready, paused during capture (like the real camera).
    private func updateLiveView() { frames.active = state.isReady && !capturing }

    private let clock: BoothClock
    private var stateContinuations: [UUID: AsyncStream<CameraConnectionState>.Continuation] = [:]
    private let frames = FrameBroadcaster()
    private var connectTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var shotNumber = 0

    public init(options: Options = Options(), clock: BoothClock) {
        self.options = options
        self.clock = clock
    }

    public func stateUpdates() -> AsyncStream<CameraConnectionState> {
        let id = UUID()
        let (stream, cont) = AsyncStream<CameraConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(16))
        cont.yield(state)
        stateContinuations[id] = cont
        cont.onTermination = { _ in Task { @MainActor [weak self] in self?.stateContinuations[id] = nil } }
        return stream
    }

    public func liveViewFrames() -> AsyncStream<CGImage> { frames.makeStream() }

    public func start() {
        BoothLog.info(.camera, "Fake camera starting")
        if options.generateFrames { startFrames() }
        connect()
    }

    public func stop() {
        connectTask?.cancel()
        frameTask?.cancel()
        frameTask = nil
        setState(.searching)
    }

    /// Simulates an unplug: searching for ~2 s, then reconnects.
    public func simulateDisconnect(reconnectAfter seconds: Double = 2) {
        BoothLog.info(.camera, "Fake camera: simulated disconnect")
        connectTask?.cancel()
        setState(.searching)
        connectTask = Task { [weak self] in
            do { try await self?.clock.sleep(seconds: seconds) } catch { return }
            self?.connect()
        }
    }

    /// Directly set the state (tests).
    func setState(_ s: CameraConnectionState) {
        guard s != state else { return }
        state = s
        updateLiveView()
        for c in stateContinuations.values { c.yield(s) }
        if s.isReady {
            applyProfile()
        } else {
            profileTask?.cancel()
            updateStatus { $0.applyingProfile = false; $0.lastReport = nil; $0.readout = nil }
        }
    }

    // MARK: Profile (every requested setting "applies"; the readout echoes the profile)

    public private(set) var status = CameraStatus()
    private var statusContinuations: [UUID: AsyncStream<CameraStatus>.Continuation] = [:]
    private var profileTask: Task<Void, Never>?
    /// Profile apply duration (the real camera takes a couple of seconds for a mode change).
    var profileApplyDelay = 0.3

    public func statusUpdates() -> AsyncStream<CameraStatus> {
        let id = UUID()
        let (stream, cont) = AsyncStream<CameraStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        cont.yield(status)
        statusContinuations[id] = cont
        cont.onTermination = { _ in Task { @MainActor [weak self] in self?.statusContinuations[id] = nil } }
        return stream
    }

    public func setProfile(_ profile: CameraProfile?) {
        updateStatus { $0.profile = profile }
        if state.isReady { applyProfile() }
    }

    private func updateStatus(_ change: (inout CameraStatus) -> Void) {
        var s = status
        change(&s)
        guard s != status else { return }
        status = s
        for c in statusContinuations.values { c.yield(s) }
    }

    private func applyProfile() {
        profileTask?.cancel()
        guard let p = status.profile else {
            updateStatus { $0.lastReport = nil; $0.readout = CameraReadout(batteryPercent: 100) }
            return
        }
        updateStatus { $0.applyingProfile = true }
        profileTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(seconds: self.profileApplyDelay) } catch { return }
            let items = Self.describe(p).map { CameraProfileReport.Item(setting: $0.0, requested: $0.1, outcome: .applied) }
            self.updateStatus {
                $0.applyingProfile = false
                $0.lastReport = CameraProfileReport(profileName: p.name, items: items, finishedAt: Date())
                $0.readout = CameraReadout(
                    exposureMode: p.exposureMode?.rawValue, shutterSpeed: p.shutterSpeed?.description,
                    aperture: p.aperture.map { String(format: "f/%g", $0) },
                    iso: p.iso.map { if case .value(let v) = $0 { return "\(v)" } else { return "Auto" } },
                    flashMode: p.flashMode?.rawValue, focusMode: p.focusMode?.rawValue, batteryPercent: 100)
            }
        }
    }

    private static func describe(_ p: CameraProfile) -> [(String, String)] {
        var out: [(String, String)] = []
        if let v = p.exposureMode { out.append(("Exposure mode", v.rawValue)) }
        if let v = p.shutterSpeed { out.append(("Shutter speed", v.description)) }
        if let v = p.aperture { out.append(("Aperture", String(format: "f/%g", v))) }
        if let v = p.iso { out.append(("ISO", { if case .value(let i) = v { return "\(i)" } else { return "Auto" } }())) }
        if let v = p.exposureCompensation { out.append(("Exposure compensation", String(format: "%+.1f EV", v))) }
        if let v = p.flashMode { out.append(("Flash mode", v.rawValue)) }
        if let v = p.flashCompensation { out.append(("Flash compensation", String(format: "%+.1f EV", v))) }
        if let v = p.focusMode { out.append(("Focus mode", v.rawValue)) }
        if let v = p.whiteBalance { out.append(("White balance", v.rawValue)) }
        if let v = p.liveViewSettingEffect { out.append(("Live view Setting Effect", v ? "On" : "Off")) }
        return out
    }

    private func connect() {
        connectTask?.cancel()
        setState(.connecting(name: options.name))
        connectTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(seconds: self.options.connectDelay) } catch { return }
            self.setState(.ready(name: self.options.name))
        }
    }

    public func prepareCapture() async {
        guard state.isReady else { return }
        prepareCount += 1
        halfPressed = true
    }

    public func cancelPrepare() async {
        cancelPrepareCount += 1
        halfPressed = false
    }

    public func capture() async throws -> CapturedPhoto {
        guard state.isReady else { throw BoothCameraError.notReady }
        guard !capturing else { throw BoothCameraError.captureInProgress }
        capturing = true
        defer { capturing = false; halfPressed = false }
        captureCount += 1
        shotNumber += 1
        let shot = shotNumber
        let size = options.captureSize
        let started = clock.now()
        // Generate off the main thread while the simulated shutter delay runs.
        let black = scriptedBlackFrames > 0
        if black { scriptedBlackFrames -= 1 }
        let gen = Task.detached(priority: .userInitiated) {
            black ? FakeImages.blackJPEG(size: size) : FakeImages.captureJPEG(size: size, shot: shot, at: started)
        }
        try await clock.sleep(seconds: options.captureDelay)
        let jpeg = await gen.value
        let fail: Bool
        if scriptedFailures > 0 { scriptedFailures -= 1; fail = true } else { fail = Double.random(in: 0..<1) < options.failRate }
        if fail {
            BoothLog.info(.camera, "Fake camera: simulated capture failure")
            throw BoothCameraError.captureFailed("Simulated capture failure")
        }
        guard let jpeg else { throw BoothCameraError.captureFailed("Could not generate fake JPEG") }
        return CapturedPhoto(jpeg: jpeg, cameraFilename: String(format: "DSC%05d.JPG", shot), capturedAt: started)
    }

    private func startFrames() {
        guard frameTask == nil else { return }
        let frames = self.frames
        let size = options.frameSize
        let t0 = Date()
        frameTask = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                let start = Date()
                if frames.active, let img = FakeImages.liveFrame(size: size, t: start.timeIntervalSince(t0)) {
                    frames.yield(img)
                }
                let elapsed = Date().timeIntervalSince(start)
                try? await Task.sleep(nanoseconds: UInt64(max(0.001, 1.0 / 30 - elapsed) * 1_000_000_000))
            }
        }
    }
}

/// Fan-out of newest-frame streams; thread-safe.
public final class FrameBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<CGImage>.Continuation] = [:]
    private var _active = false
    var active: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _active }
        set { lock.lock(); _active = newValue; lock.unlock() }
    }

    func makeStream() -> AsyncStream<CGImage> {
        let id = UUID()
        let (stream, cont) = AsyncStream<CGImage>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.lock(); continuations[id] = cont; lock.unlock()
        cont.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.continuations[id] = nil; self.lock.unlock()
        }
        return stream
    }

    func yield(_ img: CGImage) {
        lock.lock(); let conts = Array(continuations.values); lock.unlock()
        for c in conts { c.yield(img) }
    }
}

/// CoreGraphics drawing for the fake camera.
public enum FakeImages {
    static func liveFrame(size: CGSize, t: Double) -> CGImage? {
        guard let ctx = makeContext(size) else { return nil }
        let w = size.width, h = size.height
        // Moving two-colour gradient.
        let hue = (t / 12).truncatingRemainder(dividingBy: 1)
        drawGradient(ctx, size: size, hue: hue, angle: t * 0.4)
        // A "face" bobbing around so motion and mirroring are visible.
        let cx = w * (0.5 + 0.25 * sin(t * 0.9)), cy = h * (0.5 + 0.15 * cos(t * 1.3))
        ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.6, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: cx - 90, y: cy - 110, width: 180, height: 220))
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: cx - 45, y: cy + 20, width: 22, height: 28))
        ctx.fillEllipse(in: CGRect(x: cx + 23, y: cy + 20, width: 22, height: 28))
        ctx.setLineWidth(8)
        ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
        ctx.addArc(center: CGPoint(x: cx, y: cy - 20), radius: 45, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
        ctx.strokePath()
        // Clock text and a "LEFT" marker (reads backwards when the preview is mirrored).
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SS"
        drawText(ctx, "FAKE CAMERA  " + f.string(from: Date()), at: CGPoint(x: 24, y: h - 60), size: 34)
        drawText(ctx, "◀ LEFT", at: CGPoint(x: 24, y: 24), size: 40)
        return ctx.makeImage()
    }

    static func captureJPEG(size: CGSize, shot: Int, at date: Date) -> Data? {
        guard let ctx = makeContext(size) else { return nil }
        drawGradient(ctx, size: size, hue: Double(shot % 7) / 7, angle: Double(shot))
        let s = size.height / 576
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        drawText(ctx, "Fake photo #\(shot)", at: CGPoint(x: 60 * s, y: size.height / 2), size: 90 * s)
        drawText(ctx, f.string(from: date), at: CGPoint(x: 60 * s, y: size.height / 2 - 110 * s), size: 50 * s)
        drawText(ctx, "◀ LEFT (not mirrored)", at: CGPoint(x: 30 * s, y: 30 * s), size: 40 * s)
        return ctx.makeImage().flatMap(jpeg)
    }

    /// What the camera returns when the strobes don't fire against a black backdrop.
    static func blackJPEG(size: CGSize) -> Data? { solidJPEG(size: size, gray: 0) }

    /// One flat grey (0–1) all over (tests).
    static func solidJPEG(size: CGSize, gray: CGFloat) -> Data? {
        guard let ctx = makeContext(size) else { return nil }
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage().flatMap(jpeg)
    }

    static func jpeg(_ img: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func makeContext(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    private static func drawGradient(_ ctx: CGContext, size: CGSize, hue: Double, angle: Double) {
        let c1 = hsv(hue, 0.55, 0.75), c2 = hsv((hue + 0.35).truncatingRemainder(dividingBy: 1), 0.6, 0.45)
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c1, c2] as CFArray, locations: [0, 1]) else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = max(size.width, size.height) / 2
        let d = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
        ctx.drawLinearGradient(g, start: CGPoint(x: c.x - d.x, y: c.y - d.y), end: CGPoint(x: c.x + d.x, y: c.y + d.y), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func drawText(_ ctx: CGContext, _ s: String, at p: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.95),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    private static func hsv(_ h: Double, _ s: Double, _ v: Double) -> CGColor {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }
}
