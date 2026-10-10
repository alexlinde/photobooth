import AppKit
import BoothCore
import ImageIO
import Observation
import SonyCamera
import SwiftUI

// MARK: - Model

/// State behind the attendant control panel (⌘,): live status from the camera, controller,
/// button and uploads, plus an editable draft of config.json.
@MainActor
@Observable
final class ControlPanelModel {
    struct RecentPhoto: Identifiable, Equatable {
        let url: URL
        var thumbnail: NSImage?
        var id: URL { url }
    }

    let controller: BoothController
    var cameraState: CameraConnectionState
    var cameraStatus: CameraStatus
    var button: ButtonInput.Status?
    /// nil with --fake-camera (fake photos are never uploaded).
    var uploads: UploadService?
    /// The print window's model: printer status, and strip mode's last print.
    var printing: PrintModel?

    /// The config in effect (last loaded or saved).
    private(set) var applied: BoothConfig
    /// What the panel edits; "Apply & Save" writes it, "Revert" discards it.
    var draft: BoothConfig
    /// Problem with config.json as loaded (the booth then runs on defaults).
    var loadError: ConfigError?
    /// Validation / save errors from the last "Apply & Save".
    var errors: [String] = []
    var message: String?
    var profileExpanded = false
    private(set) var recent: [RecentPhoto] = []
    let configPath: String

    /// Validates + saves + applies; returns the problem, if any.
    @ObservationIgnored var onSave: ((BoothConfig) -> ConfigError?)?
    /// Opens the print window.
    @ObservationIgnored var onPrint: (() -> Void)?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var photosTask: Task<Void, Never>?

    init(controller: BoothController, camera: BoothCamera, config: BoothConfig, configPath: String) {
        self.controller = controller
        self.cameraState = camera.state
        self.cameraStatus = camera.status
        self.applied = config
        self.draft = config
        self.configPath = configPath
        let states = camera.stateUpdates()
        let statuses = camera.statusUpdates()
        tasks.append(Task { [weak self] in
            for await s in states { self?.cameraState = s }
        })
        tasks.append(Task { [weak self] in
            for await s in statuses { self?.cameraStatus = s }
        })
    }

    var isDirty: Bool { draft != applied }

    // MARK: Config

    /// Called whenever the app loads or saves config (including Ctrl+Opt+Cmd+R). Unsaved
    /// edits are kept.
    func configApplied(_ cfg: BoothConfig) {
        let clean = draft == applied
        let folderChanged = cfg.eventDirectoryURL != applied.eventDirectoryURL
        applied = cfg
        loadError = nil
        if clean {
            draft = cfg
        } else {
            // The panel doesn't edit the print settings (the print window saves the printer).
            draft.printer = cfg.printer
            draft.printMedia = cfg.printMedia
            draft.printTemplate = cfg.printTemplate
            draft.printCaption = cfg.printCaption
        }
        if folderChanged { refreshPhotos() }
    }

    func applyAndSave() {
        message = nil
        errors = draft.validationErrors()
        guard errors.isEmpty else { return }
        if let e = onSave?(draft) {
            errors = e.problems
            return
        }
        let f = DateFormatter()
        f.timeStyle = .medium
        message = "Saved and applied at \(f.string(from: Date()))."
    }

    func revert() {
        draft = applied
        errors = []
        message = nil
    }

    /// The draft's value for a profile field, with the built-in as fallback.
    func profileValue(_ field: ProfileField) -> String? {
        draft.cameraProfile.flatMap { field.value(in: $0) }
    }

    /// Picking the built-in value clears the override, so config.json only holds real changes.
    func setProfileValue(_ field: ProfileField, _ value: String?) {
        guard let base = draft.lighting.builtin else { return }
        var o = draft.profiles[draft.lighting]
        field.setOverride(value == field.value(in: base) ? nil : value, in: &o)
        draft.profiles[draft.lighting] = o
    }

    func resetProfile() {
        draft.profiles[draft.lighting] = ProfileOverride()
    }

    // MARK: Recent photos

    /// Reloads the newest photos in the event folder.
    func refreshPhotos() {
        let dir = applied.eventDirectoryURL
        photosTask?.cancel()
        photosTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> [(URL, CGImage?)] in
                ThumbnailCache.eventPhotos(in: dir).prefix(8).map { ($0, ThumbnailCache.shared.thumbnail($0)) }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.recent = loaded.map { RecentPhoto(url: $0.0, thumbnail: $0.1.map { NSImage(cgImage: $0, size: .zero) }) }
        }
    }

    func showFolder() {
        let dir = applied.eventDirectoryURL
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } else {
            NSWorkspace.shared.open(applied.outputRootURL)
        }
    }

    // MARK: Status text

    var cameraText: (String, Color) {
        switch cameraState {
        case .ready(let name): return ("\(name) ready", .green)
        case .connecting(let name): return ("Connecting to \(name)…", .orange)
        case .searching: return ("Looking for the camera…", .orange)
        case .recovering(let reason): return ("Reconnecting (\(reason))", .red)
        }
    }

    var boothText: String {
        switch controller.state {
        case .waitingForCamera: return "Waiting for the camera"
        case .idle: return "Ready"
        case let .countdown(r, k, n): return n > 1 ? "Countdown \(r) (photo \(k) of \(n))" : "Countdown \(r)"
        case .capturing: return "Taking a photo"
        case .review: return "Showing the photo"
        case .betweenShots: return "Between photos"
        case .flyIn: return "Adding the photo to the strip"
        case .stripReview: return "Showing the finished strip"
        case .notice: return "Capture failed; retrying"
        case .attendant: return "Attendant needed"
        case .paused: return "Paused (TV shows “Back in a moment”)"
        }
    }

    var readoutText: String? {
        guard let r = cameraStatus.readout else { return nil }
        let parts = [r.exposureMode, r.shutterSpeed, r.aperture, r.iso.map { "ISO \($0)" },
                     r.flashMode.map { "flash \($0)" }, r.focusMode, r.batteryPercent.map { "battery \($0)%" }]
        let s = parts.compactMap { $0 }.joined(separator: " · ")
        return s.isEmpty ? nil : s
    }

    var buttonText: (String, Color) {
        guard let b = button else { return ("Not started", .secondary) }
        if let reason = b.fallbackReason { return ("Focused-window fallback: " + reason, .orange) }
        if b.mode == .local { return ("Focused-window keys (buttonInput \"local\")", .secondary) }
        if b.deviceConnected == false { return ("Not connected (\(b.deviceDescription ?? "configured device"))", .red) }
        if b.deviceConnected == nil { return ("HID, any keyboard (no buttonDevice filter)", .secondary) }
        return ("Connected (HID, works in the background)", .green)
    }

    /// nil when there's nothing to say (no filter, or not HID).
    var seizeText: (String, Color)? {
        guard let b = button, b.mode == .hid, b.deviceDescription != nil else { return nil }
        if b.seized == true { return ("Seized: its keystrokes reach only the booth", .green) }
        if b.seized == false {
            return ("The button also types into the focused app (program it to F13 to avoid this)", .orange)
        }
        return nil
    }
}

extension ProfileField: Identifiable {
    public var id: String { rawValue }
}

// MARK: - View

struct ControlPanelView: View {
    @Bindable var model: ControlPanelModel
    @State private var creatingAlbum = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                statusSection
                lightingSection
                boothSection
                photosSection
            }
            .formStyle(.grouped)
            Divider()
            actionBar
        }
        .frame(minWidth: 460, minHeight: 480)
    }

    // MARK: Status

    private var statusSection: some View {
        Section("Status") {
            if let issue = model.controller.attendantIssue {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Reset") { model.controller.attendantReset() }
                    }
                    Text(issue.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
            LabeledContent("Booth", value: model.boothText)
            StatusRow(title: "Camera", text: model.cameraText.0, color: model.cameraText.1)
            profileStatus
            if let r = model.readoutText {
                LabeledContent("Camera reports") {
                    Text(r).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
            }
            StatusRow(title: "Button", text: model.buttonText.0, color: model.buttonText.1)
            if let s = model.seizeText {
                StatusRow(title: "Keystrokes", text: s.0, color: s.1)
            }
            uploadStatus
            printerStatus
        }
    }

    /// The printer: always in strip mode, otherwise while the print window is polling it.
    @ViewBuilder
    private var printerStatus: some View {
        if let pm = model.printing, model.applied.stripMode || pm.printer.polling {
            let p = pm.printer
            let a = p.attention
            let queued = p.jobs.isEmpty ? "" : " · \(p.jobs.count) in queue"
            StatusRow(title: "Printer", text: a.text + queued, color: PrintView.color(a.level))
            if model.applied.stripMode, let s = pm.stripStatus {
                StatusRow(title: "Last strip", text: s.text, color: s.isError ? .red : .secondary)
            }
        }
    }

    @ViewBuilder
    private var profileStatus: some View {
        let st = model.cameraStatus
        if let p = st.profile {
            if st.applyingProfile {
                LabeledContent("Lighting") {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Applying \(p.name)…")
                    }
                }
            } else if let report = st.lastReport {
                if report.allOK {
                    StatusRow(title: "Lighting", text: "✓ \(report.profileName) applied", color: .green)
                } else {
                    StatusRow(title: "Lighting", text: "\(report.profileName): \(report.problems.count) setting(s) not applied", color: .orange)
                    ForEach(Array(report.problems.enumerated()), id: \.offset) { _, item in
                        LabeledContent {
                            Text(Self.describe(item.outcome))
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.trailing)
                        } label: {
                            Text("\(item.setting) \(item.requested)")
                                .padding(.leading, 12)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                StatusRow(title: "Lighting", text: "\(p.name): applies when the camera connects", color: .secondary)
            }
        } else {
            StatusRow(title: "Lighting", text: "Camera settings left alone", color: .secondary)
        }
    }

    static func describe(_ o: CameraProfileReport.Outcome) -> String {
        switch o {
        case .applied: return "applied"
        case .alreadySet: return "already set"
        case .mismatch(let actual): return "camera shows \(actual)"
        case .locked: return "locked in this mode"
        case .unsupported: return "not supported"
        case .failed(let why): return "failed: \(why)"
        }
    }

    @ViewBuilder
    private var uploadStatus: some View {
        if let u = model.uploads {
            if let signedIn = u.signedIn {
                LabeledContent("Google Photos") {
                    HStack(spacing: 8) {
                        if u.signingIn {
                            ProgressView().controlSize(.small)
                            Text("Waiting for the browser…")
                        } else if signedIn {
                            Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("Not signed in").foregroundStyle(.orange)
                            Button("Sign in…") { Task { await u.signIn() } }
                        }
                    }
                }
                if let e = u.signInError {
                    Text("Sign-in failed: \(e)").font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Uploads") {
                    if let s = u.snapshot {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(s.uploaded) done · \(s.pending + s.inFlight) pending · \(s.failedPermanently) failed")
                                .foregroundStyle(s.failedPermanently > 0 ? .orange : .primary)
                            if s.isPausedOffline { Text("Offline: paused until the network is back").foregroundStyle(.orange) }
                            if let e = s.lastError { Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        .multilineTextAlignment(.trailing)
                    } else {
                        Text("Starting…").foregroundStyle(.secondary)
                    }
                }
            } else {
                StatusRow(title: "Uploads", text: "Off: no google_client.json (photos are saved locally)", color: .secondary)
            }
        } else {
            StatusRow(title: "Uploads", text: model.applied.upload ? "Off with --fake-camera (photos are saved locally)"
                                                    : "Off in settings (photos are saved locally)", color: .secondary)
        }
    }

    // MARK: Lighting

    private var lightingSection: some View {
        Section("Lighting") {
            Picker("Lighting", selection: $model.draft.lighting) {
                ForEach(Lighting.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let base = model.draft.lighting.builtin {
                DisclosureGroup("\(base.name) settings", isExpanded: $model.profileExpanded) {
                    ForEach(visibleFields, id: \.self) { field in
                        fieldPicker(field, builtin: field.value(in: base))
                    }
                    if model.draft.profileValue(.exposureMode) == "manual" {
                        Text("Exposure compensation is locked in manual mode, so it isn't shown.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.draft.profiles[model.draft.lighting].isEmpty {
                        HStack {
                            Spacer()
                            Button("Reset to built-in \(base.name)") { model.resetProfile() }
                        }
                    }
                }
            } else {
                Text("The booth won't change any camera settings; set them on the camera.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Exposure compensation is display-only in manual mode, so it's hidden there.
    private var visibleFields: [ProfileField] {
        ProfileField.allCases.filter { !($0 == .exposureCompensation && model.profileValue(.exposureMode) == "manual") }
    }

    private func fieldPicker(_ field: ProfileField, builtin: String?) -> some View {
        let current = model.profileValue(field)
        var choices = field.choices
        if let c = current, !choices.contains(c) { choices.insert(c, at: 0) }  // odd value from config.json
        let binding = Binding<String?>(get: { current }, set: { model.setProfileValue(field, $0) })
        return Picker(field.title, selection: binding) {
            if builtin == nil { Text("Leave as is").tag(String?.none) }
            ForEach(choices, id: \.self) { v in
                Text(field.display(v) + (v == builtin ? "  (built-in)" : "")).tag(String?.some(v))
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: Booth

    private static let newAlbumTag = "\u{0}new-album"

    /// Albums this booth made: Google's list if we have it, else what this Mac remembers.
    private var albumChoices: [(title: String, label: String)] {
        guard let u = model.uploads else { return [] }
        var rows: [(String, String)]
        if let remote = u.remoteAlbums {
            rows = remote.map { a in (a.title, a.mediaItemsCount.map { "\(a.title) (\($0) photos)" } ?? a.title) }
        } else {
            rows = u.localAlbumTitles.map { ($0, $0) }
        }
        let current = model.draft.albumName
        if !current.isEmpty, !rows.contains(where: { $0.0 == current }) {
            rows.insert((current, "\(current) (will be created)"), at: 0)
        }
        var seen = Set<String>()
        return rows.filter { seen.insert($0.0).inserted }.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    @ViewBuilder
    private var albumPicker: some View {
        if let u = model.uploads, u.signedIn != nil {
            let selection = Binding<String>(
                get: { creatingAlbum ? Self.newAlbumTag : model.draft.albumName },
                set: { v in
                    if v == Self.newAlbumTag { creatingAlbum = true }
                    else { creatingAlbum = false; model.draft.albumName = v }
                })
            HStack {
                Picker("Album", selection: selection) {
                    ForEach(albumChoices, id: \.title) { Text($0.label).tag($0.title) }
                    Divider()
                    Text("New album…").tag(Self.newAlbumTag)
                }
                .pickerStyle(.menu)
                Button {
                    Task { await u.refreshAlbums() }
                } label: {
                    if u.refreshingAlbums { ProgressView().controlSize(.small) } else { Text("Refresh") }
                }
                .disabled(!u.canListAlbums || u.refreshingAlbums)
                .help(u.canListAlbums ? "Ask Google Photos for the albums this booth created"
                                      : "Sign in again to list your albums")
            }
            if creatingAlbum {
                TextField("New album title", text: $model.draft.albumName)
            }
            if u.signedIn == true && !u.canListAlbums {
                HStack {
                    Text("Sign in again to see your albums.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign in again") { Task { await u.signIn() } }.disabled(u.signingIn)
                }
            }
            if let e = u.albumsError {
                Text("Couldn't list albums: \(e)").font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        } else {
            TextField("Album name", text: $model.draft.albumName)
        }
    }

    private var boothSection: some View {
        Section {
            TextField("Event name", text: $model.draft.eventName)
            albumPicker
            Stepper("Countdown: \(model.draft.countdownSeconds) s", value: $model.draft.countdownSeconds, in: 0...10)
            Stepper("Review: \(Int(model.draft.reviewSeconds)) s", value: $model.draft.reviewSeconds, in: 1...60, step: 1)
            Toggle("Strip mode (3 photos, then print)", isOn: $model.draft.stripMode)
            if model.draft.stripMode {
                Toggle("Print strips automatically", isOn: $model.draft.autoPrint)
            }
            Toggle("Upload to Google Photos", isOn: $model.draft.upload)
            Stepper(model.draft.stripMode ? "Photos per press: \(PrintLayout.photosPerStrip) (strip mode)" : "Photos per press: \(model.draft.shotsPerPress)",
                    value: $model.draft.shotsPerPress, in: 1...10)
                .disabled(model.draft.stripMode)
            TextField("Idle prompt", text: $model.draft.idlePrompt)
            Toggle("Mirror preview", isOn: $model.draft.mirrorPreview)
        } header: {
            Text("Booth")
        } footer: {
            Text("Photos go to \(model.draft.eventDirectoryURL.path(percentEncoded: false)). Settings file: \(model.configPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: Photos

    private var photosSection: some View {
        Section {
            if model.recent.isEmpty {
                Text("No photos yet.").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(model.recent) { photo in
                        Button { NSWorkspace.shared.open(photo.url) } label: {
                            thumbnail(photo)
                        }
                        .buttonStyle(.plain)
                        .help(photo.url.lastPathComponent)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack {
                Text("Recent photos")
                Spacer()
                Button("Print…") { model.onPrint?() }
                    .controlSize(.small)
                    .help("Print a photo strip (⌘P)")
                Button("Show folder") { model.showFolder() }
                    .controlSize(.small)
            }
        }
    }

    private func thumbnail(_ photo: ControlPanelModel.RecentPhoto) -> some View {
        Color.black.opacity(0.08)
            .aspectRatio(3 / 2, contentMode: .fit)
            .overlay {
                if let img = photo.thumbnail {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Actions

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.errors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.errors, id: \.self) { e in
                        Label(e, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout)
            } else if let e = model.loadError {
                Label("config.json has problems, so defaults are in use. Saving replaces it. " + e.problems.joined(separator: " "),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let m = model.message, !model.isDirty {
                Label(m, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Test shot") { model.controller.buttonPressed() }
                    .disabled(!(model.controller.state == .idle))
                if model.controller.isPaused {
                    Button("Resume") { model.controller.resume() }
                } else {
                    Button("Pause booth") { model.controller.pause() }
                }
                Spacer()
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty)
                Button("Apply & Save") { model.applyAndSave() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isDirty && model.loadError == nil)
            }
        }
        .padding(12)
    }
}

/// Event-folder photo thumbnails, shared by the control panel and the print window. Thread-safe;
/// least-recently-used ones are dropped past `countLimit`.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, CGImage>()

    init() { cache.countLimit = 500 }

    /// JPEGs directly in the event folder, newest first (names are timestamps, so sort by name).
    /// Subfolders such as `prints/` are not looked into.
    nonisolated static func eventPhotos(in dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Cached, or decoded now (synchronous: call off the main thread).
    func thumbnail(_ url: URL) -> CGImage? {
        if let img = cache.object(forKey: url as NSURL) { return img }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }

    /// The same, decoded on a background thread.
    func thumbnail(for url: URL) async -> CGImage? {
        await Task.detached(priority: .utility) { self.thumbnail(url) }.value
    }
}

/// "Title ........ ● text" with a status colour.
struct StatusRow: View {
    let title: String
    let text: String
    let color: Color
    var body: some View {
        LabeledContent(title) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if color != .secondary {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(text)
                    .foregroundStyle(color == .secondary ? Color.secondary : Color.primary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

extension BoothConfig {
    /// Effective profile field value (overrides on the built-in), as a friendly string.
    func profileValue(_ field: ProfileField) -> String? {
        cameraProfile.flatMap { field.value(in: $0) }
    }
}
