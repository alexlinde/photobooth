// The scenarios themselves live in BoothScenarios.swift so `PhotoBooth --self-test`
// and XCTest exercise exactly the same code.
import ImageIO
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

    /// The ZV-E10 tags landscape shots as orientation 6 when tilted; the booth resets it to 1
    /// without touching the compressed image data.
    func testUprightResetsOrientationLosslessly() throws {
        let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 36))
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
        let rotated = out as Data

        func orientation(_ d: Data) -> Int? {
            let src = CGImageSourceCreateWithData(d as CFData, nil)!
            let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            return p?[kCGImagePropertyOrientation] as? Int
        }
        func scan(_ d: Data) -> Data {
            let b = [UInt8](d)
            let i = (0..<(b.count - 1)).last { b[$0] == 0xFF && b[$0 + 1] == 0xDA }!
            return Data(b[i...])
        }
        XCTAssertEqual(orientation(rotated), 6)
        let upright = JPEGOrientation.upright(rotated)
        XCTAssertEqual(orientation(upright), 1)
        XCTAssertEqual(scan(upright), scan(rotated), "pixels must not be recompressed")
        XCTAssertEqual(JPEGOrientation.upright(upright), upright, "already upright → unchanged")
    }
}
