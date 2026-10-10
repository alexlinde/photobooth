import BoothCore
import CoreGraphics
import Foundation
import SonyCamera

/// Chooses the camera implementation.
@MainActor
enum CameraFactory {
    static func make(options: AppOptions, clock: BoothClock) -> BoothCamera {
        if options.fakeCamera {
            var o = FakeBoothCamera.Options()
            o.failRate = options.fakeFailRate
            return FakeBoothCamera(options: o, clock: clock)
        }
        var o = SonyBoothCamera.Options()
        o.log = { BoothLog.info(.camera, $0) }
        return SonyBoothCamera(options: o)
    }
}
