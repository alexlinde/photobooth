# PhotoBooth

A native macOS photo booth. A Sony ZV-E10 shows a mirrored live preview on a TV; a guest presses a big
button, gets a 3-2-1 countdown, the camera fires (with strobes), and the photo is shown for a few seconds.
Every photo is saved locally first and, optionally, uploaded to a shared Google Photos album. The attendant
can print photo strips on a Canon SELPHY.
Design notes and rationale are in `SPEC.md`.

## Hardware

- Sony ZV-E10 with SEL1855 kit lens (~24-28 mm used)
- NP-FW50 dummy battery (AC power; no battery swaps mid-event)
- USB-C cable camera to Mac (control only; live view and photos come over USB)
- Strobes fired by a radio trigger on the camera hot shoe
- TV on HDMI as an external display
- H-Mod StealthSwitch 3 with a big arcade button on **port 1** (USB VID `0x1324` / PID `0x0103`;
  presents as keyboard + mouse)

## Camera settings

With the default `"lighting": "strobes"` the app sets exposure mode, shutter, aperture, ISO, flash mode and
compensation, focus mode, white balance and Live View Setting Effect over USB on every (re)connect (see
[Lighting profiles](#lighting-profiles)); the control panel shows anything the camera refused. The table is the
intended state; rows marked *(app)* are set by the profile, the rest must be set on the camera.

| Setting | Value |
|---|---|
| Mode / exposure *(app)* | M, 1/160 s, f/8, ISO 100 |
| File format | JPEG only (L, Fine or Extra Fine) |
| Drive mode | Single |
| Focus mode *(app)* | **AF-S** (not AF-C: in the spike the camera in continuous AF reported "tracking focused") |
| Priority Set in AF-S | **Balanced Emphasis** (or Release). With the default "AF", a full press without focus lock is ignored, so a low-contrast scene means no photo and an "Oops" screen |
| Silent shooting / electronic shutter | **OFF** (otherwise strobes won't fire) |
| Flash mode *(app)* | Fill-flash |
| Live View Display *(app)* | Setting Effect **OFF** (writable over USB in M/A/S/P). With it on, the preview is near-black at strobe exposure |
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
  "buttonKey" : "printscreen",
  "countdownSeconds" : 3,
  "debounceMs" : 400,
  "display" : "auto",
  "eventName" : "PhotoBooth",
  "idlePrompt" : "Press the button!",
  "mirrorPreview" : true,
  "outputRoot" : "~/PhotoBooth",
  "pauseBetweenShotsSeconds" : 2,
  "printCaption" : "",
  "printMedia" : "Postcard.Fullbleed",
  "printTemplate" : "print-strip.png",
  "printer" : "",
  "reviewSeconds" : 5,
  "lighting" : "strobes",
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
| `lighting` | `"strobes"` (default), `"ambient"`, or `"none"` (don't touch the camera's settings). See below |
| `profiles` | Optional per-field overrides of the built-in profiles. Written only when there are overrides |
| `printer` | CUPS queue for photo strips. `""` = the first queue named like a SELPHY (`selphy`, or a model like `CP910`). The print window's picker saves it. See [Printing](#printing) |
| `printMedia` | Paper size passed to `lp -o media=` |
| `printTemplate` | Strip artwork (PNG/JPEG). Relative paths are inside `outputRoot`; `""` = none |
| `printCaption` | Text under the photos when there's no artwork (`\n` for a new line). `""` = `eventName` |

**Button key names:** `a`-`z`, `0`-`9`, `space`, `return`, `enter`, `tab`, `escape`, `delete`, arrows, `home`,
`end`, `pageup`, `pagedown`, `f1`-`f24`, `kp0`-`kp9`, punctuation, or a raw HID usage like `hid:0x2c`
(raw usages without a known key work in `hid` mode only).

**Finding what the StealthSwitch sends:** run `PhotoBooth --windowed --learn-key`, press the button on port 1,
and the window shows the HID usage, macOS key code, source device, and the exact `buttonKey` value to put in
config.json. Quit with Cmd+Q.

**Reload live:** Ctrl+Opt+Cmd+R reloads config.json without restarting (and re-applies the lighting profile).
Most settings can also be edited in the [control panel](#control-panel), which saves config.json for you.

### Lighting profiles

The booth applies a camera profile on every (re)connect, so it doesn't depend on how someone left the camera's
menus. Built-ins:

| Setting | `strobes` | `ambient` |
|---|---|---|
| Exposure mode | manual | aperture priority |
| Shutter | 1/160 | (camera) |
| Aperture | f/8 | f/5.6 |
| ISO | 100 | auto |
| Exposure compensation | (locked in M) | 0 |
| Flash | fill, 0 EV | (camera; the ZV-E10 keeps its flash mode in A) |
| Focus | AF-S | AF-S |
| White balance | auto | auto |
| Live View Setting Effect | off (bright preview) | on (preview shows the real exposure) |

Override individual fields of either profile:

```json
"lighting": "strobes",
"profiles": {
  "strobes": {"shutter": "1/160", "aperture": 8, "iso": 100, "flashCompensation": -0.3},
  "ambient": {"aperture": 4, "iso": "auto"}
}
```

| Key | Values |
|---|---|
| `exposureMode` | `"manual"`, `"aperture"`, `"shutter"`, `"program"` |
| `shutter` | `"1/160"`, `"1/4000"`, `"0.5"`, `"2"`, `"30"` (1/8000 to 30 s) |
| `aperture` | number, e.g. `8` or `5.6` |
| `iso` | number (e.g. `100`) or `"auto"` |
| `exposureCompensation`, `flashCompensation` | EV, e.g. `-0.3` (±5 / ±3). Exposure compensation is ignored in manual |
| `flash` | `"off"`, `"fill"`, `"auto"`, `"slowSync"`, `"rearSync"` |
| `focus` | `"af-s"`, `"af-c"`, `"af-a"`, `"dmf"`, `"mf"` |
| `whiteBalance` | `"auto"`, `"daylight"`, `"shade"`, `"cloudy"`, `"tungsten"`, `"flash"` |
| `settingEffect` | `true` / `false` |

Bad values show on the attendant screen like any other config error. While config.json has an error the booth
runs on defaults but leaves the camera's settings alone until the file is fixed.

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

Albums: since March 2025 the Photos Library API only lets an app add to albums **it created itself**, so the booth
always creates its own album and can't upload into one you made by hand. It remembers every album it has created
(`~/PhotoBooth/.upload/album.json`, title -> album ID), so switching `albumName` back and forth reuses albums instead
of making duplicates. The control panel's Booth section lists them (**Refresh** asks Google; "New album…" starts a
new one). Sharing is still manual, in Google Photos.

How uploads behave:
- Photos are always saved locally first: `~/PhotoBooth/<event>/YYYYMMDD-HHMMSS.jpg` is the source of truth.
- Uploads go through a persistent queue: retried with backoff, paused while offline, resumed on restart.
  State is in `~/PhotoBooth/.upload/`.
- If you aren't signed in yet, photos queue and upload once you are.

Scopes: `photoslibrary.appendonly` is enough to create the album and upload into it (verified end to end
2026-10-10). The app also requests `photoslibrary.readonly.appcreateddata`, which only lets it see albums and photos
**this app created** (never the rest of your library), so it can list its albums and find one made from another Mac
instead of creating a duplicate. It can't share or delete anything. Existing sign-ins only have the first scope and
keep uploading unchanged; click **Sign in again** in the control panel (or run `--google-login`) once to enable listing.

Fallback (per SPEC): in Google Photos on the web, use "Back up folders" on the event folder.

### Running the booth from another Mac

Copy `~/PhotoBooth/google_client.json` to the other Mac's `~/PhotoBooth/` and sign in there. Using the same OAuth
client is what makes the albums "app-created" for both Macs, so each can list and reuse the other's albums.
(A different OAuth client would see none of them.)

## Printing

Photo strips print on a **Canon SELPHY CP910** (dye-sub, 100 x 148 mm postcard paper, about a minute per
sheet). Printing is never automatic: the attendant picks three photos and presses Print.

**Add the printer once:** put the SELPHY on the same Wi-Fi as the Mac, then System Settings -> Printers &
Scanners -> **Add Printer** and pick it (it's found as AirPrint, no driver needed). macOS names the queue
`Canon_CP910`; with `"printer": ""` the booth picks it by itself.

**The print window** (**⌘P**, or **Print…** in the control panel's Recent photos) opens on the attendant's display
like the control panel:

- Left: every photo in the event folder, newest first. Click to pick; the badge 1-3 is the photo's place on the
  strip, top to bottom. Click again to un-pick (the rest renumber). **Last 3** picks the three newest, oldest first
  (one press with `shotsPerPress` 3). **Clear** starts over.
- Right: a preview of the sheet, **Copies** (1-5 sheets), and **Print** (enabled with three photos picked). After
  sending, the selection clears and it says "Sent to printer".
- Printer: the queue picker (saved to config.json), the printer's status, and its job queue with **Cancel** per job.
  Status is checked every 3 s while the window is open. "Out of paper or a sheet didn't feed" means reload the
  paper cassette; the print continues by itself. "Printer not reachable" means it's off or on another network.

Each sheet is rendered to `~/PhotoBooth/<event>/prints/print-YYYYMMDD-HHMMSS.jpg` first, then sent with
`lp -o media=Postcard.Fullbleed -o print-scaling=fill`. The file is what gets printed, so a failed print can be
re-sent from Finder. Prints are not uploaded and don't show up among the photos.

**Layout:** one sheet (100 x 148 mm, portrait) holds two identical strips side by side; cut it down the middle.
Each strip is 50 x 148 mm: three 42 x 28 mm (3:2) photo windows at 4 mm from the left and 4, 35 and 66 mm from
the top, and a caption area from 94 mm to the bottom. Photos are cropped to fill their windows (the sides of the camera's 16:9
frame are trimmed). Sheets are rendered at 12 px/mm (1200 x 1776 px).

**Artwork:** a PNG or JPEG of one strip, 600 x 1776 px (50:148), at `~/PhotoBooth/print-strip.png`
(`printTemplate`). It's drawn under the photos, so the windows can be left blank. Other shapes are stretched to fit,
with a warning in the print window. Without artwork the strips are white with the caption (`printCaption`, else the
event name) centred under the photos. Designing it: [docs/print-template.md](docs/print-template.md), starting from
`templates/print-strip-template.svg` / `.png`.

**Paper tips:**
- Fan the sheets before loading; paper that has sat in the cassette sticks together and doesn't feed.
- The paper cassette holds 18 sheets. A KP-108IN set (ink + paper) is 108 prints; swap the ink cassette when the
  printer asks.
- About a minute per sheet, so a queue builds up quickly. Keep a spare pack nearby.

## Running the booth

Launch `dist/PhotoBooth.app` (or `open dist/PhotoBooth.app`). It goes full-screen on the selected display,
hides the cursor, and prevents display sleep while running.

### Two screens: TV for guests, laptop for the attendant

1. Connect the TV and set **System Settings -> Displays** to **Extend** (not Mirror). Mirroring gives one
   display, and the booth runs single-screen.
2. The booth goes on the display `display` picks (`"auto"` = the external one), at kiosk level, without taking
   keyboard focus. The control panel opens on the other display, preferably the laptop's own.
3. The laptop stays usable: Dock and menu bar stay, and the cursor is hidden only while it's over the TV.
   (macOS only hides it while PhotoBooth is the active app.)

Plugging the TV in or out mid-event re-arranges the windows by itself. Lid closed with only the TV attached, the
booth runs single-screen.

**Single screen** (one display, or mirroring): the booth is a full kiosk exactly as before. **⌘,** opens the
control panel on top; while it's open the booth drops below other windows and the cursor shows. Close the panel
to go back to kiosk mode.

### Control panel

Open with **⌘,**, or by clicking PhotoBooth's Dock icon. Closing it doesn't quit (Cmd+Q does).

- **Status:** booth state, camera connection, lighting profile (applying, applied, or which settings the camera
  refused and why), what the camera reports (mode, shutter, aperture, ISO, flash, focus, battery), button
  (connected, HID or focused-window fallback, seized or not), uploads (done / pending / failed, offline, last
  error), Google Photos sign-in (**Sign in…** runs the same browser flow as `--google-login`, then retries the
  queue). An attendant issue shows here with a **Reset** button.
- **Lighting:** Strobes / Ambient / Don't change camera, with a disclosure to edit the selected profile's fields
  (choosing the built-in value removes the override).
- **Booth:** event name, album, countdown, review time, photos per press, idle prompt, mirror preview.
- **Apply & Save** (⌘S) validates, writes config.json and applies it the same way as Ctrl+Opt+Cmd+R.
  **Revert** discards edits. **Test shot** presses the button. **Pause booth** shows "Back in a moment" on the
  TV and ignores presses (a countdown is aborted; a photo already being taken is saved); **Resume** returns.
- **Recent photos:** the last 8; click one to open it; **Print…** opens the [print window](#printing);
  **Show folder** reveals the event folder in Finder.

### Button key: Print Screen

The StealthSwitch is a USB keyboard, so its key also reaches whatever app has focus, and the app can't take
it exclusively (macOS only lets root seize a keyboard). So port 1 is programmed to **Print Screen** (in H-Mod's
StealthSwitch3 app), which macOS sees as F13: it types nothing and triggers nothing. That's the default
`"buttonKey": "printscreen"`. Avoid Scroll Lock and Pause (macOS treats them as F14/F15, screen brightness)
and Insert (Help). A fresh switch ships sending "a"; until it's reprogrammed, set `"buttonKey": "a"` and
don't leave a text field focused. See `docs/stealthswitch3-protocol.md` for programming it without H-Mod's app.

| Screen | Meaning |
|---|---|
| "Getting the camera ready..." | Waiting for the camera (off, wrong USB mode, or permission missing). It reconnects by itself. |
| Idle: live preview + prompt | Ready; press the button. |
| 3-2-1 countdown | Presses are ignored. |
| White flash | The shutter fired. |
| Review ("Saved!") | The photo, not mirrored, for `reviewSeconds`; then back to idle. |
| "Oops - let's try that again" | A capture failed; returns to idle after a moment. |
| **ATTENDANT NEEDED** | Repeated failures or a config / storage / permission problem. Fix it, then press Ctrl+Opt+Cmd+R (or Reset in the control panel). |
| "Back in a moment" | Paused from the control panel; presses are ignored. |

Attendant keys: **Ctrl+Opt+Cmd+Q** quit, **Ctrl+Opt+Cmd+R** retry / reload config, **⌘,** control panel,
**⌘P** print window.
Cmd+Q also quits.
Esc does nothing. (Ctrl+Opt+Cmd+D simulates a camera disconnect, fake camera only.)

Logs: `~/PhotoBooth/logs/booth-YYYYMMDD.log`, and live with
`log stream --predicate 'subsystem == "PhotoBooth"'`.

## Pre-event checklist

- [ ] Camera settings as above; **Power Save off**; dummy battery in; camera on, USB set to PC Remote
- [ ] Strobes on, and a test shot fires them (look at the lights, or check EXIF flash)
- [ ] Button learned (`--learn-key`) and `buttonKey` set; `eventName` / `albumName` set
- [ ] Permissions granted (Removable Volumes, Input Monitoring, Keychain) for the exact signed app you will run
- [ ] Google signed in, and a test photo appears in the shared album
- [ ] TV placement and `display` setting verified; Displays set to Extend; control panel on the laptop
- [ ] Control panel shows the lighting profile applied (no refused settings) and the button connected
- [ ] Printer on and found (print window status "Ready"), paper and ink loaded, and one test print with the
      event's artwork looks right
- [ ] Free disk space on the Mac

## Development

Modules:

- `PTPKit`: pure PTP/Sony protocol code, no ImageCaptureCore (fully unit-tested)
- `SonyCamera`: ImageCaptureCore transport, Sony session, `BoothCamera` implementation
- `Uploader`: Google OAuth + Photos Library client, persistent upload queue
- `BoothCore`: booth logic with no AppKit/SwiftUI: state machine, config, key map, fake camera, scenarios, print
  sheet layout and renderer, CUPS output parsing
- `PhotoBooth`: the SwiftUI/AppKit app (views, HID input, app delegate, upload wiring)
- `BoothSpike`: hardware spike / soak CLI (`booth-spike`)

`PhotoBooth` flags: `--windowed`, `--fake-camera`, `--fake-fail-rate X`, `--config PATH`, `--learn-key`,
`--google-login`, `--self-test` (runs the state-machine scenarios), `--auto-press SECONDS`,
`--print-window-id`, `--snapshot-dir DIR` (PNGs of the booth window and the control panel after each state change,
plus a full-height render of the panel), `--render-print A.jpg B.jpg C.jpg --out SHEET.jpg` (renders a print sheet
with the configured artwork / caption and exits; prints nothing). Develop without hardware (booth and control panel as normal windows):

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
