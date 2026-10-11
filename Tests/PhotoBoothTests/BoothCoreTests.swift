// The scenarios themselves live in BoothScenarios.swift so `PhotoBooth --self-test`
// and XCTest exercise exactly the same code.
import XCTest
@testable import BoothCore

@MainActor
final class BoothCoreTests: XCTestCase {
    func testHappyPathOneShot() async throws { try await BoothScenarios.happyPathOneShot() }
    func testThreeShots() async throws { try await BoothScenarios.threeShots() }
    func testPressDuringCountdownIgnored() async throws { try await BoothScenarios.pressDuringCountdownIgnored() }
    func testDebounce() async throws { try await BoothScenarios.debounce() }
    func testCaptureFailureThenIdle() async throws { try await BoothScenarios.captureFailureThenIdle() }
    func testThreeFailuresAttendant() async throws { try await BoothScenarios.threeFailuresAttendant() }
    func testCameraDropMidIdle() async throws { try await BoothScenarios.cameraDropMidIdle() }
    func testCameraDropDuringCountdown() async throws { try await BoothScenarios.cameraDropDuringCountdown() }
    func testStorageFailure() async throws { try await BoothScenarios.storageFailure() }
    func testLocalSinkNaming() async throws { try await BoothScenarios.localSinkNaming() }
    func testConfigParsing() async throws { try await BoothScenarios.configParsing() }
    func testKeyMapping() async throws { try await BoothScenarios.keyMapping() }
    func testPauseResume() async throws { try await BoothScenarios.pauseResume() }
    func testLightingProfiles() async throws { try await BoothScenarios.lightingProfiles() }
    func testScreenLayout() async throws { try await BoothScenarios.screenLayout() }
    func testStripMode() async throws { try await BoothScenarios.stripMode() }
    func testStripModeRetry() async throws { try await BoothScenarios.stripModeRetry() }
    func testStripModeAbort() async throws { try await BoothScenarios.stripModeAbort() }
    func testMissedFlashBrightness() async throws { try await BoothScenarios.missedFlashBrightness() }
    func testMissedFlashRetake() async throws { try await BoothScenarios.missedFlashRetake() }
    func testStripModeMissedFlash() async throws { try await BoothScenarios.stripModeMissedFlash() }
    func testMissedFlashAmbient() async throws { try await BoothScenarios.missedFlashAmbient() }

    func testDefaultConfigJSONIsStable() throws {
        let json = String(decoding: BoothConfig().encodedJSON(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"buttonDevice\""))
        XCTAssertTrue(json.contains("\"0x1324\""))
        XCTAssertTrue(json.contains("\"display\" : \"auto\""))
    }
}
