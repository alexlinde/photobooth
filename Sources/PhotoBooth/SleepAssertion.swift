import BoothCore
import Foundation
import IOKit.pwr_mgt

/// Holds a "prevent display sleep" power assertion for as long as the object lives.
final class SleepAssertion {
    private var id: IOPMAssertionID = 0
    private(set) var active = false

    init(reason: String = "PhotoBooth is running") {
        let rc = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        active = rc == kIOReturnSuccess
        if active { BoothLog.info(.app, "Display sleep prevented (assertion \(id))") }
        else { BoothLog.error(.app, "IOPMAssertionCreateWithName failed: \(rc)") }
    }

    func release() {
        guard active else { return }
        IOPMAssertionRelease(id)
        active = false
    }

    deinit { release() }
}
