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

    func testDefaultConfigJSONIsStable() throws {
        let json = String(decoding: BoothConfig().encodedJSON(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"buttonDevice\""))
        XCTAssertTrue(json.contains("\"0x1324\""))
        XCTAssertTrue(json.contains("\"display\" : \"auto\""))
    }
}
