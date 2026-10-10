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
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var thumbnails: [URL: NSImage] = [:]
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
        if clean { draft = cfg }
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

    /// Reloads the newest photos in the event folder (names are timestamps, so sort by name).
    func refreshPhotos() {
        let dir = applied.eventDirectoryURL
        let cache = thumbnails
        photosTask?.cancel()
        photosTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> [(URL, CGImage?)] in
                let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles])) ?? []
                let newest = files.filter { $0.pathExtension.lowercased() == "jpg" }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
                    .prefix(8)
                return newest.map { url in (url, cache[url] == nil ? Self.thumbnail(url) : nil) }
            }.value
            guard let self, !Task.isCancelled else { return }
            for (url, img) in loaded {
                if let img { self.thumbnails[url] = NSImage(cgImage: img, size: .zero) }
            }
            self.recent = loaded.map { RecentPhoto(url: $0.0, thumbnail: self.thumbnails[$0.0]) }
        }
    }

    nonisolated static func thumbnail(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
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
            return ("Not seized (\(b.seizeFailure ?? "error")): the button also types into the focused app", .orange)
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
            StatusRow(title: "Uploads", text: "Off with --fake-camera (photos are saved locally)", color: .secondary)
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

    private var boothSection: some View {
        Section {
            TextField("Event name", text: $model.draft.eventName)
            TextField("Album name", text: $model.draft.albumName)
            Stepper("Countdown: \(model.draft.countdownSeconds) s", value: $model.draft.countdownSeconds, in: 0...10)
            Stepper("Review: \(Int(model.draft.reviewSeconds)) s", value: $model.draft.reviewSeconds, in: 1...60, step: 1)
            Stepper("Photos per press: \(model.draft.shotsPerPress)", value: $model.draft.shotsPerPress, in: 1...10)
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
