import Foundation
import Testing
@testable import PTPKit
@testable import SonyCamera

// MARK: - Harness

/// A `ProfileApplier` over a bare session on the fake (no supervisor), with test timings.
@MainActor
private func makeApplier(_ fake: FakeCamera) async throws -> ProfileApplier {
    try await fake.openSession(timeout: .seconds(1))
    let session = SonySession(transport: fake)
    session.log = { _ in }
    var a = ProfileApplier(session: session)
    a.modeSettleTimeout = .seconds(1)
    a.settleTimeout = .milliseconds(300)
    a.pollInterval = .milliseconds(5)
    return a
}

private func outcomes(_ r: CameraProfileReport) -> [String: CameraProfileReport.Outcome] {
    Dictionary(uniqueKeysWithValues: r.items.map { ($0.setting, $0.outcome) })
}

private let modeCode = UInt32(SonyProperty.exposureProgramMode)
private let isPropPoll: (FakeCamera.Call) -> Bool = { $0.code == PTPOperation.sonyGetAllDevicePropData }

// MARK: - ProfileApplier

@Test @MainActor func modeIsWrittenFirstAndTheRestOnlyAfterItReadsBack() async throws {
    let fake = FakeCamera()  // left in Intelligent Auto: everything else display-only
    fake.modeReadbackLag = .milliseconds(80)
    let applier = try await makeApplier(fake)
    let report = try await applier.apply(.strobes)

    let writes = fake.controlAWrites
    #expect(writes.first?.parameters == [modeCode])
    #expect(writes.filter { $0.parameters == [modeCode] }.count == 1)
    // Nothing else went out while the mode was settling (the camera would have dropped it).
    #expect(fake.droppedDuringModeChange.isEmpty, "\(fake.droppedDuringModeChange.map(hex16))")
    let modeWrite = try #require(fake.calls.firstIndex { $0.code == PTPOperation.sonySetControlDeviceA && $0.parameters == [modeCode] })
    let nextWrite = try #require(fake.calls.firstIndex { $0.code == PTPOperation.sonySetControlDeviceA && $0.parameters != [modeCode] })
    #expect(fake.calls[modeWrite..<nextWrite].filter(isPropPoll).count > 2, "mode was polled before the other writes")

    #expect(report.profileName == "Strobes")
    #expect(report.allOK, "\(report.problems)")
    let o = outcomes(report)
    #expect(o["Exposure mode"] == .applied)
    #expect(o["Shutter speed"] == .applied)
    #expect(o["Aperture"] == .applied)
    #expect(o["ISO"] == .applied)
    #expect(o["Focus mode"] == .applied)
    #expect(o["Live view Setting Effect"] == .applied)
    #expect(o["Flash mode"] == .alreadySet)
    #expect(o["Flash compensation"] == .alreadySet)
    #expect(o["White balance"] == .alreadySet)
    #expect(fake.value(SonyProperty.shutterSpeed) == 0x0001_00A0)
    #expect(fake.value(SonyProperty.fNumber) == 800)
    #expect(fake.value(SonyProperty.iso) == 100)
    #expect(report.items.map(\.requested) == ["M", "1/160", "f/8", "100", "Fill", "+0.0 EV", "AF-S", "Auto", "Off"])
}

@Test @MainActor func laggedReadBackIsPolledAndReportedApplied() async throws {
    let fake = FakeCamera()
    fake.settings = FakeCamera.strobeSettings()
    fake.readbackLag = .milliseconds(100)  // many poll intervals
    let applier = try await makeApplier(fake)
    var profile = CameraProfile.strobes
    profile.shutterSpeed = .init(1, 250)
    profile.aperture = 11
    let report = try await applier.apply(profile)

    let o = outcomes(report)
    #expect(o["Shutter speed"] == .applied)
    #expect(o["Aperture"] == .applied)
    let lastWrite = try #require(fake.calls.lastIndex { $0.code == PTPOperation.sonySetControlDeviceA })
    #expect(fake.calls[lastWrite...].filter(isPropPoll).count > 3)
    #expect(fake.value(SonyProperty.shutterSpeed) == 0x0001_00FA)
    #expect(fake.value(SonyProperty.fNumber) == 1100)
}

@Test @MainActor func alreadySetWritesNothing() async throws {
    let fake = FakeCamera()
    fake.settings = FakeCamera.strobeSettings()
    let applier = try await makeApplier(fake)
    let report = try await applier.apply(.strobes)
    #expect(report.items.count == 9)
    #expect(report.items.allSatisfy { $0.outcome == .alreadySet }, "\(report.items)")
    #expect(fake.controlAWrites.isEmpty)
}

@Test @MainActor func displayOnlySettingsAreReportedLocked() async throws {
    let fake = FakeCamera()  // Intelligent Auto, and no mode requested
    let applier = try await makeApplier(fake)
    let report = try await applier.apply(CameraProfile(name: "No mode", shutterSpeed: .init(1, 160), aperture: 8))
    #expect(report.items.map(\.outcome) == [.locked, .locked])
    #expect(fake.controlAWrites.isEmpty)

    // Exposure compensation stays display-only in M.
    fake.settings = FakeCamera.strobeSettings()
    let r2 = try await applier.apply(CameraProfile(name: "EV in M", exposureCompensation: 0.7))
    #expect(r2.items.map(\.outcome) == [.locked])
}

@Test @MainActor func unofferedOrMissingSettingsAreUnsupported() async throws {
    let fake = FakeCamera()
    fake.settings = FakeCamera.strobeSettings()
    fake.settings[SonyProperty.flashCompensation] = nil
    let applier = try await makeApplier(fake)
    let report = try await applier.apply(CameraProfile(name: "Wide", aperture: 4, iso: .value(12800), flashCompensation: -1))

    #expect(report.items.map(\.outcome) == [.unsupported, .unsupported, .unsupported])
    #expect(report.items[0].requested == "f/4 (lens offers f/5.6–22)")
    #expect(report.items[1].requested == "12800 (camera offers Auto–800)")
    #expect(report.items[2].requested == "-1.0 EV")
    #expect(fake.controlAWrites.isEmpty)
}

@Test @MainActor func evSnapsToTheNearestOfferedStep() async throws {
    let fake = FakeCamera()
    fake.settings = FakeCamera.strobeSettings()
    let applier = try await makeApplier(fake)
    let report = try await applier.apply(CameraProfile(name: "Comp", flashCompensation: -0.33))
    #expect(report.items.map(\.outcome) == [.applied])
    #expect(fake.value(SonyProperty.flashCompensation) == -300)
}

@Test @MainActor func valueThatNeverReadsBackIsAMismatch() async throws {
    let fake = FakeCamera()
    fake.settings = FakeCamera.strobeSettings()
    // The ZV-E10 acknowledges flash Off in M/A but keeps Fill.
    fake.ignoredWrites = [SonyProperty.flashMode]
    let applier = try await makeApplier(fake)
    let report = try await applier.apply(CameraProfile(name: "No flash", flashMode: .off, focusMode: .continuous))
    let o = outcomes(report)
    #expect(o["Flash mode"] == .mismatch(actual: "Fill"))
    #expect(o["Focus mode"] == .applied)
}

@Test @MainActor func deviceRefusalIsReportedAndTheApplyContinues() async throws {
    let fake = FakeCamera()
    fake.settings = FakeCamera.strobeSettings()
    fake.inject = { call in
        call.code == PTPOperation.sonySetControlDeviceA && call.parameters == [UInt32(SonyProperty.fNumber)]
            ? .respond(PTPResponseCode.accessDenied) : nil
    }
    let applier = try await makeApplier(fake)
    let report = try await applier.apply(CameraProfile(name: "Refused", shutterSpeed: .init(1, 250), aperture: 11, iso: .value(400)))
    let o = outcomes(report)
    guard case .failed(let why)? = o["Aperture"] else { Issue.record("aperture: \(String(describing: o["Aperture"]))"); return }
    #expect(why.contains("AccessDenied"))
    #expect(o["Shutter speed"] == .applied)
    #expect(o["ISO"] == .applied)
}

@Test @MainActor func transportErrorsPropagate() async throws {
    let fake = FakeCamera()
    fake.inject = { call in
        call.code == PTPOperation.sonySetControlDeviceA ? .fail(NSError(domain: "ICReturnCodeErrorDomain", code: -9923)) : nil
    }
    let applier = try await makeApplier(fake)
    await #expect(throws: NSError.self) { try await applier.apply(.strobes) }
}

@Test @MainActor func readoutUsesHumanStrings() async throws {
    let fake = FakeCamera()
    fake.settings = FakeCamera.strobeSettings()
    let applier = try await makeApplier(fake)
    try await applier.session.refreshProperties()
    #expect(applier.session.readout == CameraReadout(exposureMode: "M", shutterSpeed: "1/160", aperture: "f/8", iso: "100",
                                                     flashMode: "Fill", focusMode: "AF-S", batteryPercent: 80))
    fake.settings = FakeCamera.iAutoSettings()
    fake.settings[SonyProperty.shutterSpeed]?.value = 0x012C_000A
    fake.settings[SonyProperty.batteryLevel]?.value = -1
    try await applier.session.refreshProperties()
    #expect(applier.session.readout == CameraReadout(exposureMode: "Intelligent Auto", shutterSpeed: "30\"", aperture: "f/5.6",
                                                     iso: "Auto", flashMode: "Fill", focusMode: "AF-C", batteryPercent: nil))
}

// MARK: - SonyBoothCamera

@Test @MainActor func profileIsAppliedBeforeReady() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    camera.setProfile(.strobes)
    var reportAtReady: CameraProfileReport?
    let watcher = Task { @MainActor in
        for await s in camera.stateUpdates() where s.isReady {
            reportAtReady = camera.status.lastReport
            break
        }
    }
    camera.start()
    defer { camera.stop(); watcher.cancel() }
    try await waitUntil("ready") { camera.state.isReady }
    await watcher.value

    #expect(reportAtReady?.allOK == true)
    // All writes happened before live view started.
    let lastWrite = try #require(fake.calls.lastIndex { $0.code == PTPOperation.sonySetControlDeviceA })
    let firstLV = try #require(fake.calls.firstIndex { $0.isLiveView })
    #expect(lastWrite < firstLV)
    #expect(camera.status.readout?.exposureMode == "M")
    #expect(camera.status.readout?.shutterSpeed == "1/160")
    #expect(!camera.status.applyingProfile)
    #expect(fake.violations.isEmpty, "\(fake.violations)")
}

@Test @MainActor func setProfileWhileReadyAppliesAndPublishes() async throws {
    let fake = FakeCamera()
    fake.settings = FakeCamera.strobeSettings()
    let camera = makeCamera(fake)
    var seen: [CameraStatus] = []
    let t = Task { @MainActor in for await s in camera.statusUpdates() { seen.append(s) } }
    camera.start()
    defer { camera.stop(); t.cancel() }
    try await waitUntil("ready") { camera.state.isReady }

    camera.setProfile(.ambient)
    #expect(camera.status.profile == .ambient)
    try await waitUntil("ambient report") { camera.status.lastReport?.profileName == "Ambient" }
    #expect(camera.status.lastReport?.items.first?.outcome == .applied)
    #expect(fake.mode == FakeCamera.SonyMode.aperture)
    #expect(camera.status.readout?.exposureMode == "A")
    #expect(camera.status.readout?.aperture == "f/5.6")
    #expect(!camera.status.applyingProfile)
    #expect(seen.contains { $0.applyingProfile })
    #expect(camera.state.isReady)
    #expect(fake.openCount == 1)
}

@Test @MainActor func newerProfileSupersedesAQueuedOne() async throws {
    let fake = FakeCamera()
    fake.settings = FakeCamera.strobeSettings()
    fake.modeReadbackLag = .milliseconds(80)
    let camera = makeCamera(fake)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }

    camera.setProfile(.ambient)
    try await waitUntil("apply underway") { camera.status.applyingProfile }
    camera.setProfile(CameraProfile(name: "Shutter", exposureMode: .shutterPriority))
    camera.setProfile(CameraProfile(name: "Program", exposureMode: .program))
    try await waitUntil("program report") { camera.status.lastReport?.profileName == "Program" && !camera.status.applyingProfile }
    #expect(fake.mode == FakeCamera.SonyMode.program)
    let modeWrites = fake.controlAWrites.filter { $0.parameters == [modeCode] }.map(\.value)
    #expect(modeWrites == [UInt64(FakeCamera.SonyMode.aperture), UInt64(FakeCamera.SonyMode.program)])
}

@Test @MainActor func captureWaitsForAnApplyInFlight() async throws {
    let fake = FakeCamera()
    fake.settings = FakeCamera.strobeSettings()
    fake.modeReadbackLag = .milliseconds(100)
    let camera = makeCamera(fake)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }

    camera.setProfile(.ambient)
    try await waitUntil("apply underway") { camera.status.applyingProfile }
    let photo = try await camera.capture()
    #expect(photo.jpeg == FakeCamera.photo(1))

    let lastWrite = try #require(fake.calls.lastIndex { $0.code == PTPOperation.sonySetControlDeviceA })
    let hp = try #require(fake.calls.firstIndex { halfPress($0) })
    #expect(lastWrite < hp)
    #expect(camera.status.lastReport?.profileName == "Ambient")
    #expect(camera.status.readout?.exposureMode == "A")
    #expect(fake.violations.isEmpty, "\(fake.violations)")
}

@Test @MainActor func applyRequestedDuringCaptureWaitsForIt() async throws {
    let fake = FakeCamera()
    fake.settings = FakeCamera.strobeSettings()
    let camera = makeCamera(fake)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }

    await camera.prepareCapture()
    camera.setProfile(.ambient)  // half-pressed: queued
    try await Task.sleep(for: .milliseconds(30))
    #expect(fake.controlAWrites.isEmpty)
    _ = try await camera.capture()
    try await waitUntil("ambient report") { camera.status.lastReport?.profileName == "Ambient" }
    let firstWrite = try #require(fake.calls.firstIndex { $0.code == PTPOperation.sonySetControlDeviceA && $0.parameters != [UInt32(SonyProperty.priorityMode)] })
    let dl = try #require(fake.calls.firstIndex { $0.isPhotoDownload })
    #expect(dl < firstWrite)
}

@Test @MainActor func statusIsClearedOnDisconnect() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    camera.setProfile(.strobes)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }
    #expect(camera.status.lastReport != nil)
    #expect(camera.status.readout != nil)

    fake.unplug()
    try await waitUntil("searching") { camera.state == .searching }
    #expect(camera.status.lastReport == nil)
    #expect(camera.status.readout == nil)
    #expect(!camera.status.applyingProfile)
    #expect(camera.status.profile == .strobes, "the request survives the disconnect")
}

@Test @MainActor func profileIsReappliedOnReconnect() async throws {
    let fake = FakeCamera()
    let camera = makeCamera(fake)
    let rec = StateRecorder(camera)
    camera.setProfile(.strobes)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }
    #expect(fake.mode == FakeCamera.SonyMode.manual)

    // Someone puts the camera back in auto, then the link drops.
    fake.settings = FakeCamera.iAutoSettings()
    var failed = false
    fake.inject = { call in
        guard call.isLiveView, !failed else { return nil }
        failed = true
        return .fail(NSError(domain: "ICReturnCodeErrorDomain", code: -9923))
    }
    try await waitUntil("second ready") { rec.readyCount == 2 && camera.state.isReady }
    #expect(fake.mode == FakeCamera.SonyMode.manual)
    #expect(fake.value(SonyProperty.shutterSpeed) == 0x0001_00A0)
    #expect(camera.status.lastReport?.allOK == true)
    #expect(camera.status.lastReport?.items.first?.outcome == .applied)
    #expect(fake.controlAWrites.filter { $0.parameters == [modeCode] }.count == 2)
}

@Test @MainActor func refusedSettingsNeverFaultTheConnection() async throws {
    let fake = FakeCamera()
    fake.settings = FakeCamera.strobeSettings()
    fake.inject = { call in
        call.code == PTPOperation.sonySetControlDeviceA ? .respond(PTPResponseCode.generalError) : nil
    }
    let camera = makeCamera(fake)
    camera.start()
    defer { camera.stop() }
    try await waitUntil("ready") { camera.state.isReady }
    camera.setProfile(.ambient)
    try await waitUntil("report") { camera.status.lastReport?.profileName == "Ambient" }
    #expect(camera.status.lastReport?.problems.isEmpty == false)
    #expect(camera.state.isReady)
    #expect(fake.openCount == 1)
}
