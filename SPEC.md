# Photo Booth App — Project Brief

## Goal
A simple, reliable macOS photo booth app. Live preview from the camera fills a TV. A guest presses a big USB button, a 3‑2‑1 countdown plays over the live preview, the camera captures a full‑resolution still with studio strobes, the photo is shown briefly, saved locally, and uploaded to a Google Photos album. Attendant-chosen photo strips can be printed on a Canon SELPHY (see README, Printing). Nothing else: no video, boomerangs, filters, or editing.

This replaces LumaBooth (formerly dslrBooth), which works with this camera but is bloated.

## Hardware (all on hand)
- **Camera:** Sony ZV-E10 (original, not Mark II), Sony E 18-55mm f/3.5-5.6 (SEL1855) set around 24–28mm.
- **Power:** NP-FW50 dummy battery on wall power. USB-C to the Mac is for control only.
- **Strobes:** studio strobes fired by a radio trigger on the camera's Multi Interface hot shoe. Mechanical shutter, sync up to 1/160.
- **Display:** TV on the Mac's HDMI, used as an external display, mounted on a stand with the camera above the screen.
- **Button:** large USB button that enumerates as an HID keyboard and sends one key. Identify which key; make it configurable.
- **Host:** a Mac.

## Key technical decision: ImageCaptureCore PTP pass-through (not gphoto2)
On modern macOS, `ptpcamerad` grabs any PTP camera's USB interface and respawns within milliseconds if killed. `launchctl` can't disable it because of SIP. libgphoto2 therefore has to race it for the claim.

LumaBooth avoids this. It's built on CascableCore, which on Apple platforms sends commands through Apple's ImageCaptureCore rather than claiming USB directly.

We do the same:
- Find the camera with `ICDeviceBrowser`, then `requestOpenSession`.
- Send raw PTP commands, including Sony vendor opcodes, with `ICCameraDevice.requestSendPTPCommand(_:outData:completion:)`.
- Receive PTP events through the camera's PTP event handler / `cameraDevice(_:didReceivePTPEvent:)`.
- On macOS, PTP commands can be sent once the session opens; iPadOS has to wait for `deviceDidBecomeReady`.
- Work out empirically the exact command-buffer format `requestSendPTPCommand` expects (most likely a full PTP command container: length, type=1, code, transaction ID, params). Reference implementation: github.com/twarge/profiler (`PTPTransport`, `SonyPTP`).
- No sudo and no killing system daemons.

## Sony PTP subset needed
Take these from libgphoto2 `camlibs/ptp2` (`ptp.h`, `library.c`, `config.c`). **Verify every value against that source before relying on it.**

- **Connect handshake** (switches the camera into PC Remote control):
  - `SDIOConnect` 0x9201 with params (1,0,0), then (2,0,0)
  - `GetSDIOGetExtDeviceInfo` 0x9202 with the protocol version (e.g. 0xC8 / 0x12C; check what libgphoto2 sends)
  - `SDIOConnect` 0x9201 with (3,0,0)
- **Read and set properties:** `GetAllDevicePropData` 0x9209, `SetControlDeviceA` 0x9205 (property values), `SetControlDeviceB` 0x9207 (button-style controls).
- **Shutter:**
  - Half-press: `SetControlDeviceB` on 0xD2C1 = 2
  - Full press: `SetControlDeviceB` on 0xD2C2 = 2, then release 0xD2C2 = 1, then 0xD2C1 = 1
- **Live view:** `GetObject` on the special handle 0xFFFFC002. It returns a JPEG frame inside a Sony header; parse the offset and size per libgphoto2, or as a fallback scan for the JPEG start/end markers FFD8 / FFD9.
- **Captured image:** wait for the object-added event (Sony 0xC201), then `GetObjectInfo` / `GetObject` on 0xFFFFC001.
- **Nice to have:** set Live View Display "Setting Effect" OFF from code (libgphoto2 exposes `liveviewsettingeffect`).

## Camera settings (set manually on the camera; document them in the README)
- **Exposure:** M mode, 1/160 s, f/8, ISO 100.
- **File and drive:** JPEG only (L, Fine or Extra Fine), drive mode single, focus AF-S.
- **Flash:** Silent shooting / electronic shutter OFF (otherwise strobes won't fire). Flash mode: Fill-flash.
- **Live view:** Live View Display → Setting Effect OFF, so the preview isn't dark at strobe exposure.
- **Remote:** USB Connection → PC Remote. PC Remote save destination: PC only (or PC + Camera).
- **Power:** power-save / auto power off disabled.
- **Focus note:** autofocus lenses lose their manual-focus position on power cycle, so use AF-S. The half-press before capture handles focus.

## App behaviour
- **Single native SwiftUI app** (no web server needed), full-screen on the external display, cursor hidden, sleep prevented with an `IOPMAssertion`.
- **States:**
  1. **Idle:** mirrored live preview with a "Press the button" prompt.
  2. **Countdown:** 3‑2‑1 overlay on the live preview.
  3. **Capture:** show a brief full-screen white flash so the guest knows it fired.
  4. **Review:** show the captured photo, not mirrored, for about 5 s.
  5. Return to idle.
- **Button input:** configurable key. Use a local `NSEvent` monitor, or `IOHIDManager` so it works even if the app loses focus. Debounce it, and ignore presses outside Idle.
- **Config file** (JSON or TOML): button key, countdown length, review duration, shots per press (default 1; optionally 3 with a pause between), output folder, album name, display selection.
- **Resilience:**
  - Auto-reconnect if the camera disconnects or powers off.
  - Show an "Attendant needed" screen on errors, never a crash dialog.
  - Keep live view running continuously.
  - Pause live view polling during capture if the camera needs it.

## Storage and upload
- **Save locally first, always:** `~/PhotoBooth/<event-name>/YYYYMMDD-HHMMSS.jpg`. The local file is the source of truth.
- **Upload queue:** persistent (survives restarts), with retries and exponential backoff, uploading to Google Photos.
- **Google Photos Library API:**
  - Scope `https://www.googleapis.com/auth/photoslibrary.appendonly`. After the March 2025 changes, this still allows uploading and creating app-created albums.
  - Flow: upload the bytes (`uploads` endpoint, raw, with MIME type), then `mediaItems.batchCreate` into an album the app creates once with `albums.create` (store the album ID).
  - OAuth: installed-app flow with a loopback redirect. Store the refresh token in Keychain.
  - **Important:** publish the OAuth consent screen to Production (unverified is fine for personal use). In Testing status, refresh tokens expire after 7 days and uploads silently stop.
  - The API can't share albums any more, so the user shares the album manually in the Google Photos UI.
- **Fallback if the API is a problem:** only save to the folder, and use Google Photos web "Back up folders". This only works while a browser tab is open; Drive for desktop's Photos backup ended August 2026.

## Phases (each ends with a runnable deliverable)
0. **Spike: CLI tool, highest risk first.**
   - Discover the ZV-E10, open a session, run the Sony handshake.
   - Save 30 live-view JPEGs and report the frame rate.
   - Fire one capture (strobes should fire) and save the full-resolution JPEG.
   - Print every PTP command and response. Stop and report if any step fails; don't build UI on an unproven camera layer.
1. **Camera module:** async Swift API, e.g. `connect()`, `liveViewFrames() -> AsyncStream<CGImage>`, `capture() async throws -> Data`, connection-state publisher, auto-reconnect.
2. **Booth UI:** the full-screen SwiftUI state machine, button input, countdown, review, external display handling.
3. **Storage and upload:** local save, persistent queue, Google Photos OAuth, album and upload.
4. **Hardening:** logging to file, config, sleep prevention, error screens, and a README covering camera settings and setup.

## Engineering preferences
- Build and run from the CLI (Swift Package Manager / `xcodebuild`); avoid Xcode-only workflows where possible.
- Keep dependencies minimal; Apple frameworks plus Google's REST endpoints over `URLSession` are enough.
- Small, testable modules. Put the PTP container encode/decode behind protocols so it can be unit-tested with captured byte fixtures.
- Note any entitlements or permission prompts ImageCaptureCore needs (sandboxing, camera/USB access), and prefer running unsandboxed for a personal tool.
