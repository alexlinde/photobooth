import CoreGraphics
import Foundation
import Testing
@testable import PTPKit
@testable import SonyCamera

// MARK: - Harness

@MainActor
private func makeCamera(_ fake: FakeCamera, configure: (inout SonyBoothCamera.Options) -> Void = { _ in })
    -> SonyBoothCamera
{
    var o = SonyBoothCamera.Options()
    o.focusTimeout = .seconds(1)
    o.transactionTimeout = .milliseconds(500)
    o.liveViewTransactionTimeout = .milliseconds(300)
    o.openSessionTimeout = .milliseconds(300)
    o.liveViewStartTimeout = .seconds(2)
    o.liveViewStallTimeout = .seconds(2)
    o.undeliveredCameraHintAfter = .milliseconds(200)
    o.imageReadyTimeout = .seconds(1)
    o.postConnectSettle = .zero
    o.pollInterval = .milliseconds(3)
    o.liveViewRetryDelay = .milliseconds(2)
    o.discoveryPollTimeout = .milliseconds(50)
    o.initialBackoff = .milliseconds(20)
    o.maxBackoff = .milliseconds(80)
    configure(&o)
    return SonyBoothCamera(transport: fake, options: o)
}

/// Records every state the camera publishes.
@MainActor
private final class StateRecorder {
    private(set) var states: [CameraConnectionState] = []
    private var task: Task<Void, Never>?
    init(_ camera: SonyBoothCamera) {
        let stream = camera.stateUpdates()
        task = Task { @MainActor [weak self] in
            for await s in stream { self?.states.append(s) }
        }
    }
    deinit { task?.cancel() }
    var readyCount: Int { states.filter(\.isReady).count }
    var sawRecovering: Bool { states.contains { if case .recovering = $0 { true } else { false } } }
}

@MainActor
private func waitUntil(_ what: String, timeout: Duration = .seconds(5),
                       _ condition: () -> Bool) async throws {
    let t0 = ContinuousClock.now
    while !condition() {
        if ContinuousClock.now - t0 > timeout {
            Issue.record("timed out waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private extension Array where Element == FakeCamera.Call {
    func firstIndex(_ p: (FakeCamera.Call) -> Bool) -> Int? { firstIndex(where: p) }
    func lastIndex(_ p: (FakeCamera.Call) -> Bool) -> Int? { lastIndex(where: p) }
}

private let halfPress: (FakeCamera.Call) -> Bool = { $0.isControlB(SonyProperty.shutterHalfRelease, 2) }
private let halfRelease: (FakeCamera.Call) -> Bool = { $0.isControlB(SonyProperty.shutterHalfRelease, 1) }
private let fullPress: (FakeCamera.Call) -> Bool = { $0.isControlB(SonyProperty.shutterRelease, 2) }
private let fullRelease: (FakeCamera.Call) -> Bool = { $0.isControlB(SonyProperty.shutterRelease, 1) }

// MARK: - Connection

@Test @MainActor func handshakeRunsInOrderAndGatesLiveViewOnStatus() async throws {
    let fake = FakeCamera()
    fake.liveViewPollsUntilOn = 4
    let camera = makeCamera(fake)
    let rec = StateRecorder(camera)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }
    try await waitUntil("a live-view fetch") { fake.calls.contains(where: \.isLiveView) }

    let ops = fake.calls.prefix(5).map(\.description)
    #expect(ops == [
        "SDIOConnect(0x00000001,0x00000000,0x00000000)",
        "SDIOConnect(0x00000002,0x00000000,0x00000000)",
        "GetExtDeviceInfo(0x0000012C,0x00000001)",
        "SDIOConnect(0x00000003,0x00000000,0x00000000)",
        "SetControlDeviceA(0x0000D25A)=1",
    ])
    // Setting Effect off was attempted (and refused, non-fatally).
    #expect(fake.calls.contains { $0.code == PTPOperation.sonySetControlDeviceA && $0.parameters == [0xD231] && $0.value == 2 })
    // No live-view GetObject until LiveViewStatus read 1 (the fake would hang and flag it).
    #expect(fake.violations.isEmpty, "\(fake.violations)")
    #expect(rec.states.first == .searching)
    #expect(rec.states.contains(.connecting(name: "Fake ZV-E10")))
    #expect(rec.states.last == .ready(name: "Fake ZV-E10"))
}

@Test @MainActor func drainsStaleObjectAtConnect() async throws {
    let fake = FakeCamera()
    fake.objectInMemory = 0x8001
    let camera = makeCamera(fake)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready and live view") { camera.state.isReady && fake.calls.contains(where: \.isLiveView) }

    let info = try #require(fake.calls.firstIndex { $0.code == PTPOperation.getObjectInfo && $0.parameters == [SonyHandle.capturedImage] })
    let get = try #require(fake.calls.firstIndex(\.isPhotoDownload))
    let lv = try #require(fake.calls.firstIndex(\.isLiveView))
    #expect(info < get && get < lv)
    #expect(fake.objectInMemory == 0)
    #expect(fake.violations.isEmpty, "\(fake.violations)")
}

@Test @MainActor func deliversDecodedLiveViewFramesToEverySubscriber() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    var a: [CGImage] = [], b: [CGImage] = []
    let ta = Task { @MainActor in for await f in camera.liveViewFrames() { a.append(f); if a.count == 3 { break } } }
    let tb = Task { @MainActor in for await f in camera.liveViewFrames() { b.append(f); if b.count == 3 { break } } }
    camera.start()
    defer { camera.stop(); ta.cancel(); tb.cancel() }
    try await waitUntil("frames") { a.count == 3 && b.count == 3 }
    #expect(a.allSatisfy { $0.width == 8 && $0.height == 8 })
}

// MARK: - Capture

@Test @MainActor func captureSequenceAfterPrepare() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }

    await camera.prepareCapture()
    // Live view keeps flowing during the countdown (liveViewDuringFocus).
    let lvBefore = fake.calls.filter(\.isLiveView).count
    try await Task.sleep(for: .milliseconds(50))
    #expect(fake.calls.filter(\.isLiveView).count > lvBefore)

    let photo = try await camera.capture()
    #expect(photo.jpeg == FakeCamera.photo(1))
    #expect(photo.cameraFilename == "DSC01001.JPG")

    let c = fake.calls
    let hp = try #require(c.firstIndex(halfPress))
    let fp = try #require(c.firstIndex(fullPress))
    let fr = try #require(c.firstIndex(fullRelease))
    let hr = try #require(c.firstIndex(halfRelease))
    let info = try #require(c.firstIndex { $0.code == PTPOperation.getObjectInfo })
    let dl = try #require(c.firstIndex(\.isPhotoDownload))
    #expect(hp < fp && fp < fr && fr < hr && hr < info && info < dl)
    #expect(c.filter(halfPress).count == 1, "prepare's half-press is reused")
    // Focus was polled between half and full press (the fake flags a full press without focus).
    #expect(c[hp..<fp].contains { $0.code == PTPOperation.sonyGetAllDevicePropData })
    // Live view paused from full press until the download finished.
    let lvDuringCapture = c[fp...dl].contains(where: \.isLiveView)
    #expect(!lvDuringCapture)
    #expect(fake.violations.isEmpty, "\(fake.violations)")

    // ... and resumes afterwards.
    try await waitUntil("live view after capture") { fake.calls[(dl + 1)...].contains(where: \.isLiveView) }
    #expect(camera.lastCaptureTiming != nil)
}

@Test @MainActor func captureWithoutPrepareHalfPressesItself() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake) { $0.liveViewDuringFocus = false }
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }

    let start = fake.calls.count
    let photo = try await camera.capture()
    #expect(photo.jpeg == FakeCamera.photo(1))
    let c = Array(fake.calls[start...])
    let presses = c.filter { $0.code == PTPOperation.sonySetControlDeviceB }.map(\.description)
    #expect(presses == ["SetControlDeviceB(0x0000D2C1)=2", "SetControlDeviceB(0x0000D2C2)=2",
                        "SetControlDeviceB(0x0000D2C2)=1", "SetControlDeviceB(0x0000D2C1)=1"])
    // With liveViewDuringFocus off, no live view at all between half-press and download.
    let hp = try #require(c.firstIndex(halfPress))
    let dl = try #require(c.firstIndex(\.isPhotoDownload))
    let lvDuringCapture = c[hp...dl].contains(where: \.isLiveView)
    #expect(!lvDuringCapture)
    #expect(fake.violations.isEmpty, "\(fake.violations)")
}

@Test @MainActor func consecutiveCapturesKeepWorking() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }
    for n in 1...3 {
        await camera.prepareCapture()
        let p = try await camera.capture()
        #expect(p.jpeg == FakeCamera.photo(n))
    }
    #expect(fake.violations.isEmpty, "\(fake.violations)")
}

@Test @MainActor func releasesButtonsWhenCaptureFails() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }

    fake.inject = { call in fullPress(call) ? .respond(PTPResponseCode.generalError) : nil }
    await camera.prepareCapture()
    let start = fake.calls.count
    await #expect(throws: BoothCameraError.self) { try await camera.capture() }
    fake.inject = nil

    let c = Array(fake.calls[start...])
    let fp = try #require(c.firstIndex(fullPress))
    let fr = try #require(c.lastIndex(fullRelease))
    let hr = try #require(c.lastIndex(halfRelease))
    #expect(fp < fr && fr < hr)
    // A refused command is not connection-fatal.
    #expect(camera.state.isReady)
    #expect(fake.openCount == 1)
    // And the next capture works.
    let p = try await camera.capture()
    #expect(p.jpeg == FakeCamera.photo(1))
}

@Test @MainActor func captureErrorsForNotReadyAndConcurrentCalls() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    await #expect(throws: BoothCameraError.notReady) { try await camera.capture() }
    await camera.prepareCapture()  // no-op when not ready
    #expect(fake.calls.isEmpty)

    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }
    let first = Task { @MainActor in try await camera.capture() }
    try await waitUntil("first capture underway") { fake.calls.contains(where: halfPress) }
    await #expect(throws: BoothCameraError.captureInProgress) { try await camera.capture() }
    _ = try await first.value
}

@Test @MainActor func cancelPrepareReleasesHalfPress() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }
    await camera.prepareCapture()
    await camera.prepareCapture()  // second call is a no-op
    await camera.cancelPrepare()
    #expect(fake.calls.filter(halfPress).count == 1)
    let hp = try #require(fake.calls.firstIndex(halfPress))
    let hr = try #require(fake.calls.firstIndex(halfRelease))
    #expect(hp < hr)
    #expect(!fake.calls.contains(where: fullPress))
}

// MARK: - Recovery

@Test @MainActor func recoversAfterTransportError() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    let rec = StateRecorder(camera)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }

    var failed = false
    fake.inject = { call in
        guard call.isLiveView, !failed else { return nil }
        failed = true
        return .fail(NSError(domain: "ICReturnCodeErrorDomain", code: -9923))
    }
    try await waitUntil("second ready") { rec.readyCount == 2 && camera.state.isReady }
    #expect(rec.sawRecovering)
    #expect(fake.openCount == 2)
    #expect(fake.closeCount >= 1)
    // The handshake ran again on the new session.
    #expect(fake.calls.filter { $0.code == PTPOperation.sonyGetExtDeviceInfo }.count == 2)
    #expect(fake.violations.isEmpty, "\(fake.violations)")
}

@Test @MainActor func hungTransactionTimesOutAndRecovers() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    let rec = StateRecorder(camera)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }

    var hung = false
    fake.inject = { call in
        guard call.isLiveView, !hung else { return nil }
        hung = true
        return .hang
    }
    try await waitUntil("second ready") { rec.readyCount == 2 && camera.state.isReady }
    let reason = rec.states.compactMap { if case .recovering(let r) = $0 { r } else { nil } }.first
    #expect(reason?.contains("timed out") == true, "\(String(describing: reason))")
    #expect(fake.violations.isEmpty, "\(fake.violations)")
}

@Test @MainActor func timeoutDuringCaptureFailsCaptureAndRecovers() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    let rec = StateRecorder(camera)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }

    var hung = false
    fake.inject = { call in
        guard call.code == PTPOperation.getObjectInfo, !hung else { return nil }
        hung = true
        return .hang
    }
    await #expect(throws: BoothCameraError.self) { try await camera.capture() }
    try await waitUntil("second ready") { rec.readyCount == 2 && camera.state.isReady }
    #expect(fake.openCount == 2)
    // The photo was left in camera RAM and drained on reconnect, so the next capture is fresh.
    fake.inject = nil
    let p = try await camera.capture()
    #expect(p.jpeg == FakeCamera.photo(2))
    #expect(fake.violations.isEmpty, "\(fake.violations)")
}

@Test @MainActor func recoversAfterUnplugAndReplug() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    let rec = StateRecorder(camera)
    var frames = 0
    let tf = Task { @MainActor in for await _ in camera.liveViewFrames() { frames += 1 } }
    camera.start()
    defer { camera.stop(); tf.cancel() }
    try await waitUntil("frames") { frames > 0 }

    fake.unplug()
    try await waitUntil("searching") { camera.state == .searching }
    #expect(rec.sawRecovering)
    try await Task.sleep(for: .milliseconds(100))
    fake.cameraAvailable = true
    try await waitUntil("ready again") { rec.readyCount == 2 && camera.state.isReady }
    let before = frames
    try await waitUntil("frames on the same stream after reconnect") { frames > before }
}

@Test @MainActor func openSessionThatNeverCallsBackTimesOut() async throws {
    let fake = FakeCamera()
    fake.openHangs = 1
    let camera = makeCamera(fake)
    let rec = StateRecorder(camera)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }
    #expect(fake.openCount == 2)
    #expect(rec.sawRecovering)
}

@Test @MainActor func hintsAtRemovableVolumesPermissionWhenCameraNotDelivered() async throws {
    let fake = FakeCamera()
    fake.cameraAvailable = false
    fake.usbAttached = true
    let camera = makeCamera(fake)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("hint") {
        if case .recovering(let r) = camera.state { r.contains("Removable Volumes") } else { false }
    }
    fake.cameraAvailable = true
    try await waitUntil("ready") { camera.state.isReady }
}

@Test @MainActor func stopClosesSessionAndHaltsTraffic() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    camera.start()
    try await waitUntil("ready") { camera.state.isReady }
    camera.stop()
    #expect(!fake.sessionOpen)
    try await Task.sleep(for: .milliseconds(50))
    let n = fake.calls.count
    try await Task.sleep(for: .milliseconds(100))
    #expect(fake.calls.count == n)
    #expect(camera.state == .searching)

    // And it can be started again.
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready again") { camera.state.isReady }
}

// MARK: - Gate

@Test @MainActor func gateIsFIFOAndPoisonable() async throws {
    let gate = TransactionGate()
    var order: [Int] = []
    try await gate.acquire()
    var tasks: [Task<Void, Never>] = []
    for i in 1...3 {
        tasks.append(Task { @MainActor in
            do { try await gate.acquire(); order.append(i); gate.release() } catch { order.append(-i) }
        })
        await Task.yield()
    }
    try await Task.sleep(for: .milliseconds(10))
    #expect(order.isEmpty)
    gate.release()
    for t in tasks { await t.value }
    #expect(order == [1, 2, 3])

    try await gate.acquire()
    let waiter = Task { @MainActor in
        do { try await gate.acquire(); return true } catch { return false }
    }
    try await Task.sleep(for: .milliseconds(10))
    gate.invalidate(PTPError.notConnected)
    #expect(await waiter.value == false)
    await #expect(throws: PTPError.notConnected) { try await gate.acquire() }
}
