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
        ("pause / resume (countdown aborted, capture in flight saved)", pauseResume),
        ("lighting profiles in config", lightingProfiles),
        ("screen layout (booth / control panel displays)", screenLayout),
        ("strip mode: 3 photos → review, fly-in → strip complete", stripMode),
        ("strip mode: failed shot is retried; 3 failures → attendant", stripModeRetry),
        ("strip mode: pause / camera loss discard the strip", stripModeAbort),
        ("missed flash: brightness of black vs grey JPEGs", missedFlashBrightness),
        ("missed flash: black photo rejected, kept aside, retaken", missedFlashRetake),
        ("missed flash in strip mode: shot retaken; 3 in a row → attendant", stripModeMissedFlash),
        ("missed flash: ambient lighting accepts a black photo", missedFlashAmbient),
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
        private var _rejected: [CapturedPhoto] = []
        var failing: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _failing }
            set { lock.lock(); _failing = newValue; lock.unlock() }
        }
        var storedCount: Int { lock.lock(); defer { lock.unlock() }; return _stored.count }
        var storedJPEGs: [Data] { lock.lock(); defer { lock.unlock() }; return _stored.map(\.jpeg) }
        var rejectedCount: Int { lock.lock(); defer { lock.unlock() }; return _rejected.count }

        func store(_ photo: CapturedPhoto) async throws -> URL { try storeSync(photo) }

        func storeRejected(_ photo: CapturedPhoto) async throws -> URL? { rejectSync(photo) }

        private func rejectSync(_ photo: CapturedPhoto) -> URL {
            lock.lock(); defer { lock.unlock() }
            _rejected.append(photo)
            return URL(fileURLWithPath: "/tmp/rejected/test-\(_rejected.count).jpg")
        }

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

    /// Harness in strip mode, recording `onStripComplete`.
    static func stripHarness() -> (Harness, StripLog) {
        var s = BoothSettings()
        s.stripMode = true
        s.shotsPerPress = 5  // ignored in strip mode
        let h = Harness(settings: s)
        let log = StripLog()
        h.controller.onStripComplete = { log.strips.append($0) }
        return (h, log)
    }

    final class StripLog {
        var strips: [[URL]] = []
    }

    static func testURLs(_ n: ClosedRange<Int>) -> [URL] { n.map { URL(fileURLWithPath: "/tmp/test-\($0).jpg") } }

    static func stripMode() async throws {
        let (h, log) = stripHarness()
        try await h.startReady()
        try h.press(expect: .accepted)
        await h.pump()
        try check(h.label == "countdown(3,1/3)", "3 shots despite shotsPerPress 5: \(h.label)")
        // Shot 1: the short review (2.5 s, not reviewSeconds), then the fly-in (0.8 s), then
        // straight into the next countdown.
        try await h.step(until: "review(1/3)")
        try check(h.controller.stripPhotos.isEmpty, "slot filled before the fly-in")
        await h.advance(2.35)
        try check(h.label == "review(1/3)", "review ended early: \(h.label)")
        await h.advance(0.2)
        try check(h.label == "flyin(1/3)", "expected fly-in after 2.5 s, got \(h.label)")
        try check(h.controller.stripPhotos.isEmpty, "slot filled before the photo landed")
        await h.advance(0.65)
        try check(h.label == "flyin(1/3)", "fly-in ended early: \(h.label)")
        await h.advance(0.2)
        try check(h.label == "countdown(3,2/3)", "expected the next countdown after the fly-in, got \(h.label)")
        try check(h.controller.stripPhotos.map(\.url) == testURLs(1...1), "strip \(h.controller.stripPhotos.map(\.url))")
        try check(log.strips.isEmpty, "strip complete too early")
        // Shots 2 and 3, then the finished strip for reviewSeconds.
        try await h.step(until: "strip-review", within: 40)
        try check(log.strips == [testURLs(1...3)], "strip complete \(log.strips)")
        if case .stripReview(let photos) = h.controller.state {
            try check(photos.map(\.url) == testURLs(1...3), "strip review photos \(photos.map(\.url))")
        }
        await h.advance(4.8)
        try check(h.label == "strip-review", "strip review ended early: \(h.label)")
        try await h.step(until: "idle", within: 1)
        try check(h.controller.stripPhotos.isEmpty, "strip not cleared after the press")
        try check(h.sink.storedCount == 3 && h.camera.captureCount == 3, "stored \(h.sink.storedCount)")
        let keyStates = h.history.filter { ["capturing", "review", "flyin", "strip", "between"].contains(where: $0.hasPrefix) }
        let expected = ["capturing(1/3)", "review(1/3)", "flyin(1/3)", "capturing(2/3)", "review(2/3)", "flyin(2/3)",
                        "capturing(3/3)", "review(3/3)", "flyin(3/3)", "strip-review"]
        try check(keyStates == expected, "sequence \(keyStates)")
        // The next press starts an empty strip and fires once more.
        try h.press(expect: .accepted)
        try await h.step(until: "strip-review", within: 40)
        try check(log.strips.count == 2 && log.strips[1] == testURLs(4...6), "second strip \(log.strips)")
    }

    static func stripModeRetry() async throws {
        let (h, log) = stripHarness()
        try await h.startReady()
        try h.press(expect: .accepted)
        try await h.step(until: "countdown(3,2/3)", within: 10)
        // Shot 2 fails: "Oops", then shot 2 again (not idle, not shot 3).
        h.camera.scriptedFailures = 1
        try await h.step(until: "notice")
        try check(h.controller.consecutiveFailures == 1 && h.controller.stripPhotos.count == 1, "after failure: \(h.controller.stripPhotos.count)")
        try await h.step(until: "countdown(3,2/3)", within: 5)
        try await h.step(until: "strip-review", within: 40)
        try check(log.strips == [testURLs(1...3)], "strip complete \(log.strips)")
        try check(h.camera.captureCount == 4 && h.controller.consecutiveFailures == 0, "captures \(h.camera.captureCount)")
        let i = h.history.firstIndex(of: "notice")!
        let pressed = h.history.firstIndex(of: "countdown(3,1/3)")!
        try check(!h.history[pressed...].contains("idle"), "went idle mid-strip: \(h.history)")
        try check(h.history[i + 1] == "countdown(3,2/3)", "after notice: \(h.history[i + 1])")
        try await h.step(until: "idle", within: 6)
        // Three failures in a row: retried twice, then the attendant screen; nothing prints.
        h.camera.scriptedFailures = 3
        try h.press(expect: .accepted)
        try await h.step(until: "attendant(captureFailures)", within: 30)
        let press = h.history[(h.history.lastIndex(of: "idle")! + 1)...]
        try check(press.filter { $0 == "capturing(1/3)" }.count == 3 && press.filter { $0 == "notice" }.count == 2, "retries \(press)")
        try check(h.controller.stripPhotos.isEmpty && log.strips.count == 1, "printed after failures: \(log.strips)")
    }

    static func stripModeAbort() async throws {
        let (h, log) = stripHarness()
        try await h.startReady()
        // Paused mid-strip: discarded (photos stay saved), nothing prints, even after resume.
        try h.press(expect: .accepted)
        try await h.step(until: "countdown(3,2/3)", within: 10)
        try check(h.controller.stripPhotos.count == 1, "strip \(h.controller.stripPhotos.count)")
        h.controller.pause()
        await h.pump()
        try check(h.label == "paused" && h.controller.stripPhotos.isEmpty, "pause: \(h.label), \(h.controller.stripPhotos.count)")
        await h.advance(30)
        h.controller.resume()
        await h.advance(30)
        try check(h.label == "idle" && log.strips.isEmpty && h.sink.storedCount == 1, "after resume: \(h.label) \(log.strips)")
        // Paused during the fly-in: the same.
        try h.press(expect: .accepted)
        try await h.step(until: "flyin(1/3)", within: 10)
        h.controller.pause()
        await h.pump()
        try check(h.label == "paused" && h.controller.stripPhotos.isEmpty, "pause in fly-in: \(h.label)")
        h.controller.resume()
        await h.pump()
        // Camera lost between shots: discarded.
        try h.press(expect: .accepted)
        try await h.step(until: "countdown(2,2/3)", within: 10)
        h.camera.setState(.searching)
        await h.pump()
        try check(h.label == "waiting" && h.controller.stripPhotos.isEmpty, "camera lost: \(h.label)")
        h.camera.setState(.ready(name: "Fake"))
        await h.advance(30)
        try check(h.label == "idle" && log.strips.isEmpty, "after camera loss: \(h.label) \(log.strips)")
        // Camera lost during a review: abandoned when the photo lands, not another countdown.
        try h.press(expect: .accepted)
        try await h.step(until: "review(2/3)", within: 20)
        h.camera.setState(.searching)
        try await h.step(until: "waiting", within: 5)
        try check(h.controller.stripPhotos.isEmpty && !h.history.contains("countdown(3,3/3)"), "camera lost in review: \(h.history.suffix(4))")
        h.camera.setState(.ready(name: "Fake"))
        await h.advance(30)
        try check(h.label == "idle" && log.strips.isEmpty, "after camera loss in review: \(h.label)")
        // A full strip still works afterwards.
        try h.press(expect: .accepted)
        try await h.step(until: "strip-review", within: 40)
        try check(log.strips.count == 1 && log.strips[0].count == 3, "strip \(log.strips)")
    }

    static func missedFlashBrightness() async throws {
        let size = CGSize(width: 600, height: 338)
        guard let black = FakeImages.blackJPEG(size: size), let grey = FakeImages.solidJPEG(size: size, gray: 0.5),
              let dark = FakeImages.solidJPEG(size: size, gray: 0.22) else { throw Failure(description: "couldn't make JPEGs") }
        let b = ImageDecoding.meanLuminance(black), g = ImageDecoding.meanLuminance(grey), d = ImageDecoding.meanLuminance(dark)
        try check(b != nil && b! < 1 && ImageDecoding.isMissedFlash(meanLuminance: b!), "black: \(String(describing: b))")
        try check(g != nil && (100...160).contains(g!) && !ImageDecoding.isMissedFlash(meanLuminance: g!), "grey: \(String(describing: g))")
        // About as dark as a good photo on the black backdrop (55–70): kept.
        try check(d != nil && (40...80).contains(d!) && !ImageDecoding.isMissedFlash(meanLuminance: d!), "dark: \(String(describing: d))")
        try check(ImageDecoding.meanLuminance(Data([0xFF, 0xD8, 0xFF, 0xD9])) == nil, "garbage decodes")
        // Only the strobes profile rejects black photos.
        var c = BoothConfig()
        try check(BoothSettings(c).rejectMissedFlash, "strobes should reject")
        c.lighting = .ambient
        try check(!BoothSettings(c).rejectMissedFlash, "ambient should not reject")
        c.lighting = .none
        try check(!BoothSettings(c).rejectMissedFlash, "none should not reject")
    }

    static func missedFlashRetake() async throws {
        let h = Harness()
        try await h.startReady()
        // Black, then good. Normal mode: like a failed capture, the notice then idle; the guest
        // presses again.
        h.camera.scriptedBlackFrames = 1
        try h.press(expect: .accepted)
        try await h.step(until: "notice")
        try check(h.controller.state == .notice(BoothController.missedFlashNotice), "notice \(h.controller.state)")
        try check(h.sink.storedCount == 0 && h.sink.rejectedCount == 1, "stored \(h.sink.storedCount), rejected \(h.sink.rejectedCount)")
        try check(h.controller.consecutiveFailures == 1, "failures \(h.controller.consecutiveFailures)")
        try check(!h.history.contains("review(1/1)"), "black photo reviewed: \(h.history)")
        try await h.step(until: "idle", within: 5)
        try h.press(expect: .accepted)
        try await h.step(until: "review(1/1)")
        try check(h.sink.storedCount == 1 && h.sink.rejectedCount == 1, "stored \(h.sink.storedCount), rejected \(h.sink.rejectedCount)")
        try check(h.controller.consecutiveFailures == 0, "failures not reset by a good photo")
        if let jpeg = h.sink.storedJPEGs.first, let mean = ImageDecoding.meanLuminance(jpeg) {
            try check(!ImageDecoding.isMissedFlash(meanLuminance: mean), "stored a black photo (\(mean))")
        }
        try check(h.camera.captureCount == 2, "captures \(h.camera.captureCount)")
    }

    static func stripModeMissedFlash() async throws {
        let (h, log) = stripHarness()
        try await h.startReady()
        try h.press(expect: .accepted)
        try await h.step(until: "countdown(3,3/3)", within: 20)
        // Shot 3 comes out black: rejected, "Oops", shot 3 again; the strip has 3 good photos.
        h.camera.scriptedBlackFrames = 1
        try await h.step(until: "notice")
        try check(h.controller.state == .notice(BoothController.missedFlashNotice), "notice \(h.controller.state)")
        try check(h.controller.stripPhotos.count == 2 && h.sink.rejectedCount == 1, "strip \(h.controller.stripPhotos.count)")
        try await h.step(until: "countdown(3,3/3)", within: 5)
        try await h.step(until: "strip-review", within: 20)
        try check(log.strips == [testURLs(1...3)], "strip complete \(log.strips)")
        try check(h.sink.storedCount == 3 && h.sink.rejectedCount == 1 && h.camera.captureCount == 4, "stored \(h.sink.storedCount)")
        try check(h.controller.consecutiveFailures == 0, "failures \(h.controller.consecutiveFailures)")
        try await h.step(until: "idle", within: 6)
        // Three black photos in a row: retried twice, then the attendant screen about the flash.
        h.camera.scriptedBlackFrames = 3
        try h.press(expect: .accepted)
        try await h.step(until: "attendant(missedFlash)", within: 30)
        let press = h.history[(h.history.lastIndex(of: "idle")! + 1)...]
        try check(press.filter { $0 == "capturing(1/3)" }.count == 3 && press.filter { $0 == "notice" }.count == 2, "retries \(press)")
        try check(h.controller.attendantIssue?.title == "The flash isn't firing", "issue \(String(describing: h.controller.attendantIssue))")
        try check(h.controller.attendantIssue?.detail.contains("transmitter") == true, "detail \(String(describing: h.controller.attendantIssue))")
        try check(h.sink.storedCount == 3 && h.sink.rejectedCount == 4 && log.strips.count == 1, "stored \(h.sink.storedCount)")
        // A camera reconnect doesn't clear it (the strobes are the problem); the attendant key does.
        h.camera.setState(.searching)
        await h.pump()
        h.camera.setState(.ready(name: "Fake"))
        await h.pump()
        try check(h.label == "attendant(missedFlash)", "reconnect cleared it: \(h.label)")
        h.controller.attendantReset()
        await h.pump()
        try check(h.label == "idle" && h.controller.consecutiveFailures == 0, "after reset: \(h.label)")
    }

    static func missedFlashAmbient() async throws {
        var s = BoothSettings()
        s.rejectMissedFlash = false
        let h = Harness(settings: s)
        try await h.startReady()
        h.camera.scriptedBlackFrames = 1
        try h.press(expect: .accepted)
        try await h.step(until: "review(1/1)")
        try check(h.sink.storedCount == 1 && h.sink.rejectedCount == 0, "stored \(h.sink.storedCount), rejected \(h.sink.rejectedCount)")
        try check(!h.history.contains("notice"), "notice with ambient: \(h.history)")
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
        // Rejected frames go to rejected/, out of sight of the photo listings (top-level JPEGs only).
        let r = try await sink.storeRejected(p)
        try check(r == dir.appendingPathComponent("rejected/20261009-183005.jpg"), "rejected = \(String(describing: r))")
        let jpgs = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".jpg") }
        try check(jpgs.count == 3, "rejected frame among the photos: \(jpgs)")
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
        try check(!c.stripMode && BoothSettings(c).shotsPerPress == 3, "stripMode default")
        let (sm, e5) = ConfigLoader.decode(Data(#"{"stripMode": true}"#.utf8))
        try check(e5 == nil && sm.stripMode && BoothSettings(sm).stripMode, "stripMode: \(String(describing: e5))")
        try check(ConfigLoader.decode(sm.encodedJSON()).0 == sm, "stripMode round trip")
        try check(ConfigLoader.decode(Data(#"{"stripMode": "yes"}"#.utf8)).1 != nil, "stripMode wrong type")
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

    static func pauseResume() async throws {
        let h = Harness()
        try await h.startReady()
        // From idle.
        h.controller.pause()
        await h.pump()
        try check(h.label == "paused" && h.controller.isPaused, "pause from idle: \(h.label)")
        try h.press(expect: .ignored("paused"))
        h.controller.resume()
        await h.pump()
        try check(h.label == "idle" && !h.controller.isPaused, "resume: \(h.label)")
        // During the countdown: aborted, half-press released, no capture.
        await h.advance(1)
        try h.press(expect: .accepted)
        await h.advance(1.2)
        try check(h.label.hasPrefix("countdown"), "expected countdown, got \(h.label)")
        h.controller.pause()
        await h.pump()
        try check(h.label == "paused", "pause in countdown: \(h.label)")
        try check(h.camera.cancelPrepareCount == 1, "cancelPrepare \(h.camera.cancelPrepareCount)x")
        await h.advance(10)
        try check(h.label == "paused" && h.camera.captureCount == 0, "aborted session resumed: \(h.label), \(h.camera.captureCount) captures")
        try h.press(expect: .ignored("paused"))
        // Camera comings and goings don't leave the paused screen.
        h.camera.setState(.searching)
        await h.pump()
        try check(h.label == "paused", "camera lost while paused: \(h.label)")
        h.camera.setState(.ready(name: "Fake"))
        await h.pump()
        try check(h.label == "paused", "camera back while paused: \(h.label)")
        // Attendant issues raised while paused wait, and show on resume.
        h.controller.raiseAttendant(.other("lights"))
        await h.pump()
        try check(h.label == "paused" && h.controller.attendantIssue == .other("lights"), "attendant while paused: \(h.label)")
        h.controller.resume()
        await h.pump()
        try check(h.label == "attendant(other)", "resume with issue: \(h.label)")
        h.controller.attendantReset()
        await h.pump()
        try check(h.label == "idle" && h.controller.attendantIssue == nil, "reset: \(h.label)")
        // Reset while paused clears a waiting issue.
        h.controller.raiseAttendant(.other("x"))
        h.controller.pause()
        h.controller.attendantReset()
        await h.pump()
        try check(h.label == "paused" && h.controller.attendantIssue == nil, "reset while paused: \(h.label)")
        h.controller.resume()
        await h.pump()
        try check(h.label == "idle", "resume after reset: \(h.label)")
        // During capture: the photo in flight is saved, then paused (no review).
        await h.advance(1)
        try h.press(expect: .accepted)
        try await h.step(until: "capturing(1/1)")
        h.controller.pause()
        try check(h.label == "capturing(1/1)", "capture must finish: \(h.label)")
        try await h.step(until: "paused", within: 2)
        try check(h.sink.storedCount == 1 && h.camera.captureCount == 1, "stored \(h.sink.storedCount)")
        try check(!h.history.contains("review(1/1)"), "review shown while paused: \(h.history)")
        // During review: back to paused straight away.
        h.controller.resume()
        await h.advance(1)
        try h.press(expect: .accepted)
        try await h.step(until: "review(1/1)")
        h.controller.pause()
        await h.pump()
        try check(h.label == "paused" && h.sink.storedCount == 2, "pause in review: \(h.label)")
        h.controller.resume()
        await h.advance(10)
        try check(h.label == "idle" && h.camera.captureCount == 2, "after resume: \(h.label)")
    }

    static func lightingProfiles() async throws {
        // Defaults: strobes, no overrides, and no "profiles" key written.
        let d = BoothConfig()
        try check(d.lighting == .strobes && d.cameraProfile == .strobes, "default profile \(String(describing: d.cameraProfile))")
        let json = String(decoding: d.encodedJSON(), as: UTF8.self)
        try check(json.contains("\"lighting\" : \"strobes\"") && !json.contains("profiles"), "default JSON: \(json)")
        // "none" leaves the camera alone.
        let (n, e0) = ConfigLoader.decode(Data(#"{"lighting": "none"}"#.utf8))
        try check(e0 == nil && n.lighting == .none && n.cameraProfile == nil, "none: \(String(describing: e0))")
        // Partial overrides merge onto the built-ins.
        let partial = """
        {"lighting": "Strobes", "profiles": {
          "strobes": {"shutter": "1/125", "aperture": 5.6, "iso": 200, "flashCompensation": -0.3, "settingEffect": true},
          "ambient": {"aperture": 4, "iso": "auto", "exposureMode": "program", "shutter": "0.5"}}}
        """
        let (c, e1) = ConfigLoader.decode(Data(partial.utf8))
        try check(e1 == nil, "partial: \(String(describing: e1))")
        var want = CameraProfile.strobes
        want.shutterSpeed = .init(1, 125)
        want.aperture = 5.6
        want.iso = .value(200)
        want.flashCompensation = -0.3
        want.liveViewSettingEffect = true
        try check(c.cameraProfile == want, "strobes merge: \(String(describing: c.cameraProfile))")
        try check(c.cameraProfile?.flashMode == .fill && c.cameraProfile?.exposureMode == .manual, "untouched fields kept")
        var amb = c
        amb.lighting = .ambient
        try check(amb.cameraProfile?.aperture == 4 && amb.cameraProfile?.iso == .auto && amb.cameraProfile?.exposureMode == .program
                  && amb.cameraProfile?.shutterSpeed == .init(5, 10)
                  && amb.cameraProfile?.flashMode == CameraProfile.ambient.flashMode, "ambient merge: \(String(describing: amb.cameraProfile))")
        // Every friendly spelling of every field.
        let all = """
        {"profiles": {"strobes": {"exposureMode": "shutter", "shutter": "2", "aperture": 22, "iso": 12800,
          "exposureCompensation": 1.7, "flash": "rearSync", "flashCompensation": 3, "focus": "MF",
          "whiteBalance": "tungsten", "settingEffect": false}}}
        """
        let (a, e2) = ConfigLoader.decode(Data(all.utf8))
        let o = a.profiles.strobes
        try check(e2 == nil && o.exposureMode == .shutterPriority && o.shutter == .init(2, 1) && o.aperture == 22
                  && o.iso == .value(12800) && o.exposureCompensation == 1.7 && o.flash == .rearSync && o.flashCompensation == 3
                  && o.focus == .manual && o.whiteBalance == .tungsten && o.settingEffect == false, "all fields: \(o) \(String(describing: e2))")
        for (spelling, expected) in [("af-s", CameraProfile.FocusMode.single), ("af-c", .continuous), ("af-a", .automatic), ("dmf", .directManual)] {
            let (f, e) = ConfigLoader.decode(Data(#"{"profiles": {"ambient": {"focus": "\#(spelling)"}}}"#.utf8))
            try check(e == nil && f.profiles.ambient.focus == expected, "focus \(spelling)")
        }
        for (spelling, expected) in [("1/4000", CameraProfile.ShutterSpeed(1, 4000)), ("30", .init(30, 1)), ("2.5", .init(25, 10)), ("1", .init(1, 1)), ("2s", .init(2, 1)), ("1/160s", .init(1, 160))] {
            let (f, e) = ConfigLoader.decode(Data(#"{"profiles": {"ambient": {"shutter": "\#(spelling)"}}}"#.utf8))
            try check(e == nil && f.profiles.ambient.shutter == expected, "shutter \(spelling): \(String(describing: f.profiles.ambient.shutter)) \(String(describing: e))")
        }
        // Round trip through save/load, keeping overrides and readable values.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photobooth-cfg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.json").path
        var saved = a
        saved.lighting = .ambient
        saved.profiles.ambient = c.profiles.ambient
        saved.buttonDevice = nil
        saved.eventName = "Anna's 40th"
        try ConfigLoader.save(saved, path: path)
        let (loaded, e3) = ConfigLoader.load(path: path)
        try check(e3 == nil && loaded == saved, "round trip: \(String(describing: e3))\n\(loaded)\n\(saved)")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for frag in [#""shutter" : "0.5""#, #""iso" : "auto""#, #""iso" : 12800"#, #""focus" : "mf""#, #""settingEffect" : false"#,
                     #""flash" : "rearSync""#, #""exposureMode" : "program""#, #""buttonDevice" : null"#] {
            try check(text.contains(frag), "saved JSON lacks \(frag):\n\(text)")
        }
        // Saving invalid settings throws and leaves the file alone.
        var invalid = saved
        invalid.countdownSeconds = 99
        do {
            try ConfigLoader.save(invalid, path: path)
            throw Failure(description: "saving countdownSeconds 99 should fail")
        } catch let e as ConfigError {
            try check(e.problems.contains { $0.contains("countdownSeconds") }, "error \(e)")
        }
        try check(ConfigLoader.load(path: path).0 == saved, "invalid save changed the file")
        // Every invalid value path → ConfigError naming the key, defaults returned.
        let bad: [(String, String)] = [
            (#"{"lighting": "strobe"}"#, "lighting"),
            (#"{"lighting": 1}"#, "lighting"),
            (#"{"profiles": []}"#, "profiles"),
            (#"{"profiles": {"strobes": 3}}"#, "profiles.strobes"),
            (#"{"profiles": {"strobes": {"exposureMode": "auto"}}}"#, "exposureMode"),
            (#"{"profiles": {"strobes": {"shutter": "fast"}}}"#, "shutter"),
            (#"{"profiles": {"strobes": {"shutter": "1/0"}}}"#, "shutter"),
            (#"{"profiles": {"strobes": {"shutter": "60"}}}"#, "shutter"),
            (#"{"profiles": {"strobes": {"shutter": "1/16000"}}}"#, "shutter"),
            (#"{"profiles": {"strobes": {"shutter": true}}}"#, "shutter"),
            (#"{"profiles": {"strobes": {"aperture": "f/8"}}}"#, "aperture"),
            (#"{"profiles": {"strobes": {"aperture": 0.5}}}"#, "aperture"),
            (#"{"profiles": {"strobes": {"iso": "high"}}}"#, "iso"),
            (#"{"profiles": {"strobes": {"iso": 100.5}}}"#, "iso"),
            (#"{"profiles": {"strobes": {"iso": 10}}}"#, "iso"),
            (#"{"profiles": {"ambient": {"exposureCompensation": 9}}}"#, "exposureCompensation"),
            (#"{"profiles": {"ambient": {"exposureCompensation": "+1"}}}"#, "exposureCompensation"),
            (#"{"profiles": {"strobes": {"flash": "on"}}}"#, "flash"),
            (#"{"profiles": {"strobes": {"flashCompensation": -4}}}"#, "flashCompensation"),
            (#"{"profiles": {"strobes": {"focus": "af"}}}"#, "focus"),
            (#"{"profiles": {"strobes": {"whiteBalance": "fluorescent"}}}"#, "whiteBalance"),
            (#"{"profiles": {"strobes": {"settingEffect": "off"}}}"#, "settingEffect"),
        ]
        for (b, key) in bad {
            let (cfg, err) = ConfigLoader.decode(Data(b.utf8))
            try check(err != nil, "expected error for \(b)")
            try check(err?.description.contains(key) == true, "error for \(b) doesn't name \(key): \(String(describing: err))")
            try check(cfg == BoothConfig(), "error should fall back to defaults")
        }
        // Unknown keys (top level and inside profiles) are ignored, not errors.
        let (u, e4) = ConfigLoader.decode(Data(#"{"profiles": {"party": {}, "strobes": {"shuter": "1/60"}}}"#.utf8))
        try check(e4 == nil && u.profiles.isEmpty, "unknown profile keys: \(String(describing: e4))")
        // The control panel's choices all parse, and the built-ins' values are among them.
        for field in ProfileField.allCases {
            for v in field.choices {
                var o = ProfileOverride()
                try field.set(v, in: &o)
                try check(field.value(in: o) == v, "\(field) choice \(v) → \(String(describing: field.value(in: o)))")
            }
            for p in [CameraProfile.strobes, .ambient] {
                if let v = field.value(in: p) { try check(field.choices.contains(v), "\(p.name) \(field) \(v) not a choice") }
            }
        }
        try check(ProfileField.shutter.choices.first == "1/4000" && ProfileField.shutter.choices.last == "30", "shutter range")
        try check(ProfileField.aperture.choices.first == "1.8" && ProfileField.aperture.choices.last == "22", "aperture range")
        try check(ProfileField.iso.choices.prefix(2) == ["auto", "100"] && ProfileField.iso.choices.last == "12800", "iso range")
        try check(ProfileField.exposureCompensation.choices.contains("-0.3") && ProfileField.exposureCompensation.choices.contains("2.7")
                  && ProfileField.exposureCompensation.choices.count == 19, "EV steps \(ProfileField.exposureCompensation.choices)")
    }

    static func screenLayout() async throws {
        func screen(_ id: UInt32, _ name: String, builtin: Bool = false, main: Bool = false, x: CGFloat = 0) -> ScreenDescriptor {
            ScreenDescriptor(id: id, name: name, frame: CGRect(x: x, y: 0, width: 1920, height: 1080), isBuiltin: builtin, isMain: main)
        }
        let laptop = screen(1, "Built-in Retina Display", builtin: true, main: true)
        let tv = screen(2, "SONY TV", x: 1920)
        let monitor = screen(3, "LG UltraFine", x: -1920)

        // Nothing attached (shouldn't happen) → nil.
        try check(ScreenLayout.compute(screens: [], selection: .auto) == nil, "no screens")
        // Laptop only → kiosk on it.
        try check(ScreenLayout.compute(screens: [laptop], selection: .auto) == .singleScreen(booth: laptop), "laptop only")
        // Laptop + TV → booth on the TV, panel on the laptop (either way round in the list).
        try check(ScreenLayout.compute(screens: [laptop, tv], selection: .auto) == .twoScreen(booth: tv, panel: laptop), "laptop + TV")
        var tvMain = tv
        tvMain.isMain = true
        var laptopSecond = laptop
        laptopSecond.isMain = false
        try check(ScreenLayout.compute(screens: [tvMain, laptopSecond], selection: .auto) == .twoScreen(booth: tvMain, panel: laptopSecond),
                  "TV as main display")
        // Lid closed: TV only → kiosk on the TV.
        try check(ScreenLayout.compute(screens: [tvMain], selection: .auto) == .singleScreen(booth: tvMain), "TV only")
        // Mac mini: monitor (main) + TV → booth on the non-main external, panel on the monitor.
        var monitorMain = monitor
        monitorMain.isMain = true
        try check(ScreenLayout.compute(screens: [monitorMain, tv], selection: .auto) == .twoScreen(booth: tv, panel: monitorMain), "two externals")
        // Laptop + monitor + TV, by name: booth on the TV, panel prefers the built-in.
        try check(ScreenLayout.compute(screens: [laptop, monitor, tv], selection: .name("sony")) == .twoScreen(booth: tv, panel: laptop),
                  "name selection")
        try check(ScreenLayout.compute(screens: [laptop, monitor, tv], selection: .name("lg")) == .twoScreen(booth: monitor, panel: laptop),
                  "name selection 2")
        // By index (NSScreen order).
        try check(ScreenLayout.compute(screens: [laptop, tv], selection: .index(1)) == .twoScreen(booth: tv, panel: laptop), "index 1")
        try check(ScreenLayout.compute(screens: [laptop, tv], selection: .index(0)) == .twoScreen(booth: laptop, panel: tv), "index 0")
        try check(ScreenLayout.compute(screens: [laptop, tv], selection: .main) == .twoScreen(booth: laptop, panel: tv), "main")
        // A selection that matches nothing falls back to the first display.
        try check(ScreenLayout.compute(screens: [laptop, tv], selection: .index(5)) == .twoScreen(booth: laptop, panel: tv), "bad index")
        try check(ScreenLayout.compute(screens: [laptop], selection: .name("SONY")) == .singleScreen(booth: laptop), "missing TV by name")
        // The panel is never on the booth display, whatever the selection.
        let sets: [[ScreenDescriptor]] = [[laptop], [laptop, tv], [tvMain, laptopSecond], [monitorMain, tv], [laptop, monitor, tv], [tvMain]]
        let selections: [BoothConfig.DisplaySelection] = [.auto, .main, .index(0), .index(1), .index(2), .index(9), .name("sony"), .name("lg"), .name("built-in"), .name("none")]
        for screens in sets {
            for sel in selections {
                guard let l = ScreenLayout.compute(screens: screens, selection: sel) else { throw Failure(description: "nil layout") }
                try check(screens.contains(l.booth), "booth on unknown screen")
                if let p = l.panel {
                    try check(p.id != l.booth.id, "panel on booth display: \(screens) \(sel)")
                    try check(screens.count > 1, "two-screen layout with one screen")
                } else {
                    try check(screens.count == 1, "single-screen layout with \(screens.count) screens")
                }
            }
        }
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
        // Except Print Screen, which macOS delivers as F13 (keyCode 105): an intended alias.
        let kcs = KeyMap.entries.filter { $0.name != "printscreen" }.compactMap(\.keyCode)
        try check(Set(kcs).count == kcs.count, "duplicate key codes")
        try check(KeySpec.parse("printscreen")?.keyCode == 105, "printscreen works in focused-window mode")
    }
}
