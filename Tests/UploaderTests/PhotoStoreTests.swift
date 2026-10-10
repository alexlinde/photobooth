import Testing
import Foundation
@testable import Uploader

struct PhotoStoreTests {
    @Test func namingCollisionsAndFolders() throws {
        let root = tempDir().appendingPathComponent("PhotoBooth")
        let tz = TimeZone(identifier: "America/New_York")!
        let store = PhotoStore(root: root, eventName: "Wedding: A/B", timeZone: tz)
        #expect(store.eventFolder.lastPathComponent == "Wedding- A-B")
        var c = DateComponents(); c.year = 2026; c.month = 3; c.day = 7; c.hour = 21; c.minute = 5; c.second = 9
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let date = cal.date(from: c)!

        let a = try store.save(jpeg: Data([1]), capturedAt: date)
        let b = try store.save(jpeg: Data([2]), capturedAt: date)
        let d = try store.save(jpeg: Data([3]), capturedAt: date)
        #expect(a.lastPathComponent == "20260307-210509.jpg")
        #expect(b.lastPathComponent == "20260307-210509-2.jpg")
        #expect(d.lastPathComponent == "20260307-210509-3.jpg")
        #expect(try Data(contentsOf: b) == Data([2]))
    }
}
