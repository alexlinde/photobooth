import BoothCore
import AppKit
import Carbon.HIToolbox

/// System-wide attendant hot keys (Carbon `RegisterEventHotKey`): they fire even when
/// PhotoBooth isn't the active app, e.g. when the booth window covers the only screen but some
/// other app underneath has the keyboard. Needs no permissions. The system consumes a
/// registered key combination, so the focused app (including our own local monitor) never
/// sees it.
///
/// Registration can fail (another app already owns the combination); the caller then keeps
/// handling that key in its local monitor.
@MainActor
final class GlobalHotKeys {
    struct Key: Hashable {
        /// Virtual key code (kVK_ANSI_*).
        var keyCode: UInt32
        /// Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
        var modifiers: UInt32
    }

    /// Ctrl+Opt+Cmd.
    static let attendantModifiers = UInt32(controlKey | optionKey | cmdKey)

    var onPress: ((Key) -> Void)?

    private static let signature: OSType = 0x5042_4F48  // 'PBOH'
    private var refs: [UInt32: (Key, EventHotKeyRef)] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    /// The keys currently registered.
    var registered: Set<Key> { Set(refs.values.map(\.0)) }

    /// Registers `key`; false (logged) when the system refuses it.
    @discardableResult
    func register(_ key: Key, name: String) -> Bool {
        guard !registered.contains(key) else { return true }
        guard installHandler() else { return false }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let rc = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        guard rc == noErr, let ref else {
            BoothLog.error(.input, "Couldn't register the system-wide \(name) hot key (OSStatus \(rc)); it works only while PhotoBooth is the active app.")
            return false
        }
        refs[id] = (key, ref)
        return true
    }

    func unregisterAll() {
        for (_, ref) in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func installHandler() -> Bool {
        guard handler == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let rc = InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            guard let event, let ctx else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let rc = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard rc == noErr, hk.signature == GlobalHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<GlobalHotKeys>.fromOpaque(ctx).takeUnretainedValue()
            // Carbon dispatches application-target events on the main thread.
            return MainActor.assumeIsolated { me.fired(hk.id) ? noErr : OSStatus(eventNotHandledErr) }
        }, 1, &spec, ctx, &handler)
        guard rc == noErr else {
            BoothLog.error(.input, "Couldn't install the hot key handler (OSStatus \(rc)); attendant keys work only while PhotoBooth is the active app.")
            handler = nil
            return false
        }
        return true
    }

    private func fired(_ id: UInt32) -> Bool {
        guard let (key, _) = refs[id] else { return false }
        onPress?(key)
        return true
    }
}
