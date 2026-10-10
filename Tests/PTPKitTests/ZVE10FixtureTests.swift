import Foundation
import Testing
@testable import PTPKit

// Payloads recorded from a real ZV-E10 (firmware 2.02) during the Phase 0 spike.
private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "bin"))
    return try Data(contentsOf: url)
}

@Test func parsesRecordedPropertyBlob() throws {
    let props = SonyPropertyParser.parse(try fixture("getalldevicepropdata"))
    #expect(props.count == 93)
    #expect(props[SonyProperty.stillImageStoreDestination]?.form == .enumeration([.uint(1), .uint(0x11), .uint(0x10)]))
    #expect(props[SonyProperty.objectInMemory]?.dataType == PTPDataType.uint16)
    #expect(props[SonyProperty.liveViewSettingEffect]?.currentValue == .uint(1))
}

@Test func extractsRecordedLiveViewFrame() throws {
    let raw = try fixture("liveview-raw")
    let jpeg = try #require(SonyLiveView.extractJPEG(from: raw))
    #expect(jpeg.starts(with: [0xFF, 0xD8]))
    #expect(Array(jpeg.suffix(2)) == [0xFF, 0xD9])
    // Header u32[0] is the JPEG offset (0x7F4 on this body).
    #expect(raw.count - jpeg.count >= 0x7F4)
}

@Test func parsesRecordedDeviceInfoOperations() throws {
    var r = PTPReader(try fixture("getdeviceinfo"))
    _ = try r.u16(); #expect(try r.u32() == 0x11)  // Sony vendor extension
    _ = try r.u16(); #expect(try r.string() == "Sony PTP Extensions")
    _ = try r.u16()
    let ops = try r.array { try $0.u16() }
    #expect(ops.contains(PTPOperation.sonySDIOConnect))
    #expect(ops.contains(PTPOperation.sonyGetAllDevicePropData))
}

// The recorded blob was captured in Intelligent Auto, which is why the profile properties
// below are display-only there (isEnabled 2) and the exposure ones offer no values.
@Test func recordedBlobHasProfilePropertiesWithExpectedTypes() throws {
    let props = SonyPropertyParser.parse(try fixture("getalldevicepropdata"))
    let mode = try #require(props[SonyProperty.exposureProgramMode])
    #expect(mode.dataType == PTPDataType.uint32)
    #expect(mode.currentValue == .uint(0x0004_8000))  // Intelligent Auto
    #expect(mode.isEnabled == 1)

    let expected: [(UInt16, UInt16)] = [
        (SonyProperty.whiteBalance, PTPDataType.uint16), (SonyProperty.fNumber, PTPDataType.uint16),
        (SonyProperty.focusMode, PTPDataType.uint16), (SonyProperty.flashMode, PTPDataType.uint16),
        (SonyProperty.exposureBiasCompensation, PTPDataType.int16), (SonyProperty.flashCompensation, PTPDataType.int16),
        (SonyProperty.shutterSpeed, PTPDataType.uint32), (SonyProperty.iso, PTPDataType.uint32),
        (SonyProperty.liveViewSettingEffect, PTPDataType.uint8), (SonyProperty.batteryLevel, PTPDataType.int8),
    ]
    for (code, type) in expected {
        #expect(props[code]?.dataType == type, "\(hex16(code))")
    }
    #expect(props[SonyProperty.fNumber]?.isEnabled == 2)
    #expect(props[SonyProperty.fNumber]?.form == .enumeration([]))
    #expect(props[SonyProperty.liveViewSettingEffect]?.isEnabled == 2)
    #expect(props[SonyProperty.batteryLevel]?.form == .range(min: .int(-1), max: .int(100), step: .int(1)))
}
