# H-Mod StealthSwitch 3: USB configuration protocol

This document records how H-Mod's 2015 configuration app programs the StealthSwitch 3 foot switch. The goal is to reprogram the device without that app once Rosetta, and with it the x86_64-only app, goes away. Every statement carries one of these tags:

- **[V] Verified.** Observed directly: disassembly with exact constants, on-disk data, or a live read-only query of the device.
- **[I] Inferred.** Reasoned from the code but not yet observed on the wire or on the device.
- **[?] Open.** Must be settled by the live capture (see section 6).

Sources:
- `/Applications/StealthSwitch3.app` (bundle `com.stealthswitch.StealthSwitch3`, version 2.1, built 2015 with the 10.10 SDK).
- The helper `Contents/MacOS/RoboCon.app` (`com.stealthswitch.RoboCon`). It contains an identical copy of the programming code [V].
- No public documentation describes this protocol (see section 5).

---

## 1. Device identification

All of this was read live with standard descriptor reads only [V].

| Field | Value |
|---|---|
| VID / PID | `0x1324` / `0x0103` (not in usb.ids; not an Ultimarc VID. Ultimarc uses `0xD208`/`0xD209`) |
| bcdUSB / bcdDevice | 1.10 / `0x1002` |
| Speed | low speed, bMaxPacketSize0 = 8 |
| Strings | iManufacturer=1 "Ultimarc", iProduct=2 "Button/Joystick/Trackball Interface", no serial |
| Device descriptor | `12 01 10 01 00 00 00 08 24 13 03 01 02 10 01 02 00 01` |
| Configuration | 1 configuration, 59 bytes, bus powered, 100 mA, 2 interfaces |
| Interface 0, "Button/Joystick" | HID boot keyboard (03/01/01), report descriptor 63 bytes, EP 0x81 interrupt IN, 8 bytes, 10 ms. The key array's logical max is 0x68 (F13). |
| Interface 1, "Trackball" | HID boot mouse (03/01/02), report descriptor 99 bytes, EP 0x82 interrupt IN, 8 bytes, 10 ms. Report IDs 1 and 2 (mouse + keyboard). |
| macOS service class | `IOUSBHostDevice`. The app's legacy `IOServiceMatching("IOUSBDevice")` + `idVendor`/`idProduct` still matches it on macOS 26 [V]. |

Configuration descriptor (live):
```
09 02 3b 00 02 01 04 80 32 09 04 00 00 01 03 01 01 05 09 21 10 01 00 01 22 3f 00 07 05 81 03 08
00 0a 09 04 01 00 01 03 01 02 06 09 21 10 01 00 01 22 63 00 07 05 82 03 08 00 0a
```

The device has no vendor interface and no bulk endpoints. **Configuration happens only through vendor control requests on endpoint 0** [V]. HID SET_REPORT is not used.

---

## 2. Transport recovered by static analysis

### 2.1 Code path [V]

The programming code is `-[SSProgrammer programConfiguration:permanent:]` at `0x100005877` in `StealthSwitch3`. The binary is stripped, so method addresses come from the ObjC metadata.

1. A static helper at `0x100005e52` builds `IOServiceMatching("IOUSBDevice")` with `idVendor = 0x1324` and `idProduct = 0x0103`. `IOServiceGetMatchingService` then finds the device.
2. `IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, …)`. The UUIDs `9DC7B780-9EC0-11D4-A54F-000A27052861` and `C244E858-109C-11D4-91D4-0050E4C6426F` are passed as `CFUUIDGetConstantUUIDWithBytes` immediates.
3. `QueryInterface(kIOUSBDeviceInterfaceID182)`, UUID `152FC496-4891-11D5-9D52-000A27801E86`. The plug-in is then released (vtable +0x18).
4. The calls go through the `IOUSBDeviceInterface182` vtable. The offsets below were checked with `offsetof()` against the current SDK's `IOUSBLib.h`.

| vtable offset | Method | Use |
|---|---|---|
| `+0x08` | QueryInterface | on the plug-in |
| `+0x18` | Release | on the plug-in |
| `+0xE8` | **USBDeviceOpenSeize** | opens the device; on failure, NSLog "could not open usb device (%08x)" |
| `+0xF0` | **DeviceRequestTO** | every transfer |
| `+0x48` | **USBDeviceClose** | at the end, on success or failure |

The app makes no other USB calls. There are no `IOUSBInterfaceInterface` calls, no pipe I/O and no HID Manager calls. The device interface object is never released, which is a small leak in the app.

### 2.2 Request sequence [V]

Every request uses `IOUSBDevRequestTO` with `noDataTimeout = 50 ms` and `completionTimeout = 100 ms`. In each request, wIndex is always 0.

| # | bmRequestType | bRequest | wValue | wLength | Data | App's error string |
|---|---|---|---|---|---|---|
| 1 | `0x43` (OUT, vendor, recipient *other*) | `0xE9` | `0x0001` | 0 | none | "start download error (%08x)" |
| 2 | `0x43` | `0xEB` | `0x0000` | 32 | image bytes 0–31 | "send data error (%08x) block (%d)" |
| 3 | `0xC3` (IN, vendor, other) | `0xEA` | `0x0000` | 1 | 1 status byte | "check data error (%08x) block (%d)" |
| 4–5 | as 2–3 | | | | image bytes 32–63 | |
| 6–7 | as 2–3 | | | | image bytes 64–95 | |
| 8 | `0x43` | `0xE9` | `0x0000` | 0 | none | "end download error (%08x)" |

How the app handles each step:
- **Status byte after each block** [V]:
  - `0x01`: OK, continue.
  - `0x03`: abort with "incorrect download checksum".
  - Anything else: abort with "device download error (%d) block (%d)".
- **On any error** the app skips the "end download" request and goes straight to `USBDeviceClose` [V].
- **Block number is not sent** [V]. wValue and wIndex are 0 for all three blocks, so the device must count blocks itself after the 0xE9/wValue=1 "start". [I]: the device probably resets its block counter on "start download".
- **Return value:** success means every step returned `kIOReturnSuccess` and every status byte was `0x01`.
- **On success** the UI plays the "Hero" sound [V].

**Read-back or verify path: none** [V]. Neither binary contains a request that reads the configuration back. The only device-to-host vendor request is the 1-byte `0xEA` status. The `0xEA` status is the only verification, and it appears to check the checksum (status 3).

Also not implemented in either binary [V]: a firmware version query, a reset, and a configuration readback.

### 2.3 "Permanent" vs. not [V for the byte, I for its meaning]

`programConfiguration:permanent:` writes image byte **58** (labelled `control mode` by the app's own debug dump at `0x100009753`) after building the image:

- `permanent == YES` → byte 58 = `0x00`
- `permanent == NO` → byte 58 = `0x04`

Both shipping callers pass `permanent:YES`: `-[SSConfigurator programSwitch:]` in the main app, and the RoboCon helper. **The 0x04 path is never exercised by the shipped apps** [V].

[I]: 0x04 most likely means "apply but don't commit to EEPROM" (RAM only, lost at power-off). Byte 58 is outside the checksummed range, so it would not affect the status-3 check. Do not experiment with 0x04 until a baseline capture has confirmed the rest of the model.

---

## 3. The 96-byte configuration image

The image is built by `-[SSConfiguration keyConfigurationForType:]` (`0x100004a9d`) into a 0x60-byte C struct. The app's own debug printer `SSKeyConfig {…}` (`0x100009753`) names the fields. All offsets in this section are [V].

| Offset | Size | App's name | Contents |
|---|---|---|---|
| 0 | 1 | `shiftnumber` | Firmware input index (1–28) of the switch acting as shift. `0xFF` = no shift switch. |
| 1–28 | 28 | `normalcode[0..27]` | Code sent by firmware input *i* (= byte offset *i*), unshifted |
| 29–56 | 28 | `shiftcode[0..27]` | Code for input *i* while shift is held: offset *i* + 28 |
| 57 | 1 | `checksum` | `sum(bytes[0..56]) & 0xFF` (8-bit sum of the first 57 bytes) |
| 58 | 1 | `control mode` | `0x00` = permanent; `0x04` = non-permanent (see 2.3) |
| 59–74 | 16 | `macro[0..3]` | 4 macros × 4 codes: macro *m* (1-based) = bytes `59+4(m−1)` … `62+4(m−1)` |
| 75–95 | 21 | (unused) | zero |

Notes on the image:
- The checksum is the low byte of the sum of bytes 0–56. It covers byte 0 and both code tables. It does **not** cover byte 58 or the macros [V].
- The image starts zero-filled, so inputs not mapped to a switch are `0x00`. Codes the user leaves blank in the UI are `0xFF` (`<none>`) [V].
- [I]: the firmware is a generic 28-input Ultimarc-style button encoder. H-Mod wires its 5 or 10 jacks to a subset of those inputs.

### 3.1 Switch → firmware-input map [V]

`+[SSSwitch shiftNumberForSwitch:product:]` uses two tables at `0x10000e018` and `0x10000e023`.

| UI switch # | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|
| hardware type 0 (5-switch) | 8 | 10 | 12 | 5 | 3 | | | | | |
| hardware type 1 (10-switch) | 3 | 1 | 4 | 16 | 20 | 8 | 6 | 2 | 18 | 22 |

Index 0 in both tables is `0xFF`, so "no shift switch" encodes as 0xFF.

How the hardware type is chosen (`harwareTypeForProductType:`, `0x100005757`) [V]:
- 1 if the configuration's `type` is 1.
- Also 1 if the user default `SSEdition` is `"AT"`, in this app's domain or in `com.stealthswitch.StealthSwitch2`.
- Otherwise the configuration's `type`.

On this Mac:
- `SSEdition = "II"`.
- Both saved configurations have `type = 0`.
- **So this device is programmed as hardware type 0, the 5-switch layout** [V for the app's choice; [?] for which physical jacks map to inputs 8/10/12/5/3].

Image construction: for switch *n* = 1..5 (type 0) or 1..10 (type 1), with idx = map[*n*], the app sets `image[idx] = normalCode` and `image[idx+28] = shiftedCode`. Byte 0 is `map[shiftSwitchNumber]`, where `shiftSwitchNumber` is the first switch found with `shift = true`, or 0 if none [V].

### 3.2 Key-code encoding [V for the app's table, I for the firmware semantics]

Codes are **PS/2 Scan Code Set 2 make codes**, not HID usages. The app's name → code table at `0x1000143e0` has 125 entries `{NSString *name; uint32 code}`. Codes there are stored as `0xE0xx` for E0-prefixed keys. When the app converts them to a byte (`0x10000983b`, `0x100009870`), it uses:

```
byte = ((code & 0xFFFFFF00) == 0xE000) ? (0x80 | (code & 0x7F)) : (code & 0xFF)
```

The `.ssconfig` files store the **byte**, e.g. `normalCode = 208` for Left Mouse Click.

| Group | Byte values |
|---|---|
| Letters | A 1C, B 32, C 21, D 23, E 24, F 2B, G 34, H 33, I 43, J 3B, K 42, L 4B, M 3A, N 31, O 44, P 4D, Q 15, R 2D, S 1B, T 2C, U 3C, V 2A, W 1D, X 22, Y 35, Z 1A |
| Digits | 1 16, 2 1E, 3 26, 4 25, 5 2E, 6 36, 7 3D, 8 3E, 9 46, 0 45 |
| Navigation (E0) | Home EC, End E9, PgUp FD, PgDn FA, Up F5, Down F2, Left EB, Right F4, Insert F0, Delete F1 |
| Mouse (H-Mod/Ultimarc pseudo-codes) | Left click D0, Middle click D1, Right click D3, Double click E8, Left toggle D6, Middle toggle D7 |
| Editing | Return 5A, keypad Enter DA, Esc 76, Backspace 66, Caps 58, Tab 0D, Print Screen 7F, Space 29 |
| Punctuation | `-` 4E, `=` 55, `[` 54, `]` 5B, `\` 5D, `;` 4C, `'` 52, `` ` `` 0E, `,` 41, `.` 49, `/` 4A |
| Modifiers | Command (E0 1F) 9F, L-Shift 12, L-Ctrl 14, L-Option 11, R-Shift 59, R-Ctrl (E0 14) 94, R-Option (E0 11) 91 |
| Modifier toggles | Shift toggle DE, Ctrl toggle DC, Option toggle DF |
| Function keys | F1 05, F2 06, F3 04, F4 0C, F5 03, F6 0B, F7 83, F8 0A, F9 01, F10 09, F11 78, F12 07 |
| Keypad | `/` CA, `*` 7C, `-` 7B, `+` 79, `=` 0F, 1 69, 2 72, 3 7A, 4 6B, 5 73, 6 74, 7 6C, 8 75, 9 7D, 0 70, `.` 71 |
| Macros | Macro 1–4 E0, E1, E2, E3 |
| Shift | H-Mod Shift Toggle E7 |
| Special | `<none>` FF |

Notes and caveats on the table:
- **Ambiguity [?]:** F7 is `0x83`, a genuine set-2 code above 0x7F, which collides with the "0x80|code" extended-key scheme: `0x83` could also mean E0 03. The firmware must treat it as F7, but this needs confirming.
- `Print Screen = 0x7F` is not the standard set-2 sequence (E0 12 E0 7C). It is reproduced here as the app has it.
- This table is the complete set the UI can produce. Other codes the firmware may accept (e.g. F13, given the 0x68 logical max in the HID descriptor) are unknown [?].
- **Shift switch [V]:**
  - `-[SSSwitch setNormalCode:]` forces the shifted code to E7 whenever the normal code is E7.
  - `setShiftedCode:` clears E7 consistently in the same way.
  - The shift switch is chosen from a menu (`setShiftSwitchNumber:`), which sets `shift = true` on exactly one switch.
- **Macros [V layout, I semantics]:**
  - Each macro is 4 code bytes; unused slots are `0xFF`.
  - A switch whose code is E0–E3 plays macro 1–4.
  - Whether the firmware sends the codes as a sequence or as a chord is [?].

### 3.3 Worked examples (offline, from `ssw_proto.py encode`)

`Default.ssconfig` on this Mac has switch 1 = Print Screen and everything else `<none>`. Byte 57 is the checksum (`75`):
```
ff 00 00 ff 00 ff 00 00 7f 00 ff 00 ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ff
00 ff 00 00 ff 00 ff 00 ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 75 00 ff ff ff ff ff
ff ff ff ff ff ff ff ff ff ff ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

`LRDSE.ssconfig` has switches 1–5 = Left click, Right click, Double click, Space, Return. Its checksum is `08`:
```
ff 00 00 5a 00 29 00 00 d0 00 d3 00 e8 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ff
00 ff 00 00 ff 00 ff 00 ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 08 00 ff ff ff ff ff
ff ff ff ff ff ff ff ff ff ff ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

These are predictions [I] until a capture matches them byte for byte.

---

## 4. `.ssconfig` file format [V]

The format is an XML plist:

```
identifier : UUID string
type       : 0 = 5-switch product, 1 = 10-switch product
switches   : { "1".."28" : { normalCode: int, shiftedCode: int, shift: 0|1 } }
macros     : { "1".."4"  : { firstCode, secondCode, thirdCode, fourthCode : int } }
```

- All codes are the bytes from 3.2.
- Only switches 1..5 (type 0) or 1..10 (type 1) are used when building the image.
- User configurations live in `~/Library/Application Support/StealthSwitch/Configurations/`.

---

## 5. Comparison with published Ultimarc protocols

- **VID 0x1324** is not in usb.ids under any vendor, and Ultimarc-linux's udev rules don't list it. Ultimarc's own IDs are `0xD208` (Mini-PAC 0x0310) and `0xD209` (I-PAC, Ultra-Stik, etc.).
- **Ultimarc-linux** (github.com/katie-snow/Ultimarc-linux) programs every supported board with **HID class SET_REPORT**, never vendor requests:
  - `libusb_control_transfer(h, 0x21, 9, 0x0203, iface, msg, 5, 2000)`
  - each message is a 5-byte feature report `{0x03, d0..d3}`
  - a 260-byte image for I-PAC-series boards, in both the "pre-2015" and "2015" paths
  - It contains no `0x43`/`0xC3` vendor request and no 0xE9/0xEA/0xEB requests. Those values appear only as key-table constants.
- **What matches:** the key encoding. Ultimarc-linux's `ipacseries.h` says "The IPAC uses scan codes set 2", the same family as section 3.2.
- **What doesn't match:** the transport (vendor requests on EP0 with a start/32-byte block/status/end handshake), the 96-byte image with a sum checksum at byte 57, and the 28-input layout. None of these appear in any public Ultimarc source found.
- **Ultimarc docs and SDK:** WinIPAC protocol notes and the PacDrive SDK were not retrieved. MAME/BYOAC forum threads were not checked.
- **H-Mod:** its public pages (manualslib, ergocanada) give no protocol details.

**Conclusion** [I]:
- The device is a custom or OEM build of an older Ultimarc button-encoder firmware, with its own unregistered VID and its own download protocol.
- **The disassembly is the only authoritative source for the transport.**
- Ultimarc-linux is useful only as a cross-check for scan-code semantics.

---

## 6. Live capture: procedure and what it must confirm

### 6.1 Tools

The tools are in `tools/stealthswitch3/` (run `./build.sh` there first; it builds the x86_64 tracer dylib).

| File | Purpose |
|---|---|
| `ssw_usbtrace.c`, `ssw_tramp.s` → `ssw_usbtrace.dylib` (x86_64) | Passive tracer (details below). |
| `ssw_readonly_test.c` → `ssw_readonly_test` (x86_64) | Read-only exerciser. It does what the app does up to QueryInterface, then only cached getters, two standard GET_DESCRIPTORs and an interface enumeration. No open, no vendor or class request. |
| `capture.sh` | Launcher. |
| `ssw_proto.py` | Offline model. `encode <ssconfig>` predicts the image and request sequence; `decode-log <log>` reassembles and decodes captured downloads and checks the checksum. Sends nothing to any device. |
| `build.sh` | Rebuilds both binaries. |

What `ssw_usbtrace.dylib` does:
- It interposes `IOCreatePlugInInterfaceForService` and swaps the plug-in **instance's** vtable pointer to a private heap copy with QueryInterface wrapped. The shared vtable in IOUSBLib is never written.
- When QueryInterface returns any `IOUSBDeviceInterface*` or `IOUSBInterfaceInterface*` version, the tracer installs a private copy sized for that version, using `sizeof` from the SDK.
- Fully decoded wrappers cover open, seize and close; the `DeviceRequest` family (including async, with callback wrapping); `ControlRequest*`; the pipe read and write calls; and the descriptor getters. These log the setup packet, OUT data, IN data, `wLenDone` and the IOReturn.
- Every other slot goes through an asm trampoline that logs the method name and raw argument registers, then tail-jumps to the original.
- It also logs `IOServiceMatching`/`GetMatchingService(s)`/`AddMatchingNotification`/`IOServiceOpen` and the `IOConnectCall*Method` user-client calls underneath. `DeviceRequest` appears there as `IOConnectCallScalarMethod selector=7` with scalars `[?, bm, bReq, wValue, wIndex, wLength, pData, timeout]`.
- It writes timestamped lines (wall clock plus a monotonic offset, thread id and sequence number) to `$SSW_LOG`.

**Test result [V]:** `ssw_readonly_test` ran under Rosetta (`rosetta_translated=1`) with the dylib injected.
- Every call was logged: plug-in creation, QI to `kIOUSBDeviceInterfaceID182`, the getters, both GET_DESCRIPTORs with their IN data, the interface iterator and both interface plug-ins.
- Logging also covered the IOConnect layer below, so IOUSBLib's own calls are interposable too.
- Output was identical with and without the dylib.

DYLD_INSERT_LIBRARIES works for this app:
- Rosetta honours DYLD_INSERT_LIBRARIES for x86_64 processes, as the test above shows.
- The app has no hardened runtime (CodeDirectory flags 0x0), no entitlements, no `__RESTRICT` segment and no setuid bit.
- `capture.sh` execs the Mach-O directly rather than via `open`, which would drop `DYLD_*`.
- If the banner line is missing from the log, `capture.sh` exits with status 2.

**Fallback if injection is ever blocked:** run under lldb, which works with Rosetta (`lldb -- /Applications/StealthSwitch3.app/Contents/MacOS/StealthSwitch3`).
- Set `br s -a 0x100005c99`, `0x100005d1c`, `0x100005ba4` and `0x100005da6`. Add the ASLR slide, or use `br s -n IOConnectCallScalarMethod` instead.
- At each stop, dump `x/32xb $rsi` (the `IOUSBDevRequestTO`) and `x/32xb *(void**)($rsi+8)` (the data).
- Alternatively, break on `IOConnectCallScalarMethod` and print `$rdi`, `$esi` and `x/8gx $rdx`.

### 6.2 Procedure

Programming always writes the configuration permanently, so every step below overwrites what the switch is doing. Restore your real configuration at the end.

1. Quit StealthSwitch3 completely. Also quit the RoboCon menu-bar helper if it is running; it is not traced.
2. `cd <ssw dir>`. If anything was moved, run `./build.sh`, then `./capture.sh`.
3. In the app, for each configuration below:
   1. Create it with *New Configuration*, product = the one you own.
   2. Set the switches.
   3. Press *Program*.
   4. Wait for the "Hero" sound.
   5. Physically test the switches, for example with Karabiner-EventViewer or a text editor, and note what each jack produces.
4. Quit the app with Cmd-Q, then run `python3 ssw_proto.py decode-log <log>`.
5. For each configuration you saved, compare the decoded image with `python3 ssw_proto.py encode ~/Library/Application\ Support/StealthSwitch/Configurations/<name>.ssconfig`. The two must be byte-identical.

Program these configurations in this order:

| # | Configuration | Disambiguates |
|---|---|---|
| A | Reprogram the existing **Default** unchanged | Baseline. Confirms the request sequence, timeouts, status bytes and USBDeviceOpenSeize result. Compares with the prediction in 3.3. |
| B | **Pos**: sw1=A, sw2=B, sw3=C, sw4=D, sw5=E, no shifted codes, no shift switch | The switch → input map (expected bytes 8, 10, 12, 5, 3) and which physical jack is "switch 1". |
| C | **Shift**: as B, plus shift switch = 5; shifted codes sw1=1, sw2=2, sw3=3, sw4=4 | Byte 0 (expected 3), the +28 offset of the shift table, what the shift switch's own slots contain (E7?), and how the firmware behaves while shift is held. |
| D | **Ext**: sw1=Up Arrow, sw2=Right Control, sw3=Command, sw4=F7, sw5=Keypad Enter | The E0 → 0x80\|code encoding (F5, 94, 9F, DA) and the F7 0x83 ambiguity. Check on the host that each key arrives correctly. |
| E | **Mouse**: sw1=Left click, sw2=Right click, sw3=Double click, sw4=Left Mouse Toggle, sw5=Middle click | The mouse pseudo-codes on interface 1. |
| F | **Macro**: Macro 1 = L-Control, C, `<none>`, `<none>`; Macro 2 = H, I, `<none>`, `<none>`; sw1=Key Macro 1, sw2=Key Macro 2 | Macro byte layout (59–66) and whether a macro is a chord or a sequence. Byte 57 is computed without the macro bytes; a status 0x01 here confirms the checksum range. |
| G | Reprogram your real configuration | Restore. |

To check the checksum independently without risking a bad write, look at the status byte after each block in the capture. Do not hand-craft bad images.

### 6.3 Still to be confirmed by capture

- [?] `USBDeviceOpenSeize` succeeds on macOS 26 while the HID drivers own both interfaces, or the app fails with "could not open usb device". Note that standard requests worked **without** any open in the read-only test [V]; whether the vendor requests also need an open is [?].
- [?] Status values in practice: 0x01 per block expected. Is the status after block 1 already checksum-related, or only after block 3?
- [?] Physical jack ↔ firmware input mapping, and whether the device reports itself as 5- or 10-switch.
- [?] Firmware semantics of F7 (0x83), Print Screen (0x7F), the toggles, and macros as chord or sequence.
- [?] What `control mode = 0x04` does. The shipped apps never send it. It may be worth one deliberate test later, *after* a known-good permanent configuration is stored.
- [?] Whether the device needs a replug or re-enumerates after "end download". Watch the log for terminate/first-match notifications, which the app also registers for.

### 6.4 Capture results (2026-10-10, macOS 26, Apple silicon via Rosetta) [V]

Three downloads were captured: the Print Screen config, then sw1–5 = A–E, then Print Screen again.

- **Request sequence:** byte for byte as in section 2: start (`0xE9` wValue 1), then 3 × (`0xEB` 32 bytes, `0xEA` status), then end (`0xE9` wValue 0).
- **Status byte:** `0x01` after every block, including blocks 1 and 2.
- **`USBDeviceOpenSeize`:** succeeds as a normal user on macOS 26, even with the HID drivers attached. No root is needed.
- **Image layout:**
  - matches section 3, including checksum byte 57 (`0x75` for Print Screen, `0xB0` for A–E);
  - control mode 0;
  - macros unset (`0xFF`);
  - bytes 75–95 zero.
- **Codes:** Print Screen is `0x7F`. A–E are set-2 codes `1C 32 21 23 24` at inputs 8, 10, 12, 5 and 3 (switches 1–5 in the app's numbering).

Print Screen config image:
```
ff 00 00 ff 00 ff 00 00 7f 00 ff 00 ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ff
00 ff 00 00 ff 00 ff 00 ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 75 00 ff ff ff ff ff
ff ff ff ff ff ff ff ff ff ff ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Still open: the physical jack labels versus app switch numbers, F7/toggle/macro semantics, and control mode `0x04`.

---

## 7. Reimplementation sketch (after confirmation)

A native arm64 replacement needs only:
- IOKit's `IOUSBDeviceInterface` (or libusb), matching 0x1324:0x0103.
- An optional `USBDeviceOpenSeize`.
- The 8 control transfers in 2.2, carrying the image from section 3. 

Timeouts can be looser than the app's 50/100 ms. No HID or kernel driver work is required, and no device state needs to be read first because the protocol is write-only.
