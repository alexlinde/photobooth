import Foundation
import ImageCaptureCore
import PTPKit
import SonyCamera

// Phase 0 spike: prove the ImageCaptureCore → Sony PTP path end to end.
//   booth-spike [--frames N] [--no-capture] [--out DIR] [--quiet-liveview] [--set 0xCODE=VALUE ...]
//   (--set writes a property via SetControlDeviceA after the handshake and reports the read-back.)
// Phase 1 soak: run SonyBoothCamera for a while, capturing every 20 s.
//   booth-spike --soak SECONDS [--soak-fault] [--trace]

struct Options {
    var frames = 30
    var capture = true
    var out = URL(fileURLWithPath: "spike-output")
    var quietLiveView = false
    var soak: Int?
    var soakFault = false
    var trace = false
    var sets: [(code: UInt16, value: Int64)] = []

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--frames": frames = Int(it.next() ?? "") ?? frames
            case "--no-capture": capture = false
            case "--out": out = URL(fileURLWithPath: it.next() ?? out.path)
            case "--quiet-liveview": quietLiveView = true
            case "--soak": soak = Int(it.next() ?? "") ?? 120
            case "--soak-fault": soakFault = true
            case "--trace": trace = true
            case "--set":
                let kv = (it.next() ?? "").split(separator: "=").map(String.init)
                guard kv.count == 2, let code = Options.int(kv[0]).flatMap({ UInt16(exactly: $0) }),
                      let value = Options.int(kv[1]) else { print("--set wants 0xCODE=VALUE"); exit(2) }
                sets.append((code, value))
            default: print("unknown argument \(a)"); exit(2)
            }
        }
    }

    static func int(_ s: String) -> Int64? {
        s.hasPrefix("0x") ? Int64(s.dropFirst(2), radix: 16) : Int64(s)
    }
}

let start = ContinuousClock.now
func stamp() -> String {
    let ms = (ContinuousClock.now - start).components
    let t = Double(ms.seconds) + Double(ms.attoseconds) / 1e18
    return String(format: "[%8.3f]", t)
}
func say(_ s: String) { print("\(stamp()) \(s)"); fflush(stdout) }
func step(_ n: String) { print("\n\(stamp()) ===== \(n) ====="); fflush(stdout) }
func fail(_ what: String, _ error: Error) -> Never {
    print("\n\(stamp()) ✗ FAILED at \(what): \(error)")
    exit(1)
}

@MainActor
func run() async {
    let opts = Options(CommandLine.arguments)
    if let seconds = opts.soak {
        await soak(seconds: seconds, opts: opts)
    }
    let fixtures = opts.out.appendingPathComponent("fixtures")
    let frames = opts.out.appendingPathComponent("liveview")
    try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

    let transport = ICCTransport()
    transport.log = say
    let session = SonySession(transport: transport)
    session.log = say
    transport.onEvent = { session.receive($0) }
    transport.onDisconnect = { say("⚠️ camera disconnected") }

    // 2. Discovery + session
    step("1. Discover camera and open session")
    let camera: ICCameraDevice
    do { camera = try await transport.waitForCamera() } catch { fail("discovery", error) }
    say("camera: \(camera.name ?? "?") uuid=\(camera.uuidString ?? "?") transport=\(camera.transportType ?? "?")")
    do { try await transport.openSession(camera) } catch { fail("open session", error) }

    // 2. Sanity: standard GetDeviceInfo
    step("2. GetDeviceInfo (format check)")
    do {
        let r = try await transport.transact(PTPOperation.getDeviceInfo)
        try r.data.write(to: fixtures.appendingPathComponent("getdeviceinfo.bin"))
        if let di = DeviceInfo(r.data) {
            say("manufacturer=\(di.manufacturer) model=\(di.model) version=\(di.version) vendorExt=\(hex32(di.vendorExtensionID))")
            say("\(di.operations.count) operations; Sony SDIO ops present: \(di.operations.contains(PTPOperation.sonySDIOConnect))")
        }
    } catch { fail("GetDeviceInfo", error) }

    // 3. Sony handshake
    step("3. Sony PC Remote handshake")
    do { try await session.connect() } catch { fail("handshake", error) }
    say("handshake OK, protocol \(hex16(session.protocolVersion)), \(session.properties.count) properties parsed")

    // 3b. Property writes
    if !opts.sets.isEmpty {
        step("3b. Property writes")
        for (code, value) in opts.sets {
            guard let p = session.properties[code] else { say("\(hex16(code)): not reported by camera, skipped"); continue }
            let before = p.currentValue
            do {
                let v: PTPValue = value < 0 ? .int(value) : .uint(UInt64(value))
                try await session.setControlA(code, v, type: p.dataType)
                try await Task.sleep(for: .milliseconds(700))
                _ = try await session.refreshProperties()
                let after = session.properties[code]?.currentValue
                say("\(hex16(code)) getSet=\(p.getSet) enabled=\(p.isEnabled): \(before) → wrote \(value) → reads \(after.map { "\($0)" } ?? "?")"
                    + (after?.uint64 == v.uint64 ? "  ✓" : "  ✗ unchanged"))
            } catch { say("\(hex16(code)): write failed: \(error)") }
        }
    }

    // 4. Property dump
    step("4. Property dump")
    do {
        let r = try await transport.transact(PTPOperation.sonyGetAllDevicePropData)
        try r.data.write(to: fixtures.appendingPathComponent("getalldevicepropdata.bin"))
        let props = SonyPropertyParser.parse(r.data)
        var lines: [String] = []
        for code in props.keys.sorted() {
            let p = props[code]!
            lines.append("\(hex16(code)) type=\(hex16(p.dataType)) getSet=\(p.getSet) enabled=\(p.isEnabled) current=\(p.currentValue) form=\(p.form)")
        }
        try lines.joined(separator: "\n").write(to: opts.out.appendingPathComponent("properties.txt"), atomically: true, encoding: .utf8)
        say("wrote \(props.count) properties to properties.txt")
        let interesting: [(String, UInt16)] = [
            ("FocusMode", SonyProperty.focusMode), ("ShutterSpeed", SonyProperty.shutterSpeed),
            ("ObjectInMemory", SonyProperty.objectInMemory), ("LiveViewStatus", SonyProperty.liveViewStatus),
            ("StillImageStoreDestination", SonyProperty.stillImageStoreDestination),
            ("LiveViewSettingEffect", SonyProperty.liveViewSettingEffect), ("PriorityMode", SonyProperty.priorityMode),
        ]
        for (name, code) in interesting {
            let p = props[code]
            say("  \(name) \(hex16(code)): \(p.map { "\($0.currentValue) form=\($0.form)" } ?? "absent")")
        }
    } catch { fail("property dump", error) }

    // 5. Live view
    step("5. Live view: \(opts.frames) frames")
    transport.traceTransactions = !opts.quietLiveView
    do {
        try await session.waitForLiveView()
        // Save one raw payload as a parser fixture.
        var raw: PTPResponse?
        for _ in 0..<50 {
            let r = try await transport.send(PTPOperation.getObject, parameters: [SonyHandle.liveView], outData: nil)
            if r.isOK { raw = r; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let raw else { throw PTPError.captureFailed("live view never became available") }
        try raw.data.write(to: fixtures.appendingPathComponent("liveview-raw.bin"))
        let off = raw.data.count >= 4 ? raw.data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } : 0
        say("raw live-view payload \(raw.data.count) bytes, header u32[0]=\(off)")

        var got = 0, misses = 0
        var sizes: [Int] = []
        let t0 = ContinuousClock.now
        while got < opts.frames {
            if let jpeg = try await session.liveViewFrame() {
                got += 1
                sizes.append(jpeg.count)
                try jpeg.write(to: frames.appendingPathComponent(String(format: "frame-%03d.jpg", got)))
            } else {
                misses += 1
                if misses > opts.frames * 20 { throw PTPError.captureFailed("too many live-view misses") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let elapsed = ContinuousClock.now - t0
        let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        transport.traceTransactions = true
        say(String(format: "✓ %d frames in %.2fs = %.1f fps (%d not-ready responses), avg %d KB/frame",
                   got, secs, Double(got) / secs, misses, sizes.reduce(0, +) / max(sizes.count, 1) / 1024))
        if let first = try? Data(contentsOf: frames.appendingPathComponent("frame-001.jpg")),
           let src = CGImageSourceCreateWithData(first as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            say("frame size \(img.width)x\(img.height)")
        }
    } catch { fail("live view", error) }

    // 6. Capture
    if opts.capture {
        step("6. Capture (strobes should fire)")
        do {
            let (data, name, timing) = try await session.capture()
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let url = opts.out.appendingPathComponent("capture-\(fmt.string(from: Date())).jpg")
            try data.write(to: url)
            say("✓ captured \(name ?? "?"), \(data.count / 1024) KB → \(url.path)")
            say("timing: \(timing)")
            if let src = CGImageSourceCreateWithData(data as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
                let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
                say("image \(props[kCGImagePropertyPixelWidth as String] ?? "?")x\(props[kCGImagePropertyPixelHeight as String] ?? "?")"
                    + " exposure=\(exif?[kCGImagePropertyExifExposureTime as String] ?? "?")"
                    + " f=\(exif?[kCGImagePropertyExifFNumber as String] ?? "?")"
                    + " ISO=\(exif?[kCGImagePropertyExifISOSpeedRatings as String] ?? "?")"
                    + " flash=\(exif?[kCGImagePropertyExifFlash as String] ?? "?")")
            }

            // Live view must survive a capture.
            var resumed = false
            for _ in 0..<100 {
                if try await session.liveViewFrame() != nil { resumed = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            say(resumed ? "✓ live view resumed after capture" : "⚠️ live view did not resume after capture")
        } catch { fail("capture", error) }
    }

    transport.closeSession()
    step("SPIKE PASSED")
    exit(0)
}

/// Minimal ISO 15740 DeviceInfo parser for the sanity check.
struct DeviceInfo {
    var vendorExtensionID: UInt32
    var operations: [UInt16]
    var manufacturer: String
    var model: String
    var version: String

    init?(_ data: Data) {
        var r = PTPReader(data)
        do {
            _ = try r.u16()
            vendorExtensionID = try r.u32()
            _ = try r.u16()
            _ = try r.string()
            _ = try r.u16()
            operations = try r.array { try $0.u16() }
            _ = try r.array { try $0.u16() }  // events
            _ = try r.array { try $0.u16() }  // props
            _ = try r.array { try $0.u16() }  // capture formats
            _ = try r.array { try $0.u16() }  // image formats
            manufacturer = try r.string()
            model = try r.string()
            version = try r.string()
        } catch { return nil }
    }
}

// MARK: - Soak

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// Runs SonyBoothCamera for `seconds`: prints state changes and live-view fps every 5 s, does a
/// prepare → 3 s → capture cycle every 20 s, and (with --soak-fault) injects a closed session at
/// ~1/3 and a hung transaction at ~2/3 of the run, reporting how long recovery took.
@MainActor
func soak(seconds total: Int, opts: Options) async {
    let dir = opts.out.appendingPathComponent("soak")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    step("SOAK \(total)s\(opts.soakFault ? " with fault injection" : "")")

    var o = SonyBoothCamera.Options()
    o.log = { say("  \($0)") }
    o.traceTransactions = opts.trace
    let camera = SonyBoothCamera(options: o)

    var frames = 0
    var readyAt: [ContinuousClock.Instant] = []
    let stateTask = Task { @MainActor in
        for await s in camera.stateUpdates() {
            say("STATE \(s)")
            if s.isReady { readyAt.append(.now) }
        }
    }
    let frameTask = Task { @MainActor in
        for await _ in camera.liveViewFrames() { frames += 1 }
    }
    camera.start()

    let t0 = ContinuousClock.now
    let end = t0 + .seconds(total)
    var faults: [(SonyBoothCamera.SimulatedFault, ContinuousClock.Instant)] = opts.soakFault
        ? [(.sessionClosed, t0 + .seconds(total / 3 + 5)), (.transactionHang, t0 + .seconds(2 * total / 3 + 5))]
        : []
    var faultLog: [(SonyBoothCamera.SimulatedFault, ContinuousClock.Instant)] = []
    var nextReport = t0 + .seconds(5)
    var lastFrames = 0, lastFetched = 0, lastNotReady = 0
    var nextCapture = t0 + .seconds(20)
    var captureTask: Task<Void, Never>?
    var captures = 0, failures = 0
    var timings: [SonySession.CaptureTiming] = []
    var countdownFps: [Double] = []
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd-HHmmss"

    while ContinuousClock.now < end {
        try? await Task.sleep(for: .milliseconds(100))
        let now = ContinuousClock.now

        if now >= nextReport {
            let f = frames - lastFrames, fetched = camera.liveViewFramesFetched - lastFetched
            let nr = camera.liveViewNotReady - lastNotReady
            say(String(format: "[t=%3.0fs] %@ — live view %.1f fps delivered (%.1f fetched, %d not-ready)",
                       seconds(now - t0), "\(camera.state)", Double(f) / 5, Double(fetched) / 5, nr))
            lastFrames = frames; lastFetched = camera.liveViewFramesFetched; lastNotReady = camera.liveViewNotReady
            nextReport += .seconds(5)
        }

        if let (fault, at) = faults.first, now >= at, captureTask == nil, camera.state.isReady {
            faults.removeFirst()
            faultLog.append((fault, now))
            camera.simulateFault(fault)
        }

        if now >= nextCapture, captureTask == nil, camera.state.isReady, now + .seconds(6) < end {
            nextCapture = now + .seconds(20)
            captureTask = Task { @MainActor in
                defer { captureTask = nil }
                say("CAPTURE: prepare (half-press), 3 s countdown")
                let f0 = frames
                await camera.prepareCapture()
                try? await Task.sleep(for: .seconds(3))
                countdownFps.append(Double(frames - f0) / 3)
                say(String(format: "CAPTURE: %.1f fps during countdown (live view while half-pressed)", Double(frames - f0) / 3))
                do {
                    let photo = try await camera.capture()
                    captures += 1
                    let url = dir.appendingPathComponent("\(fmt.string(from: photo.capturedAt))-\(photo.cameraFilename ?? "photo.jpg")")
                    try? photo.jpeg.write(to: url)
                    if let t = camera.lastCaptureTiming { timings.append(t) }
                    say("CAPTURE ✓ #\(captures) \(photo.cameraFilename ?? "?") \(photo.jpeg.count / 1024) KB → \(url.lastPathComponent)")
                } catch {
                    failures += 1
                    say("CAPTURE ✗ \(error)")
                }
            }
        }
    }
    await captureTask?.value

    step("SOAK SUMMARY")
    say("captures: \(captures) ok, \(failures) failed; connections: \(camera.connectCount)")
    say(String(format: "live view: %d frames delivered over %ds = %.1f fps average; countdown fps %@",
               frames, total, Double(frames) / Double(total),
               countdownFps.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
    for (i, t) in timings.enumerated() { say("  capture \(i + 1): \(t)") }
    for (fault, at) in faultLog {
        if let back = readyAt.first(where: { $0 > at }) {
            say(String(format: "fault %@ at t=%.1fs → ready again after %.2fs", "\(fault)", seconds(at - t0), seconds(back - at)))
        } else {
            say("fault \(fault) at t=\(seconds(at - t0))s → NOT recovered")
        }
    }
    camera.stop()
    stateTask.cancel()
    frameTask.cancel()
    let recovered = faultLog.allSatisfy { f in readyAt.contains { $0 > f.1 } }
    exit(failures == 0 && captures > 0 && recovered ? 0 : 1)
}

Task { @MainActor in await run() }
RunLoop.main.run()
