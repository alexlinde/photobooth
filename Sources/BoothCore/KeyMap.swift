import Foundation

/// A button key, resolved from the human-written `buttonKey` config value.
///
/// Accepted spellings (case-insensitive):
/// - Names: `a`…`z`, `0`…`9`, `space`, `return`, `enter` (keypad Enter), `tab`, `escape`,
///   `delete`/`backspace`, `forwarddelete`, `up`/`down`/`left`/`right`, `home`, `end`,
///   `pageup`, `pagedown`, `f1`…`f24`, `kp0`…`kp9`, punctuation such as `-` `=` `[` `]`
///   `;` `'` `,` `.` `/` `` ` `` `\` (also by name: `minus`, `comma`, …).
/// - Raw HID usage (keyboard usage page 0x07): `hid:0x2c`, `hid:44`, `0x2c`, or a JSON
///   number `44`. Raw usages that are not in the table work in `hid` mode only.
public struct KeySpec: Equatable, Sendable, CustomStringConvertible {
    /// HID usage on the keyboard/keypad usage page (0x07).
    public var hidUsage: UInt32
    /// macOS virtual key code (`NSEvent.keyCode`), when known.
    public var keyCode: UInt16?
    /// Canonical config name (e.g. "space"), or "hid:0x.." when not in the table.
    public var name: String

    public var description: String {
        let kc = keyCode.map { String($0) } ?? "none"
        return "\(name) (HID usage 0x\(String(hidUsage, radix: 16)) = \(hidUsage), keyCode \(kc))"
    }

    static func parse(_ raw: String) -> KeySpec? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        if s.count > 1 || !s.first!.isNumber {
            if let e = KeyMap.byName[s] ?? KeyMap.byName[KeyMap.aliases[s] ?? ""] {
                return KeySpec(hidUsage: e.hid, keyCode: e.keyCode, name: e.name)
            }
        } else if let e = KeyMap.byName[s] { // single digit
            return KeySpec(hidUsage: e.hid, keyCode: e.keyCode, name: e.name)
        }
        var num = s
        if num.hasPrefix("hid:") { num.removeFirst(4) }
        let value: UInt32?
        if num.hasPrefix("0x") { value = UInt32(num.dropFirst(2), radix: 16) } else { value = UInt32(num) }
        guard let usage = value, usage > 0, usage <= 0xFFFF else { return nil }
        return KeySpec(hidUsage: usage)
    }

    /// From a raw HID usage: uses the table name when known.
    init(hidUsage: UInt32) {
        if let e = KeyMap.byHID[hidUsage] {
            self.init(hidUsage: e.hid, keyCode: e.keyCode, name: e.name)
        } else {
            self.init(hidUsage: hidUsage, keyCode: nil, name: "hid:0x" + String(hidUsage, radix: 16))
        }
    }

    init(hidUsage: UInt32, keyCode: UInt16?, name: String) {
        self.hidUsage = hidUsage
        self.keyCode = keyCode
        self.name = name
    }
}

public enum KeyMap {
    struct Entry: Sendable {
        let name: String
        let hid: UInt32
        let keyCode: UInt16?
    }

    /// name, HID usage (page 0x07), macOS virtual keyCode (kVK_*).
    static let entries: [Entry] = {
        var e: [Entry] = []
        let letters: [(String, UInt16)] = [
            ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14), ("f", 3), ("g", 5), ("h", 4),
            ("i", 34), ("j", 38), ("k", 40), ("l", 37), ("m", 46), ("n", 45), ("o", 31),
            ("p", 35), ("q", 12), ("r", 15), ("s", 1), ("t", 17), ("u", 32), ("v", 9),
            ("w", 13), ("x", 7), ("y", 16), ("z", 6),
        ]
        for (i, (n, kc)) in letters.enumerated() { e.append(Entry(name: n, hid: 0x04 + UInt32(i), keyCode: kc)) }
        // Digits: HID 1..9 = 0x1E..0x26, 0 = 0x27.
        let digitCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25] // 1..9
        for d in 1...9 { e.append(Entry(name: "\(d)", hid: 0x1D + UInt32(d), keyCode: digitCodes[d - 1])) }
        e.append(Entry(name: "0", hid: 0x27, keyCode: 29))
        e += [
            Entry(name: "return", hid: 0x28, keyCode: 36),
            Entry(name: "escape", hid: 0x29, keyCode: 53),
            Entry(name: "delete", hid: 0x2A, keyCode: 51),
            Entry(name: "tab", hid: 0x2B, keyCode: 48),
            Entry(name: "space", hid: 0x2C, keyCode: 49),
            Entry(name: "-", hid: 0x2D, keyCode: 27),
            Entry(name: "=", hid: 0x2E, keyCode: 24),
            Entry(name: "[", hid: 0x2F, keyCode: 33),
            Entry(name: "]", hid: 0x30, keyCode: 30),
            Entry(name: "\\", hid: 0x31, keyCode: 42),
            Entry(name: ";", hid: 0x33, keyCode: 41),
            Entry(name: "'", hid: 0x34, keyCode: 39),
            Entry(name: "`", hid: 0x35, keyCode: 50),
            Entry(name: ",", hid: 0x36, keyCode: 43),
            Entry(name: ".", hid: 0x37, keyCode: 47),
            Entry(name: "/", hid: 0x38, keyCode: 44),
            Entry(name: "capslock", hid: 0x39, keyCode: 57),
        ]
        // F1–F12: HID 0x3A–0x45.
        let fCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for i in 1...12 { e.append(Entry(name: "f\(i)", hid: 0x39 + UInt32(i), keyCode: fCodes[i - 1])) }
        e += [
            Entry(name: "printscreen", hid: 0x46, keyCode: nil),
            Entry(name: "scrolllock", hid: 0x47, keyCode: nil),
            Entry(name: "pause", hid: 0x48, keyCode: nil),
            Entry(name: "insert", hid: 0x49, keyCode: 114), // kVK_Help
            Entry(name: "home", hid: 0x4A, keyCode: 115),
            Entry(name: "pageup", hid: 0x4B, keyCode: 116),
            Entry(name: "forwarddelete", hid: 0x4C, keyCode: 117),
            Entry(name: "end", hid: 0x4D, keyCode: 119),
            Entry(name: "pagedown", hid: 0x4E, keyCode: 121),
            Entry(name: "right", hid: 0x4F, keyCode: 124),
            Entry(name: "left", hid: 0x50, keyCode: 123),
            Entry(name: "down", hid: 0x51, keyCode: 125),
            Entry(name: "up", hid: 0x52, keyCode: 126),
            Entry(name: "kp/", hid: 0x54, keyCode: 75),
            Entry(name: "kp*", hid: 0x55, keyCode: 67),
            Entry(name: "kp-", hid: 0x56, keyCode: 78),
            Entry(name: "kp+", hid: 0x57, keyCode: 69),
            Entry(name: "enter", hid: 0x58, keyCode: 76),
        ]
        // Keypad 1..9 = 0x59..0x61, 0 = 0x62.
        let kpCodes: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
        for d in 1...9 { e.append(Entry(name: "kp\(d)", hid: 0x58 + UInt32(d), keyCode: kpCodes[d - 1])) }
        e.append(Entry(name: "kp0", hid: 0x62, keyCode: 82))
        e.append(Entry(name: "kp.", hid: 0x63, keyCode: 65))
        e.append(Entry(name: "kp=", hid: 0x67, keyCode: 81))
        // F13–F24: HID 0x68–0x73. macOS keyCodes exist up to F20.
        let f13Codes: [UInt16?] = [105, 107, 113, 106, 64, 79, 80, 90, nil, nil, nil, nil]
        for i in 13...24 { e.append(Entry(name: "f\(i)", hid: 0x5B + UInt32(i), keyCode: f13Codes[i - 13])) }
        return e
    }()

    static let aliases: [String: String] = [
        "enter_main": "return", "ret": "return", "esc": "escape", "backspace": "delete",
        "del": "forwarddelete", "spacebar": "space", "pgup": "pageup", "pgdn": "pagedown",
        "minus": "-", "equal": "=", "equals": "=", "leftbracket": "[", "rightbracket": "]",
        "backslash": "\\", "semicolon": ";", "quote": "'", "grave": "`", "comma": ",",
        "period": ".", "slash": "/", "uparrow": "up", "downarrow": "down",
        "leftarrow": "left", "rightarrow": "right", "keypadenter": "enter", "kpenter": "enter",
    ]

    static let byName: [String: Entry] = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    static let byHID: [UInt32: Entry] = Dictionary(entries.map { ($0.hid, $0) }, uniquingKeysWith: { a, _ in a })
    static let byKeyCode: [UInt16: Entry] = {
        var d: [UInt16: Entry] = [:]
        for e in entries { if let kc = e.keyCode, d[kc] == nil { d[kc] = e } }
        return d
    }()

    /// Config string to use for a key seen via HID.
    public static func configString(hidUsage: UInt32) -> String {
        byHID[hidUsage]?.name ?? "hid:0x" + String(hidUsage, radix: 16)
    }

    /// Config string to use for a key seen via NSEvent (nil when unknown — use HID mode).
    public static func configString(keyCode: UInt16) -> String? { byKeyCode[keyCode]?.name }
}
