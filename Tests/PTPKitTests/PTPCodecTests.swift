import Foundation
import Testing
@testable import PTPKit

@Test func commandContainerLayout() {
    let d = PTPCodec.command(code: 0x9201, transactionID: 7, parameters: [1, 0, 0])
    #expect([UInt8](d) == [24, 0, 0, 0, 1, 0, 0x01, 0x92, 7, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
}

@Test func parsesResponseContainer() {
    let d = Data([16, 0, 0, 0, 3, 0, 0x01, 0x20, 5, 0, 0, 0, 0xAA, 0, 0, 0])
    let r = PTPCodec.parseContainer(d, type: PTPContainerType.response)
    #expect(r?.code == PTPResponseCode.ok)
    #expect(r?.transactionID == 5)
    #expect(r?.parameters == [0xAA])
    #expect(PTPCodec.parseContainer(d, type: PTPContainerType.event) == nil)
}

@Test func stripsDataHeaderOnlyWhenPresent() {
    let payload = Data([1, 2, 3])
    var w = PTPWriter(); w.u32(15); w.u16(2); w.u16(0x1009); w.u32(1)
    #expect(PTPCodec.stripDataHeader(w.data + payload) == payload)
    #expect(PTPCodec.stripDataHeader(payload) == payload)
}

@Test func extractsJPEGUsingOffsetHeader() {
    // Header whose u32[0] points at the JPEG, with a decoy FFD8 inside the header.
    var bytes: [UInt8] = [8, 0, 0, 0, 0xFF, 0xD8, 0, 0]
    bytes += [0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9, 0x00, 0x00]
    #expect(SonyLiveView.extractJPEG(from: Data(bytes)) == Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9]))
}

@Test func extractsJPEGByScanningWhenOffsetInvalid() {
    let bytes: [UInt8] = [0xFF, 0xFF, 0, 0, 9, 9, 0xFF, 0xD8, 0x42, 0xFF, 0xD9]
    #expect(SonyLiveView.extractJPEG(from: Data(bytes)) == Data([0xFF, 0xD8, 0x42, 0xFF, 0xD9]))
}

@Test func parsesSonyPropertyBlob() {
    var w = PTPWriter()
    w.u32(2); w.u32(0)
    // 0xD215 uint16, getSet 0, enabled 1, default 0, current 0x8001, no form
    w.u16(0xD215); w.u16(PTPDataType.uint16); w.u8(0); w.u8(1); w.u16(0); w.u16(0x8001); w.u8(0)
    // 0xD231 uint8 enum [1,2], current 1
    w.u16(0xD231); w.u16(PTPDataType.uint8); w.u8(1); w.u8(1); w.u8(1); w.u8(1); w.u8(2); w.u16(2); w.u8(1); w.u8(2)
    let props = SonyPropertyParser.parse(w.data)
    #expect(props[0xD215]?.currentValue.uint64 == 0x8001)
    #expect(props[0xD231]?.form == .enumeration([.uint(1), .uint(2)]))
}

@Test func encodesValuesByType() {
    #expect([UInt8](PTPValue.uint(2).encoded(as: PTPDataType.uint16)) == [2, 0])
    #expect([UInt8](PTPValue.int(1).encoded(as: PTPDataType.int8)) == [1])
}
