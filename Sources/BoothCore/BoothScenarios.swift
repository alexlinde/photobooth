import Foundation
import SonyCamera

/// Scripted scenarios for the booth state machine, config and key mapping. Run by
/// `PhotoBooth --self-test`, and intended to be called from XCTest once a `BoothCore`
/// library target exists (see Tests/PhotoBoothTests/BoothCoreTests.swift).
///
/// Uses the fake camera and a manual clock, so the whole suite takes about a second.
@MainActor
public enum BoothScenarios {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("happy path, 1 shot", happyPathOneShot),
        ("3 shots per press", threeShots),
        ("press during countdown is ignored", pressDuringCountdownIgnored),
        ("debounce", debounce),
        ("capture failure → message → idle", captureFailureThenIdle),
        ("3 failures → attendant (reset key, and reconnect clears it)", threeFailuresAttendant),
        ("camera drops mid-idle → waiting → ready → idle", cameraDropMidIdle),
        ("camera drops during countdown → waiting, half-press released", cameraDropDuringCountdown),
        ("storage failure → attendant → retry clears", storageFailure),
        ("local photo sink naming / collisions", localSinkNaming),
        ("config parsing and defaults", configParsing),
        ("key name mapping", keyMapping),
    ]

    /// Runs everything; prints results; returns true when all pass.
    public static func runAll() async -> Bool {
        var failed = 0
        for (name, run) in all {
            do {
                try await run()
                print("PASS  \(name)")
            } catch {
                failed += 1
                print("FAIL  \(name)\n      \(error)")
            }
        }
        print(failed == 0 ? "\nAll \(all.count) scenarios passed." : "\n\(failed) of \(all.count) scenarios FAILED.")
        return failed == 0
    }

    // MARK: Harness

    final class TestSink: PhotoSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _failing = false
        private var _stored: [CapturedPhoto] = []
        var failing: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _failing }
            set { lock.lock(); _failing = newValue; lock.unlock() }
        }
        var storedCount: Int { lock.lock(); defer { lock.unlock() }; return _stored.count }

        func store(_ photo: CapturedPhoto) async throws -> URL { try storeSync(photo) }

        private func storeSync(_ photo: CapturedPhoto) throws -> URL {
            lock.lock(); defer { lock.unlock() }
            if _failing { throw CocoaError(.fileWriteOutOfSpace) }
            _stored.append(photo)
            return URL(fileURLWithPath: "/tmp/test-\(_stored.count).jpg")
        }
    }

    @MainActor
    final class Harness {
        let clock = ManualBoothClock()
        let camera: FakeBoothCamera
        let sink = TestSink()
        let controller: BoothController
        var history: [String] = []

        init(settings: BoothSettings = BoothSettings()) {
            var o = FakeBoothCamera.Options()
            o.generateFrames = false
            o.captureSize = CGSize(width: 64, height: 36)
            camera = FakeBoothCamera(options: o, clock: clock)
            controller = BoothController(camera: camera, sink: sink, clock: clock, settings: settings,
                                         decodeForReview: { _ in nil })
            history.append(controller.state.label)
            controller.onStateChange = { [weak self] s in self?.history.append(s.label) }
        }

        var label: String { controller.state.label }

        /// Lets main-actor work and off-main hops (sink, decode) finish without moving time.
        func pump() async {
            await clock.settle()
            try? await Task.sleep(nanoseconds: 2_000_000)
            await clock.settle()
        }

        /// Starts the booth and waits for the fake camera to connect.
        func startReady() async throws {
            controller.start()
            try await step(until: "idle", within: 3)
        }

        /// Advances the clock in small steps until the state label matches.
        func step(until target: String, within seconds: Double = 30) async throws {
            try await step(within: seconds, until: { $0 == target }, describe: target)
        }

        func step(within seconds: Double, until match: (String) -> Bool, describe: String) async throws {
            var t = 0.0
            await pump()
            while !match(label) {
                guard t < seconds else {
                    throw Failure(description: "timed out waiting for \(describe); state \(label); history \(history)")
                }
                await clock.advance(by: 0.1)
                t += 0.1
                await pump()
            }
        }

        func advance(_ seconds: Double) async {
            await clock.advance(by: seconds)
            await pump()
        }

        func press(expect expected: PressResult, _ file: String = #fileID, _ line: Int = #line) throws {
            let r = controller.buttonPressed()
            guard r == expected else {
                throw Failure(description: "press at \(file):\(line): expected \(expected), got \(r) (state \(label))")
            }
        }
    }

    static func check(_ cond: @autoclosure () -> Bool, _ msg: @autoclosure () -> String, _ file: String = #fileID, _ line: Int = #line) throws {
        if !cond() { throw Failure(description: "\(file):\(line): \(msg())") }
    }

    // MARK: Scenarios

    static func happyPathOneShot() async throws {
        let h = Harness()
        try await h.startReady()
        try h.press(expect: .accepted)
        await h.pump()
        try check(h.label == "countdown(3,1/1)", "expected countdown 3, got \(h.label)")
        try check(h.camera.prepareCount == 1, "prepareCapture called \(h.camera.prepareCount)x at countdown start")
        try await h.step(until: "review(1/1)")
        try check(h.sink.storedCount == 1, "stored \(h.sink.storedCount) photos")
        try await h.step(until: "idle")
        let expected = ["waiting", "idle", "countdown(3,1/1)", "countdown(2,1/1)", "countdown(1,1/1)",
                        "capturing(1/1)", "review(1/1)", "idle"]
        // Collapse repeats (e.g. waiting "Looking…" → waiting "Connecting…").
        let collapsed = h.history.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        try check(collapsed == expected, "history \(collapsed) != \(expected)")
        try check(h.camera.captureCount == 1, "captureCount \(h.camera.captureCount)")
    }

    static func threeShots() async throws {
        var s = BoothSettings()
        s.shotsPerPress = 3
        let h = Harness(settings: s)
        try await h.startReady()
        try h.press(expect: .accepted)
        try await h.step(until: "review(1/3)")
        try await h.step(until: "between(2/3)")
        try await h.step(until: "review(3/3)", within: 40)
        try await h.step(until: "idle")
        try check(h.sink.storedCount == 3, "stored \(h.sink.storedCount)")
        try check(h.camera.prepareCount == 3, "prepareCount \(h.camera.prepareCount)")
        let keyStates = h.history.filter { $0.hasPrefix("review") || $0.hasPrefix("between") || $0.hasPrefix("capturing") }
        let expected = ["capturing(1/3)", "review(1/3)", "between(2/3)", "capturing(2/3)", "review(2/3)",
                        "between(3/3)", "capturing(3/3)", "review(3/3)"]
        try check(keyStates == expected, "sequence \(keyStates)")
    }

    static func pressDuringCountdownIgnored() async throws {
        let h = Harness()
        try await h.startReady()
        try h.press(expect: .accepted)
        await h.advance(1.5)
        try check(h.label.hasPrefix("countdown"), "expected countdown, got \(h.label)")
        try h.press(expect: .ignored(h.label))
        try await h.step(until: "capturing(1/1)")
        try h.press(expect: .ignored("capturing(1/1)"))
        try await h.step(until: "idle")
        try check(h.camera.captureCount == 1, "captureCount \(h.camera.captureCount)")
        try check(h.sink.storedCount == 1, "stored \(h.sink.storedCount)")
        try check(h.history.filter { $0 == "countdown(3,1/1)" }.count == 1, "countdown restarted: \(h.history)")
    }

    static func debounce() async throws {
        let h = Harness() // debounce 0.4 s, review 5 s
        try await h.startReady()
        try h.press(expect: .accepted)
        try h.press(expect: .debounced)
        try await h.step(until: "review(1/1)")
        await h.advance(4.8)
        try h.press(expect: .ignored("review(1/1)")) // records the raw press time
        try await h.step(until: "idle", within: 1)   // review ends 0.2 s later
        try h.press(expect: .debounced)              // within 0.4 s of the last raw press
        await h.advance(0.3)
        try h.press(expect: .accepted)
    }

    static func captureFailureThenIdle() async throws {
        let h = Harness()
        try await h.startReady()
        h.camera.scriptedFailures = 1
        try h.press(expect: .accepted)
        try await h.step(until: "notice")
        if case .notice(let msg) = h.controller.state {
            try check(msg.contains("try that again"), "notice text \(msg)")
        }
        try check(h.controller.consecutiveFailures == 1, "failures \(h.controller.consecutiveFailures)")
        try h.press(expect: .ignored("notice"))
        try await h.step(until: "idle", within: 5)
        try check(h.sink.storedCount == 0, "stored \(h.sink.storedCount)")
        // A success resets the failure counter.
        try h.press(expect: .accepted)
        try await h.step(until: "review(1/1)")
        try check(h.controller.consecutiveFailures == 0, "failures not reset")
    }

    static func threeFailuresAttendant() async throws {
        let h = Harness()
        try await h.startReady()
        func failThree() async throws {
            h.camera.scriptedFailures = 3
            for i in 1...3 {
                try h.press(expect: .accepted)
                try await h.step(within: 10, until: { $0 == "notice" || $0.hasPrefix("attendant") }, describe: "failure \(i)")
                if i < 3 {
                    try check(h.label == "notice", "failure \(i): \(h.label)")
                    try await h.step(until: "idle")
                }
            }
            try check(h.label == "attendant(captureFailures)", "expected attendant, got \(h.label)")
            try h.press(expect: .ignored("attendant(captureFailures)"))
        }
        try await failThree()
        // Attendant key clears it.
        h.controller.attendantReset()
        await h.pump()
        try check(h.label == "idle", "after reset: \(h.label)")
        try check(h.controller.consecutiveFailures == 0, "failures not reset")
        // Again; this time a camera reconnect clears it.
        await h.advance(1)
        try await failThree()
        h.camera.setState(.searching)
        await h.pump()
        try check(h.label == "attendant(captureFailures)", "should stay on attendant while camera away: \(h.label)")
        h.camera.setState(.ready(name: "Fake"))
        await h.pump()
        try check(h.label == "idle", "after reconnect: \(h.label)")
    }

    static func cameraDropMidIdle() async throws {
        let h = Harness()
        try await h.startReady()
        h.camera.setState(.searching)
        await h.pump()
        try check(h.controller.state == .waitingForCamera(status: "Looking for the camera…"), "state \(h.controller.state)")
        try h.press(expect: .ignored("waiting"))
        h.camera.setState(.connecting(name: "ZV-E10"))
        await h.pump()
        try check(h.controller.state == .waitingForCamera(status: "Connecting to ZV-E10…"), "state \(h.controller.state)")
        h.camera.setState(.recovering(reason: "USB error"))
        await h.pump()
        try check(h.label == "waiting", "state \(h.label)")
        h.camera.setState(.ready(name: "ZV-E10"))
        await h.pump()
        try check(h.label == "idle", "state \(h.label)")
        await h.advance(1)
        // Simulated disconnect auto-reconnects (2 s searching + 1 s connecting).
        h.camera.simulateDisconnect()
        await h.pump()
        try check(h.label == "waiting", "state \(h.label)")
        try await h.step(until: "idle", within: 5)
    }

    static func cameraDropDuringCountdown() async throws {
        let h = Harness()
        try await h.startReady()
        try h.press(expect: .accepted)
        await h.advance(1.2)
        h.camera.setState(.searching)
        await h.pump()
        try check(h.label == "waiting", "state \(h.label)")
        try check(h.camera.cancelPrepareCount == 1, "cancelPrepare called \(h.camera.cancelPrepareCount)x")
        await h.advance(5) // the aborted session must not resume
        try check(h.label == "waiting", "state \(h.label)")
        try check(h.camera.captureCount == 0, "captured \(h.camera.captureCount)")
        h.camera.setState(.ready(name: "Fake"))
        await h.pump()
        try check(h.label == "idle", "state \(h.label)")
        try h.press(expect: .accepted)
        try await h.step(until: "idle")
        try check(h.sink.storedCount == 1, "stored \(h.sink.storedCount)")
    }

    static func storageFailure() async throws {
        let h = Harness()
        try await h.startReady()
        h.sink.failing = true
        try h.press(expect: .accepted)
        try await h.step(until: "attendant(storage)")
        try check(h.controller.unsavedPhotos.count == 1, "unsaved \(h.controller.unsavedPhotos.count)")
        // Attendant key while still failing: stays.
        h.controller.attendantReset()
        await h.pump()
        try check(h.label == "attendant(storage)", "state \(h.label)")
        // Fixed + attendant key → saved and idle.
        h.sink.failing = false
        h.controller.attendantReset()
        try await h.step(until: "idle", within: 1)
        try check(h.sink.storedCount == 1 && h.controller.unsavedPhotos.isEmpty, "stored \(h.sink.storedCount)")
        // Again, but recovers via the periodic retry without a key press.
        await h.advance(1)
        h.sink.failing = true
        try h.press(expect: .accepted)
        try await h.step(until: "attendant(storage)")
        h.sink.failing = false
        try await h.step(until: "idle", within: 20)
        try check(h.sink.storedCount == 2, "stored \(h.sink.storedCount)")
    }

    static func localSinkNaming() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photobooth-selftest-\(UUID().uuidString)/My Event")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let sink = LocalFolderPhotoSink(directory: dir)
        var comps = DateComponents()
        (comps.year, comps.month, comps.day, comps.hour, comps.minute, comps.second) = (2026, 10, 9, 18, 30, 5)
        let date = Calendar.current.date(from: comps)!
        let p = CapturedPhoto(jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), cameraFilename: nil, capturedAt: date)
        let a = try await sink.store(p)
        let b = try await sink.store(p)
        let c = try await sink.store(p)
        try check(a.lastPathComponent == "20261009-183005.jpg", "a = \(a.lastPathComponent)")
        try check(b.lastPathComponent == "20261009-183005-2.jpg", "b = \(b.lastPathComponent)")
        try check(c.lastPathComponent == "20261009-183005-3.jpg", "c = \(c.lastPathComponent)")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        try check(files.count == 3, "leftover files: \(files)")
        let written = try Data(contentsOf: a)
        try check(written == p.jpeg, "content mismatch")
    }

    static func configParsing() async throws {
        // Defaults round-trip.
        let (d, e0) = ConfigLoader.decode(BoothConfig().encodedJSON())
        try check(e0 == nil && d == BoothConfig(), "defaults don't round-trip: \(String(describing: e0))")
        // Empty object → all defaults.
        let (empty, e1) = ConfigLoader.decode(Data("{}".utf8))
        try check(e1 == nil && empty == BoothConfig(), "empty object")
        // Partial + unknown keys + hex device IDs + numeric display.
        let json = """
        {"eventName": "Anna's 40th", "buttonKey": "F13", "shotsPerPress": 3, "display": 1,
         "buttonDevice": {"vendorID": "0x1324", "productID": 259}, "someFutureKey": true}
        """
        let (c, e2) = ConfigLoader.decode(Data(json.utf8))
        try check(e2 == nil, "partial config error: \(String(describing: e2))")
        try check(c.eventName == "Anna's 40th" && c.shotsPerPress == 3 && c.countdownSeconds == 3, "values \(c)")
        try check(c.display == .index(1), "display \(c.display)")
        try check(c.buttonDevice == .stealthSwitch3, "device \(String(describing: c.buttonDevice))")
        try check(c.key?.hidUsage == 0x68 && c.key?.keyCode == 105, "key \(String(describing: c.key))")
        // null device = any keyboard; display by name.
        let (n, e3) = ConfigLoader.decode(Data(#"{"buttonDevice": null, "display": "LG TV", "buttonKey": 44}"#.utf8))
        try check(e3 == nil && n.buttonDevice == nil && n.display == .name("LG TV") && n.key?.name == "space", "null device: \(n) \(String(describing: e3))")
        // Errors become ConfigError (attendant screen), not crashes.
        let bad: [String] = [
            #"{"countdownSeconds": "three"}"#,
            #"{"buttonKey": "bogus"}"#,
            #"{"shotsPerPress": 0}"#,
            #"{"buttonInput": "bluetooth"}"#,
            #"{"buttonDevice": {"vendorID": "zz", "productID": 1}}"#,
            #"{"buttonInput": "local", "buttonKey": "f24"}"#,
            "not json",
        ]
        for b in bad {
            let (cfg, err) = ConfigLoader.decode(Data(b.utf8))
            try check(err != nil, "expected error for \(b)")
            try check(cfg == BoothConfig(), "error should fall back to defaults")
        }
        // Event folder sanitising.
        var s = BoothConfig()
        s.eventName = "a/b:c"
        try check(s.eventFolderName == "a-b-c", "folder \(s.eventFolderName)")
        s.eventName = "  "
        try check(s.eventFolderName == "PhotoBooth", "empty folder name")
    }

    static func keyMapping() async throws {
        let cases: [(String, UInt32, UInt16?, String)] = [
            ("space", 0x2C, 49, "space"), ("Return", 0x28, 36, "return"), ("enter", 0x58, 76, "enter"),
            ("f13", 0x68, 105, "f13"), ("F1", 0x3A, 122, "f1"), ("f12", 0x45, 111, "f12"),
            ("f20", 0x6F, 90, "f20"), ("f24", 0x73, nil, "f24"), ("b", 0x05, 11, "b"), ("z", 0x1D, 6, "z"),
            ("1", 0x1E, 18, "1"), ("0", 0x27, 29, "0"), ("4", 0x21, 21, "4"), ("up", 0x52, 126, "up"),
            ("left", 0x50, 123, "left"), ("esc", 0x29, 53, "escape"), ("kp5", 0x5D, 87, "kp5"),
            ("hid:0x2c", 0x2C, 49, "space"), ("0x68", 0x68, 105, "f13"), ("44", 0x2C, 49, "space"),
            ("hid:0xe8", 0xE8, nil, "hid:0xe8"), (".", 0x37, 47, "."), ("comma", 0x36, 43, ","),
        ]
        for (input, hid, kc, name) in cases {
            guard let k = KeySpec.parse(input) else { throw Failure(description: "\"\(input)\" did not parse") }
            try check(k.hidUsage == hid && k.keyCode == kc && k.name == name, "\"\(input)\" → \(k)")
        }
        for bad in ["", "bogus", "hid:", "0x0", "f99"] {
            try check(KeySpec.parse(bad) == nil, "\"\(bad)\" should not parse")
        }
        // Round trips used by --learn-key.
        try check(KeyMap.configString(hidUsage: 0x2C) == "space", "hid→name")
        try check(KeyMap.configString(keyCode: 49) == "space", "keyCode→name")
        try check(KeyMap.configString(hidUsage: 0x99) == "hid:0x99", "unknown hid → hid:0x..")
        // Table consistency: unique names, HID usages and key codes.
        try check(Set(KeyMap.entries.map(\.name)).count == KeyMap.entries.count, "duplicate key names")
        try check(Set(KeyMap.entries.map(\.hid)).count == KeyMap.entries.count, "duplicate HID usages")
        let kcs = KeyMap.entries.compactMap(\.keyCode)
        try check(Set(kcs).count == kcs.count, "duplicate key codes")
    }
}
