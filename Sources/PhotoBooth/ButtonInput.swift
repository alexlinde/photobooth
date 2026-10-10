import BoothCore
import AppKit
import IOKit.hid

/// Guest button input plus attendant shortcuts.
///
/// - `hid` mode: `IOHIDManager` on keyboard devices (optionally only the configured USB
///   device), key-down on usage page 7. Works when the app isn't frontmost. Needs Input
///   Monitoring permission; falls back to `local` automatically when it's not granted and
///   switches back once it is.
/// - `local` mode: `NSEvent` local monitor (app must be focused). The device filter cannot
///   apply in this mode.
///
/// A local monitor is always installed for the attendant shortcuts (Ctrl+Opt+Cmd+Q quit,
/// Ctrl+Opt+Cmd+R reset/reload, Ctrl+Opt+Cmd+D fake-camera disconnect) and to swallow plain
/// key presses so the kiosk window doesn't beep.
@MainActor
final class ButtonInput {
    struct DeviceInfo: Equatable, CustomStringConvertible {
        var vendorID: Int
        var productID: Int
        var product: String
        var manufacturer: String
        var description: String {
            String(format: "%@ (%@) vendorID 0x%04X (%d) productID 0x%04X (%d)", product, manufacturer, vendorID, vendorID, productID, productID)
        }
    }

    struct RawPress {
        enum Source: String { case hid = "HID", nsevent = "NSEvent" }
        var source: Source
        var hidUsage: UInt32?
        var keyCode: UInt16?
        var characters: String?
        var device: DeviceInfo?

        /// Config `buttonKey` value for this press, when derivable.
        var configString: String? {
            if let u = hidUsage { return KeyMap.configString(hidUsage: u) }
            if let k = keyCode { return KeyMap.configString(keyCode: k) }
            return nil
        }
    }

    enum Shortcut { case quit, attendantReset, simulateDisconnect }

    enum Mode: String { case hid, local }

    struct Status: Equatable {
        var mode: Mode
        /// Why we're in local mode although HID was requested.
        var fallbackReason: String?
        /// nil when there's no device filter (or not in HID mode).
        var deviceConnected: Bool?
        var deviceDescription: String?
    }

    var onPress: (() -> Void)?
    var onRaw: ((RawPress) -> Void)?
    var onShortcut: ((Shortcut) -> Void)?
    var onStatusChange: ((Status) -> Void)?

    private(set) var status: Status
    private var key: KeySpec?
    private var requestedMode: Mode
    private var deviceFilter: BoothConfig.DeviceFilter?
    /// Learn mode: report every key from every keyboard; no matching.
    private let learn: Bool

    private var manager: IOHIDManager?
    private var matchedDevices = 0
    private var localMonitor: Any?
    private var permissionTimer: Timer?

    init(key: KeySpec?, mode: BoothConfig.ButtonInput, deviceFilter: BoothConfig.DeviceFilter?, learn: Bool = false) {
        self.key = key
        self.requestedMode = mode == .hid ? .hid : .local
        self.deviceFilter = learn ? nil : deviceFilter
        self.learn = learn
        self.status = Status(mode: .local)
    }

    func start() {
        installLocalMonitor()
        if requestedMode == .hid || learn {
            startHIDOrFallBack()
        } else {
            setStatus(Status(mode: .local))
            if deviceFilter != nil {
                BoothLog.info(.input, "buttonInput is \"local\": buttonDevice filter can't apply to NSEvent input; any keyboard's \(key?.name ?? "?") will trigger.")
            }
        }
        BoothLog.info(.input, "Button input started: mode \(status.mode.rawValue), key \(key?.description ?? "none")\(deviceFilter.map { ", device " + $0.hexDescription } ?? "")")
    }

    func stop() {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        localMonitor = nil
        stopHID()
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    /// Apply new settings (config reload).
    func reconfigure(key: KeySpec?, mode: BoothConfig.ButtonInput, deviceFilter: BoothConfig.DeviceFilter?) {
        let newMode: Mode = mode == .hid ? .hid : .local
        guard key != self.key || newMode != requestedMode || deviceFilter != self.deviceFilter else { return }
        stop()
        self.key = key
        self.requestedMode = newMode
        self.deviceFilter = deviceFilter
        start()
    }

    // MARK: Permission

    static func hidAccess() -> IOHIDAccessType { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) }

    static let permissionHelp = "Open System Settings → Privacy & Security → Input Monitoring and turn on PhotoBooth (or the Terminal app when running from a terminal). Until then the button only works while the booth window is focused."

    private func startHIDOrFallBack() {
        var access = Self.hidAccess()
        if access == kIOHIDAccessTypeUnknown {
            BoothLog.info(.input, "Requesting Input Monitoring access")
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            access = Self.hidAccess()
        }
        if access == kIOHIDAccessTypeGranted, openHID() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            setStatus(hidStatus())
            return
        }
        let reason = access == kIOHIDAccessTypeGranted
            ? "Could not open HID keyboard devices; using focused-window keyboard input."
            : "Input Monitoring permission not granted; using focused-window keyboard input."
        BoothLog.error(.input, reason + " " + Self.permissionHelp)
        setStatus(Status(mode: .local, fallbackReason: reason))
        // Poll until the permission is granted, then switch to HID.
        if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, Self.hidAccess() == kIOHIDAccessTypeGranted else { return }
                    BoothLog.info(.input, "Input Monitoring granted; switching to HID input")
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                    self.startHIDOrFallBack()
                }
            }
        }
    }

    private func hidStatus() -> Status {
        Status(mode: .hid, fallbackReason: nil,
               deviceConnected: deviceFilter == nil ? nil : matchedDevices > 0,
               deviceDescription: deviceFilter?.hexDescription)
    }

    private func setStatus(_ s: Status) {
        guard s != status else { return }
        status = s
        onStatusChange?(s)
    }

    // MARK: HID

    private func openHID() -> Bool {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        var matches: [[String: Any]] = []
        for usage in [kHIDUsage_GD_Keyboard, kHIDUsage_GD_Keypad] {
            var d: [String: Any] = [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: usage,
            ]
            if let f = deviceFilter {
                d[kIOHIDVendorIDKey] = f.vendorID
                d[kIOHIDProductIDKey] = f.productID
            }
            matches.append(d)
        }
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<ButtonInput>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.deviceChanged(device, added: true) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<ButtonInput>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.deviceChanged(device, added: false) }
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(m, { ctx, _, _, value in
            guard let ctx else { return }
            let me = Unmanaged<ButtonInput>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.hidValue(value) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let rc = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        guard rc == kIOReturnSuccess else {
            BoothLog.error(.input, String(format: "IOHIDManagerOpen failed: 0x%08X", rc))
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return false
        }
        manager = m
        return true
    }

    private func stopHID() {
        guard let m = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        matchedDevices = 0
    }

    private func deviceChanged(_ device: IOHIDDevice, added: Bool) {
        matchedDevices = max(0, matchedDevices + (added ? 1 : -1))
        BoothLog.info(.input, "HID device \(added ? "connected" : "removed"): \(Self.info(device)) (\(matchedDevices) matched)")
        if status.mode == .hid { setStatus(hidStatus()) }
    }

    static func info(_ device: IOHIDDevice) -> DeviceInfo {
        func prop(_ k: String) -> Any? { IOHIDDeviceGetProperty(device, k as CFString) }
        return DeviceInfo(vendorID: prop(kIOHIDVendorIDKey) as? Int ?? 0,
                          productID: prop(kIOHIDProductIDKey) as? Int ?? 0,
                          product: prop(kIOHIDProductKey) as? String ?? "?",
                          manufacturer: prop(kIOHIDManufacturerKey) as? String ?? "?")
    }

    private func hidValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad) else { return }
        let usage = IOHIDElementGetUsage(element)
        // 0x00–0x03 are reserved / error-rollover codes.
        guard usage >= 0x04, usage <= 0xFFFF, IOHIDValueGetIntegerValue(value) != 0 else { return }
        if learn {
            let device = IOHIDElementGetDevice(element)
            onRaw?(RawPress(source: .hid, hidUsage: usage, keyCode: nil, characters: nil, device: Self.info(device)))
            return
        }
        guard status.mode == .hid, let key, usage == key.hidUsage else { return }
        onPress?()
    }

    // MARK: Local monitor

    private func installLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let e = event
            nonisolated(unsafe) var result: NSEvent? = e
            MainActor.assumeIsolated { result = self?.handleLocal(e) ?? e }
            return result
        }
    }

    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isSuperset(of: [.control, .option, .command]) {
            switch event.keyCode {
            case 12: onShortcut?(.quit); return nil                // Q
            case 15: onShortcut?(.attendantReset); return nil      // R
            case 2: onShortcut?(.simulateDisconnect); return nil   // D
            default: break
            }
        }
        // Let Cmd-key equivalents (Cmd+Q) through to the menu.
        if mods.contains(.command) { return event }
        if learn {
            if !event.isARepeat {
                onRaw?(RawPress(source: .nsevent, hidUsage: nil, keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, device: nil))
            }
            return nil
        }
        if status.mode == .local, !event.isARepeat, let kc = key?.keyCode, event.keyCode == kc,
           mods.intersection([.control, .option]).isEmpty {
            onPress?()
        }
        return nil // swallow: no beeps, and Esc does nothing.
    }
}
