# PhotoBooth

A native macOS photo booth. A Sony ZV-E10 shows a mirrored live preview on a TV; a guest presses a big
button, gets a 3-2-1 countdown, the camera fires (with strobes), and the photo is shown for a few seconds.
Every photo is saved locally first and, optionally, uploaded to a shared Google Photos album.
Design notes and rationale are in `SPEC.md`.

## Hardware

- Sony ZV-E10 with SEL1855 kit lens (~24-28 mm used)
- NP-FW50 dummy battery (AC power; no battery swaps mid-event)
- USB-C cable camera to Mac (control only; live view and photos come over USB)
- Strobes fired by a radio trigger on the camera hot shoe
- TV on HDMI as an external display
- Ultimarc StealthSwitch 3 with a big arcade button on **port 1** (USB VID `0x1324` / PID `0x0103`;
  presents as keyboard + mouse)

## Camera settings (set on the camera)

| Setting | Value |
|---|---|
| Mode / exposure | M, 1/160 s, f/8, ISO 100 |
| File format | JPEG only (L, Fine or Extra Fine) |
| Drive mode | Single |
| Focus mode | **AF-S** (not AF-C: in the spike the camera in continuous AF reported "tracking focused") |
| Priority Set in AF-S | **Balanced Emphasis** (or Release). With the default "AF", a full press without focus lock is ignored, so a low-contrast scene means no photo and an "Oops" screen |
| Silent shooting / electronic shutter | **OFF** (otherwise strobes won't fire) |
| Flash mode | Fill-flash |
| Live View Display | Setting Effect **OFF** — must be set on the camera: the ZV-E10 accepts the USB command but ignores it. With it on, the preview is near-black at strobe exposure |
| USB Connection | **PC Remote** |
| PC Remote save destination | PC only (or PC + Camera) |
| **Power Save / Auto Power Off** | **DISABLED** |

**Disable Power Save.** During development the camera powered itself off after a few idle minutes. The app
can only wait for it to come back (it reconnects automatically once the camera is switched on again).

USB identification: the ZV-E10 in PC Remote mode has USB product ID `0x0d97`. Check with
`system_profiler SPUSBHostDataType`. When the camera is off or not in PC Remote mode it shows up as
"USB Charger".

## Build and install

```sh
swift build            # debug build
swift test             # unit tests
scripts/bundle.sh      # release build -> dist/PhotoBooth.app (signed)
```

### Signing

`scripts/bundle.sh` signs with the first **Developer ID Application** identity in your keychain
(hardened runtime + secure timestamp), falling back to ad-hoc if there is none. Override with `SIGN_IDENTITY`
(`SIGN_IDENTITY=-` forces ad-hoc).

Why this matters: macOS ties privacy grants (Input Monitoring, Removable Volumes) and Keychain access to the
app's code signature. An ad-hoc signature changes on every build, so each rebuild can re-trigger the permission
prompts and a Keychain "wants to use confidential information" dialog. On an unattended booth that dialog
blocks everything. With a stable identity the grants survive rebuilds.

No Developer ID? A self-signed certificate works for local use: Keychain Access -> Certificate Assistant ->
**Create a Certificate...**, Identity Type Self Signed Root, Certificate Type **Code Signing**; pass its name as
`SIGN_IDENTITY`.

Notarization is only needed to run the app on a different Mac (e.g. after downloading it). One-time setup, then
build with `NOTARY_PROFILE`:

```sh
xcrun notarytool store-credentials photobooth --apple-id <apple-id> --team-id <team-id>
NOTARY_PROFILE=photobooth scripts/bundle.sh
```

## macOS permissions (one-time, per app identity)

| Permission | Where | Why / symptom if missing |
|---|---|---|
| Removable Volumes | System Settings -> Privacy & Security -> Files & Folders -> PhotoBooth -> Removable Volumes | Required for ImageCaptureCore's `ptpcamerad` to hand the camera to the app. Missing: the booth stays on "Getting the camera ready..." and the log says "camera visible but not delivered". |
| Input Monitoring | System Settings -> Privacy & Security -> Input Monitoring | Lets HID button mode work even when the app isn't focused. If denied, the app falls back to focused-window keyboard input and shows a banner. |
| Keychain | prompt on first Google sign-in | Stores the Google refresh token. |

Tip: do the first launch with `--windowed` so the prompts aren't hidden behind the full-screen kiosk window,
then quit and launch normally:

```sh
dist/PhotoBooth.app/Contents/MacOS/PhotoBooth --windowed
```

## Configure

Config lives at `~/PhotoBooth/config.json` and is created with defaults on first run (override with
`--config PATH`). Missing keys use defaults; unknown keys are ignored; bad values show on the attendant screen
(never a crash). Defaults:

```json
{
  "albumName" : "Photo Booth",
  "buttonDevice" : {
    "productID" : "0x0103",
    "vendorID" : "0x1324"
  },
  "buttonInput" : "hid",
  "buttonKey" : "a",
  "countdownSeconds" : 3,
  "debounceMs" : 400,
  "display" : "auto",
  "eventName" : "PhotoBooth",
  "idlePrompt" : "Press the button!",
  "mirrorPreview" : true,
  "outputRoot" : "~/PhotoBooth",
  "pauseBetweenShotsSeconds" : 2,
  "reviewSeconds" : 5,
  "shotsPerPress" : 1
}
```

| Key | Meaning |
|---|---|
| `eventName` | Names the event folder `<outputRoot>/<eventName>/` for photos |
| `buttonKey` | Key the button sends (see below) |
| `buttonInput` | `hid` (IOHIDManager; works unfocused, needs Input Monitoring) or `local` (focused-window key events) |
| `buttonDevice` | `{vendorID, productID}` (number or `"0x..."` string): in `hid` mode only presses from this device count. `null` = any keyboard |
| `debounceMs` | Ignore repeat presses within this time (0-5000) |
| `countdownSeconds` | 0-10 |
| `reviewSeconds` | How long the photo is shown (1-60) |
| `shotsPerPress` | Photos per press (1-10); `pauseBetweenShotsSeconds` (0-30) between them |
| `outputRoot` | Root folder for photos, logs, `google_client.json`, upload state |
| `albumName` | Google Photos album title |
| `display` | `"auto"` (external display if present, else main), `"main"`, an integer index, or a case-insensitive part of the display name (e.g. `"LG"`) |
| `mirrorPreview` | Mirror the live preview (the review photo is never mirrored) |
| `idlePrompt` | Text on the idle screen |

**Button key names:** `a`-`z`, `0`-`9`, `space`, `return`, `enter`, `tab`, `escape`, `delete`, arrows, `home`,
`end`, `pageup`, `pagedown`, `f1`-`f24`, `kp0`-`kp9`, punctuation, or a raw HID usage like `hid:0x2c`
(raw usages without a known key work in `hid` mode only).

**Finding what the StealthSwitch sends:** run `PhotoBooth --windowed --learn-key`, press the button on port 1,
and the window shows the HID usage, macOS key code, source device, and the exact `buttonKey` value to put in
config.json. Quit with Cmd+Q.

**Reload live:** Ctrl+Opt+Cmd+R reloads config.json without restarting.

## Google Photos upload (optional)

Without `google_client.json` the booth just saves locally.

1. Create a project in Google Cloud Console and enable the **Photos Library API**.
2. OAuth consent screen: user type **External**, then **Publish to In production**. In "Testing" status
   refresh tokens expire after 7 days and uploads silently stop.
3. Create an OAuth client ID of type **Desktop app**. Download its JSON and save it as
   `~/PhotoBooth/google_client.json` (that is `<outputRoot>/google_client.json`).
4. Sign in once:
   ```sh
   dist/PhotoBooth.app/Contents/MacOS/PhotoBooth --google-login
   ```
   Approve in the browser. Expect "Google hasn't verified this app": Advanced -> continue.
5. The app creates the album (title = `albumName`). **Share it manually in Google Photos**; the API can't.

How uploads behave:
- Photos are always saved locally first: `~/PhotoBooth/<event>/YYYYMMDD-HHMMSS.jpg` is the source of truth.
- Uploads go through a persistent queue: retried with backoff, paused while offline, resumed on restart.
  State is in `~/PhotoBooth/.upload/`.
- If you aren't signed in yet, photos queue and upload once you are.

Open question: the app requests only the `photoslibrary.appendonly` scope (`photosAppendOnlyScope` in
`Sources/Uploader/GoogleAuth.swift`). If uploads fail with a 403 mentioning scopes, the app may also need
`photoslibrary.edit.appcreateddata`. **Test end to end before the event.**

Fallback (per SPEC): in Google Photos on the web, use "Back up folders" on the event folder.

## Running the booth

Launch `dist/PhotoBooth.app` (or `open dist/PhotoBooth.app`). It goes full-screen on the selected display,
hides the cursor, and prevents display sleep while running.

| Screen | Meaning |
|---|---|
| "Getting the camera ready..." | Waiting for the camera (off, wrong USB mode, or permission missing). It reconnects by itself. |
| Idle: live preview + prompt | Ready; press the button. |
| 3-2-1 countdown | Presses are ignored. |
| White flash | The shutter fired. |
| Review ("Saved!") | The photo, not mirrored, for `reviewSeconds`; then back to idle. |
| "Oops - let's try that again" | A capture failed; returns to idle after a moment. |
| **ATTENDANT NEEDED** | Repeated failures or a config / storage / permission problem. Fix it, then press Ctrl+Opt+Cmd+R. |

Attendant keys: **Ctrl+Opt+Cmd+Q** quit, **Ctrl+Opt+Cmd+R** retry / reload config. Cmd+Q also quits.
Esc does nothing. (Ctrl+Opt+Cmd+D simulates a camera disconnect, fake camera only.)

Logs: `~/PhotoBooth/logs/booth-YYYYMMDD.log`, and live with
`log stream --predicate 'subsystem == "PhotoBooth"'`.

## Pre-event checklist

- [ ] Camera settings as above; **Power Save off**; dummy battery in; camera on, USB set to PC Remote
- [ ] Strobes on, and a test shot fires them (look at the lights, or check EXIF flash)
- [ ] Button learned (`--learn-key`) and `buttonKey` set; `eventName` / `albumName` set
- [ ] Permissions granted (Removable Volumes, Input Monitoring, Keychain) for the exact signed app you will run
- [ ] Google signed in, and a test photo appears in the shared album
- [ ] TV placement and `display` setting verified
- [ ] Free disk space on the Mac

## Development

Modules:

- `PTPKit`: pure PTP/Sony protocol code, no ImageCaptureCore (fully unit-tested)
- `SonyCamera`: ImageCaptureCore transport, Sony session, `BoothCamera` implementation
- `Uploader`: Google OAuth + Photos Library client, persistent upload queue
- `BoothCore`: booth logic with no AppKit/SwiftUI: state machine, config, key map, fake camera, scenarios
- `PhotoBooth`: the SwiftUI/AppKit app (views, HID input, app delegate, upload wiring)
- `BoothSpike`: hardware spike / soak CLI (`booth-spike`)

`PhotoBooth` flags: `--windowed`, `--fake-camera`, `--fake-fail-rate X`, `--config PATH`, `--learn-key`,
`--google-login`, `--self-test` (runs the 12 state-machine scenarios), `--auto-press SECONDS`,
`--print-window-id`, `--snapshot-dir DIR`. Develop without hardware:

```sh
swift run PhotoBooth --windowed --fake-camera
```

Hardware spike (touches the real camera):

```sh
swift run booth-spike [--frames N] [--no-capture] [--quiet-liveview] [--out DIR]
swift run booth-spike --soak SECONDS [--soak-fault] [--trace]
```

How it talks to the camera:

- ImageCaptureCore PTP pass-through: no USB claiming, no fighting `ptpcamerad`, no sudo.
- Sony SDIO handshake: `0x9201` / `0x9202(0x12C, 1)` / `0x9201`, plus PriorityMode.
- Live view: GetObject `0xFFFFC002`, gated on LiveViewStatus `0xD221 == 1` (about 30 fps, 1024x576).
- Capture: half-press `0xD2C1`, wait for FocusFound `0xD213` in {2, 3, 6, 7}, full press `0xD2C2` held until
  ObjectAdded / `0xD215 >= 0x8000`, release, then GetObject `0xFFFFC001`.
- Codes were verified against libgphoto2 `camlibs/ptp2`.
