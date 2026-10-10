import Testing
import Foundation
@testable import Uploader

struct UploadQueueTests {
    let noJitter = BackoffPolicy(base: 5, cap: 1800, jitterFraction: 0, notAuthorizedDelay: 300)

    func make(_ script: [Result<Void, UploadError>], dir: URL, clock: FakeClock = FakeClock(),
              monitor: PathMonitoring? = nil) -> (UploadQueue, ScriptedUploader) {
        let up = ScriptedUploader(script)
        let q = UploadQueue(stateURL: dir.appendingPathComponent("q.json"), uploader: up,
                            clock: clock, backoff: noJitter, pathMonitor: monitor)
        return (q, up)
    }

    @Test func backoffPolicy() {
        let p = noJitter
        #expect(p.delay(forAttempt: 1) == 5)
        #expect(p.delay(forAttempt: 2) == 10)
        #expect(p.delay(forAttempt: 3) == 20)
        #expect(p.delay(forAttempt: 20) == 1800)
        let j = BackoffPolicy(base: 5, cap: 1800, jitterFraction: 0.2)
        #expect(j.delay(forAttempt: 1, unit: 0) == 4)
        #expect(abs(j.delay(forAttempt: 1, unit: 0.5) - 5) < 1e-9)
    }

    @Test func uploadsAndIsIdempotent() async throws {
        let dir = tempDir()
        let f = makeJPEG(in: dir, name: "a.jpg")
        let (q, up) = make([], dir: dir)
        await q.enqueue(f); await q.enqueue(f)
        #expect(await q.snapshot().pending == 1)
        await q.start()
        #expect(await waitUntil { await q.snapshot().uploaded == 1 })
        await q.enqueue(f)  // already uploaded: ignored
        #expect(await q.snapshot().pending == 0)
        #expect(up.calls == ["a.jpg"])
        await q.stop()
    }

    @Test func persistsAcrossReinit() async throws {
        let dir = tempDir()
        let f = makeJPEG(in: dir, name: "a.jpg")
        let (q1, _) = make([], dir: dir)
        await q1.enqueue(f)
        let (q2, up2) = make([], dir: dir)
        #expect(await q2.snapshot().pending == 1)
        await q2.start()
        #expect(await waitUntil { await q2.snapshot().uploaded == 1 })
        let (q3, up3) = make([], dir: dir)
        #expect(await q3.snapshot().uploaded == 1)
        await q3.start()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(up3.calls.isEmpty && up2.calls.count == 1)
        await q2.stop(); await q3.stop()
    }

    @Test func reconcile() async throws {
        let dir = tempDir()
        let a = makeJPEG(in: dir, name: "a.jpg")
        _ = makeJPEG(in: dir, name: "b.jpg")
        _ = makeJPEG(in: dir, name: "note.txt")
        let (q, _) = make([], dir: dir.appendingPathComponent("state"))
        await q.enqueue(a)
        await q.reconcile(folder: dir)
        #expect(await q.snapshot().pending == 2)
        await q.reconcile(folder: dir)
        #expect(await q.snapshot().pending == 2)
    }

    @Test func transientBackoffProgression() async throws {
        let dir = tempDir()
        let f = makeJPEG(in: dir, name: "a.jpg")
        let clock = FakeClock()
        let (q, up) = make([.failure(.transient("x")), .failure(.transient("y")), .failure(.transient("z"))],
                           dir: dir, clock: clock)
        await q.enqueue(f)
        await q.start()
        #expect(await waitUntil { await q.snapshot().uploaded == 1 })
        #expect(up.calls.count == 4)
        #expect(clock.sleeps == [5, 10, 20])
        await q.stop()
    }

    @Test func permanentFailureKept() async throws {
        let dir = tempDir()
        let f = makeJPEG(in: dir, name: "a.jpg")
        let (q, up) = make([.failure(.permanent("bad"))], dir: dir)
        await q.enqueue(f)
        await q.start()
        #expect(await waitUntil { await q.snapshot().failedPermanently == 1 })
        let s = await q.snapshot()
        #expect(s.lastError == "bad" && s.pending == 0 && up.calls.count == 1)
        await q.stop()
    }

    @Test func missingFileIsPermanent() async throws {
        let dir = tempDir()
        let (q, up) = make([], dir: dir)
        await q.enqueue(dir.appendingPathComponent("gone.jpg"))
        await q.start()
        #expect(await waitUntil { await q.snapshot().failedPermanently == 1 })
        #expect(up.calls.isEmpty)
        await q.stop()
    }

    @Test func notAuthorizedRetriesSlowly() async throws {
        let dir = tempDir()
        let f = makeJPEG(in: dir, name: "a.jpg")
        let clock = FakeClock()
        let (q, _) = make([.failure(.notAuthorized)], dir: dir, clock: clock)
        await q.enqueue(f)
        await q.start()
        #expect(await waitUntil { await q.snapshot().uploaded == 1 })
        #expect(clock.sleeps == [300])
        await q.stop()
    }

    @Test func retryNowSkipsBackoff() async throws {
        let dir = tempDir()
        let f = makeJPEG(in: dir, name: "a.jpg")
        let clock = StuckClock()
        let up = ScriptedUploader([.failure(.notAuthorized)])
        let q = UploadQueue(stateURL: dir.appendingPathComponent("q.json"), uploader: up,
                            clock: clock, backoff: noJitter, pathMonitor: nil)
        await q.enqueue(f)
        await q.start()
        #expect(await waitUntil { await q.snapshot().lastError == "Google Photos sign-in required" })
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await q.snapshot().uploaded == 0)  // waiting out the 5-minute backoff
        await q.retryNow()
        #expect(await waitUntil { await q.snapshot().uploaded == 1 })
        await q.stop()
    }

    @Test func inFlightResetOnStart() async throws {
        let dir = tempDir()
        let f = makeJPEG(in: dir, name: "a.jpg")
        let state = """
        {"version":1,"items":[{"path":"\(f.standardizedFileURL.path)","state":"inFlight","attempts":0}]}
        """
        try state.write(to: dir.appendingPathComponent("q.json"), atomically: true, encoding: .utf8)
        let (q, up) = make([], dir: dir)
        #expect(await q.snapshot().inFlight == 1)
        await q.start()
        #expect(await waitUntil { await q.snapshot().uploaded == 1 })
        #expect(up.calls.count == 1)
        await q.stop()
    }

    @Test func offlinePauseAndResume() async throws {
        let dir = tempDir()
        let f = makeJPEG(in: dir, name: "a.jpg")
        let mon = FakePathMonitor()
        let (q, up) = make([], dir: dir, monitor: mon)
        mon.set(false)
        await q.enqueue(f)
        await q.start()
        #expect(await waitUntil { await q.snapshot().isPausedOffline })
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(up.calls.isEmpty)
        mon.set(true)
        #expect(await waitUntil { await q.snapshot().uploaded == 1 })
        #expect(await q.snapshot().isPausedOffline == false)
        await q.stop()
    }
}
