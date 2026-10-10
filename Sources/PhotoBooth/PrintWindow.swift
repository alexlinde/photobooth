import AppKit
import BoothCore
import Observation
import SwiftUI

// MARK: - Model

/// State behind the print window (⌘P): the event's photos, the three picked for the sheet (in
/// click order), a live preview, and the printer. Printing is never automatic: the attendant
/// picks three photos and presses Print; one sheet = two identical strips.
@MainActor
@Observable
final class PrintModel {
    let printer = PrinterService()
    /// The config in effect (template, caption, media, event folder).
    private(set) var config: BoothConfig
    /// Event photos, newest first.
    private(set) var photos: [URL] = []
    /// Picked photos, in click order (top to bottom on the strip).
    private(set) var selection: [URL] = []
    private(set) var preview: NSImage?
    private(set) var hasArtwork = false
    private(set) var artworkWarning: String?
    var copies = 1
    private(set) var sending = false
    /// Result of the last Print ("Sent to printer", or what went wrong).
    private(set) var message: (text: String, isError: Bool)?

    /// Saves the attendant's printer choice into config.json.
    @ObservationIgnored var onChoosePrinter: ((String) -> Void)?
    @ObservationIgnored private var artwork: CGImage?
    /// Preview-size photos, by file.
    @ObservationIgnored private var previewPhotos: [URL: CGImage] = [:]
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var photosTask: Task<Void, Never>?

    static let photosPerSheet = PrintLayout.photosPerStrip
    static let copiesRange = 1...5
    /// Preview resolution (600 x 888 px).
    static let previewScale: CGFloat = 0.5

    init(config: BoothConfig) {
        self.config = config
        printer.configured = config.printer
    }

    var canPrint: Bool { selection.count == Self.photosPerSheet && printer.printer != nil && !sending }

    func number(of url: URL) -> Int? { selection.firstIndex(of: url).map { $0 + 1 } }

    // MARK: Window

    /// Window opened: re-read photos and artwork (it may have been edited), start polling.
    func opened() {
        refreshPhotos()
        reloadArtwork()
        printer.startPolling()
    }

    func closed() {
        printer.stopPolling()
    }

    func configApplied(_ cfg: BoothConfig) {
        let folderChanged = cfg.eventDirectoryURL != config.eventDirectoryURL
        let artChanged = cfg.printTemplateURL != config.printTemplateURL || cfg.printCaptionText != config.printCaptionText
        config = cfg
        if printer.configured != cfg.printer {
            printer.configured = cfg.printer
            Task { await printer.refresh() }
        }
        if folderChanged {
            selection = []
            refreshPhotos()
        }
        if artChanged { reloadArtwork() }
    }

    // MARK: Photos

    /// Re-lists the event folder (top-level JPEGs only; `prints/` is skipped).
    func refreshPhotos() {
        let dir = config.eventDirectoryURL
        photosTask?.cancel()
        photosTask = Task { [weak self] in
            let urls = await Task.detached(priority: .utility) { ThumbnailCache.eventPhotos(in: dir) }.value
            guard let self, !Task.isCancelled else { return }
            self.photos = urls
            let gone = self.selection.filter { !urls.contains($0) }
            if !gone.isEmpty {
                self.selection.removeAll { gone.contains($0) }
                self.updatePreview()
            }
        }
    }

    /// Click: pick (up to three) or un-pick; the others renumber.
    func toggle(_ url: URL) {
        if let i = selection.firstIndex(of: url) {
            selection.remove(at: i)
        } else if selection.count < Self.photosPerSheet {
            selection.append(url)
        } else {
            return
        }
        message = nil
        updatePreview()
    }

    /// The three newest, oldest first (one press with `shotsPerPress` 3).
    func selectLatest() {
        selection = Array(photos.prefix(Self.photosPerSheet).reversed())
        message = nil
        updatePreview()
    }

    func clearSelection() {
        selection = []
        updatePreview()
    }

    // MARK: Preview

    private func reloadArtwork() {
        let url = config.printTemplateURL
        Task { [weak self] in
            let art = await Task.detached(priority: .userInitiated) { PrintSheet.loadArtwork(url) }.value
            guard let self else { return }
            self.artwork = art.image
            self.hasArtwork = art.image != nil
            self.artworkWarning = art.warning
            self.updatePreview()
        }
    }

    /// Re-renders the preview shortly after the last change, off the main thread.
    private func updatePreview() {
        previewTask?.cancel()
        let urls = selection
        let cached = previewPhotos
        let artwork = artwork
        let caption = config.printCaptionText
        let scale = Self.previewScale
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            let (image, loaded) = await Task.detached(priority: .userInitiated) { () -> (CGImage?, [URL: CGImage]) in
                var loaded: [URL: CGImage] = [:]
                let photos: [CGImage?] = urls.map { url in
                    if let img = cached[url] { return img }
                    let img = PrintSheet.loadPhoto(url, maxPixel: Int(CGFloat(PrintSheet.photoMaxPixel) * scale))
                    loaded[url] = img
                    return img
                }
                return (PrintSheet.render(photos: photos, artwork: artwork, caption: caption, scale: scale), loaded)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.previewPhotos.merge(loaded) { a, _ in a }
            if self.previewPhotos.count > 30 { self.previewPhotos = self.previewPhotos.filter { self.selection.contains($0.key) } }
            self.preview = image.map { NSImage(cgImage: $0, size: .zero) }
        }
    }

    // MARK: Printing

    func choosePrinter(_ name: String) {
        guard name != printer.configured else { return }
        printer.configured = name
        config.printer = name
        onChoosePrinter?(name)
        Task { await printer.refresh() }
    }

    /// Renders the full-size sheet, saves it to `<event>/prints/`, then sends it to the printer.
    func print() {
        guard canPrint else { return }
        let urls = selection, cfg = config, copies = copies
        sending = true
        message = nil
        Task { [weak self] in
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    try PrintSheet.save(PrintSheet.renderJPEG(photoURLs: urls, config: cfg), in: cfg.printsDirectoryURL)
                }.value
                BoothLog.info(.printing, "Rendered \(file.lastPathComponent) from \(urls.map(\.lastPathComponent))")
                guard let self else { return }
                let job = try await self.printer.submit(file, copies: copies, media: cfg.printMedia)
                self.selection = []
                self.updatePreview()
                self.message = ("Sent to printer (\(copies == 1 ? "1 sheet" : "\(copies) sheets"), job \(job))", false)
            } catch {
                BoothLog.error(.printing, "Print failed: \(error)")
                self?.message = ("Not printed: \(error)", true)
            }
            self?.sending = false
        }
    }
}

// MARK: - View

struct PrintView: View {
    @Bindable var model: PrintModel

    var body: some View {
        HStack(spacing: 0) {
            photoPicker
            Divider()
            Form {
                sheetSection
                printerSection
            }
            .formStyle(.grouped)
            .frame(width: 400)
        }
        .frame(minWidth: 900, minHeight: 640)
    }

    // MARK: Photos

    private var photoPicker: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pick 3 photos").font(.headline)
                Text("\(model.selection.count) of 3 · click order is top to bottom").foregroundStyle(.secondary)
                Spacer()
                Button("Last 3") { model.selectLatest() }
                    .disabled(model.photos.count < PrintModel.photosPerSheet)
                    .help("The three newest photos, oldest first")
                Button("Clear") { model.clearSelection() }
                    .disabled(model.selection.isEmpty)
            }
            .padding(12)
            Divider()
            if model.photos.isEmpty {
                Text("No photos yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(model.photos, id: \.self) { url in
                            Button { model.toggle(url) } label: {
                                PhotoTile(url: url, number: model.number(of: url))
                            }
                            .buttonStyle(.plain)
                            .help(url.lastPathComponent)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 480)
    }

    // MARK: Sheet

    private var sheetSection: some View {
        Section {
            HStack {
                Spacer()
                Group {
                    if let img = model.preview {
                        Image(nsImage: img).resizable().interpolation(.high)
                    } else {
                        Color.white
                    }
                }
                .aspectRatio(PrintLayout.sheetMM.width / PrintLayout.sheetMM.height, contentMode: .fit)
                .frame(height: 380)
                .overlay { Rectangle().stroke(Color.secondary.opacity(0.4), lineWidth: 1) }
                .shadow(radius: 2)
                Spacer()
            }
            .padding(.vertical, 4)
            if let w = model.artworkWarning {
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.hasArtwork {
                Text("No artwork (\(model.config.printTemplateURL?.lastPathComponent ?? "printTemplate is empty")), so the strips show the caption “\(model.config.printCaptionText)”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Stepper("Copies: \(model.copies)", value: $model.copies, in: PrintModel.copiesRange)
            HStack {
                if let m = model.message {
                    Label(m.text, systemImage: m.isError ? "xmark.octagon.fill" : "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(m.isError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.sending { ProgressView().controlSize(.small) }
                Button("Print") { model.print() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canPrint)
            }
        } header: {
            Text("Sheet (two identical strips)")
        }
    }

    // MARK: Printer

    private var printerSection: some View {
        Section {
            let p = model.printer
            let selection = Binding<String>(get: { p.printer ?? "" }, set: { model.choosePrinter($0) })
            Picker("Printer", selection: selection) {
                if p.printer == nil { Text("None").tag("") }
                ForEach(choices, id: \.self) { name in
                    Text(p.printers.contains(name) ? name : "\(name) (not found)").tag(name)
                }
            }
            .pickerStyle(.menu)
            let a = p.attention
            StatusRow(title: "Status", text: a.text, color: Self.color(a.level))
            if p.jobs.isEmpty {
                LabeledContent("Queue", value: "Empty")
            } else {
                ForEach(p.jobs) { job in
                    LabeledContent {
                        HStack {
                            Text(job.id == p.status?.activeJob ? "printing" : "waiting").foregroundStyle(.secondary)
                            Button("Cancel") { Task { await p.cancel(job) } }.controlSize(.small)
                        }
                    } label: {
                        Text(job.id)
                    }
                }
            }
        } header: {
            Text("Printer")
        } footer: {
            Text("Each sheet takes about a minute.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var choices: [String] {
        var names = model.printer.printers
        if let p = model.printer.printer, !names.contains(p) { names.insert(p, at: 0) }
        return names
    }

    static func color(_ level: PrinterAttention.Level) -> Color {
        switch level {
        case .ready: return .green
        case .warning: return .orange
        case .problem: return .red
        case .info: return .secondary
        }
    }
}

/// A photo in the picker: thumbnail (loaded lazily via `ThumbnailCache`) plus its number on the
/// strip when picked.
private struct PhotoTile: View {
    let url: URL
    let number: Int?
    @State private var image: NSImage?

    var body: some View {
        Color.black.opacity(0.08)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).stroke(number == nil ? Color.clear : Color.accentColor, lineWidth: 4)
            }
            .overlay(alignment: .topLeading) {
                if let number {
                    Text("\(number)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.accentColor))
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .task(id: url) {
                image = await ThumbnailCache.shared.thumbnail(for: url).map { NSImage(cgImage: $0, size: .zero) }
            }
    }
}
