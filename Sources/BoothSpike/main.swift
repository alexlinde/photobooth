import Foundation
import ImageCaptureCore
import PTPKit
import SonyCamera

// Phase 0 spike: prove the ImageCaptureCore → Sony PTP path end to end.
//   booth-spike [--frames N] [--no-capture] [--out DIR] [--quiet-liveview]

struct Options {
    var frames = 30
    var capture = true
    var out = URL(fileURLWithPath: "spike-output")
    var quietLiveView = false

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--frames": frames = Int(it.next() ?? "") ?? frames
            case "--no-capture": capture = false
            case "--out": out = URL(fileURLWithPath: it.next() ?? out.path)
            case "--quiet-liveview": quietLiveView = true
            default: print("unknown argument \(a)"); exit(2)
            }
        }
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

Task { @MainActor in await run() }
RunLoop.main.run()
