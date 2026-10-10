import BoothCore
import Foundation
import Observation

/// The CUPS side of printing: lists queues, polls the chosen printer's status and job queue
/// (only while the print window is open), submits sheets with `lp` and cancels jobs. The tools
/// run off the main thread; their output is parsed by `PrintQueues` (BoothCore).
@MainActor
@Observable
final class PrinterService {
    struct ToolError: Error, CustomStringConvertible {
        var description: String
    }

    /// All CUPS queues on this Mac.
    private(set) var printers: [String] = []
    /// `printer` from config.json; "" = auto (the first SELPHY-looking queue).
    var configured = ""
    private(set) var status: PrinterStatus?
    private(set) var jobs: [PrintJob] = []
    /// False until the first poll has finished.
    private(set) var loaded = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var searchingSince: Date?
    @ObservationIgnored private var polls = 0

    static let pollSeconds = 3.0

    /// The queue sheets go to: the configured one, else the auto-picked one.
    var printer: String? { configured.isEmpty ? PrintQueues.autoPick(printers) : configured }

    var attention: PrinterAttention {
        guard loaded else { return PrinterAttention("Checking the printer…", .info) }
        let searching = searchingSince.map { Date().timeIntervalSince($0) } ?? 0
        return PrintQueues.attention(status, printer: printer, searchingFor: searching)
    }

    func startPolling() {
        guard pollTask == nil else { return }
        BoothLog.info(.printing, "Printer status polling started")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.pollSeconds))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Re-reads the queue list (every 10th poll) and the chosen printer's status and jobs.
    func refresh() async {
        if polls % 10 == 0 || printers.isEmpty {
            let r = await Self.run("/usr/bin/lpstat", ["-e"])
            printers = PrintQueues.parseDestinations(r.output)
        }
        polls += 1
        guard let name = printer else {
            status = nil
            jobs = []
            loaded = true
            return
        }
        async let st = Self.run("/usr/bin/lpstat", ["-l", "-p", name])
        async let jb = Self.run("/usr/bin/lpstat", ["-o", name])
        let (s, j) = await (st, jb)
        guard name == printer else { return }  // the choice changed meanwhile
        let new = PrintQueues.parseStatus(s.output, printer: name)
        if new?.isSearching == true { searchingSince = searchingSince ?? Date() } else { searchingSince = nil }
        if new != status { BoothLog.info(.printing, "\(name): \(new.map { "\($0.state.rawValue) \($0.message ?? "") alerts \($0.alerts)" } ?? "not found")") }
        status = new
        jobs = PrintQueues.parseJobs(j.output)
        loaded = true
    }

    /// Prints `file` once per copy, filling the page (the sheet has the paper's aspect).
    /// Returns the job ID.
    func submit(_ file: URL, copies: Int, media: String) async throws -> String {
        guard let name = printer else { throw ToolError(description: "No printer chosen.") }
        let args = ["-d", name, "-t", file.lastPathComponent, "-n", "\(copies)",
                    "-o", "media=\(media)", "-o", "print-scaling=fill", file.path]
        let r = await Self.run("/usr/bin/lp", args)
        guard r.status == 0 else {
            throw ToolError(description: "lp failed: " + (r.error.isEmpty ? "exit \(r.status)" : r.error))
        }
        let id = PrintQueues.parseRequestID(r.output) ?? "?"
        BoothLog.info(.printing, "Sent \(file.lastPathComponent) x\(copies) to \(name) (\(id))")
        await refresh()
        return id
    }

    func cancel(_ job: PrintJob) async {
        let r = await Self.run("/usr/bin/cancel", [job.id])
        BoothLog.info(.printing, "Cancel \(job.id): " + (r.status == 0 ? "ok" : r.error))
        await refresh()
    }

    /// Runs a tool on a background queue (never blocks the UI) with the C locale, so the
    /// output is the English the parsers expect.
    nonisolated static func run(_ tool: String, _ args: [String]) async -> (status: Int32, output: String, error: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tool)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["LANG"] = "C"
                env["LC_ALL"] = "C"
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: (-1, "", "\(error.localizedDescription)"))
                    return
                }
                // Read before waiting, so a full pipe can't stall the tool.
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: o, as: UTF8.self),
                                        String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }
}

/// `PhotoBooth --render-print a.jpg b.jpg c.jpg --out sheet.jpg`: renders a sheet with the
/// configured artwork / caption and exits (no booth, nothing printed).
enum RenderPrint {
    static func run(photos: [String], out: String, configPath: String?) -> Int32 {
        let (config, error) = ConfigLoader.load(path: configPath)
        if let error { print("config: \(error.description) (continuing with defaults)") }
        let art = PrintSheet.loadArtwork(config.printTemplateURL)
        if let w = art.warning { print("warning: \(w)") }
        print(art.image != nil ? "Artwork: \(config.printTemplateURL?.path ?? "")"
                               : "No artwork (\(config.printTemplateURL?.path ?? "printTemplate is empty")); caption \"\(config.printCaptionText)\"")
        do {
            let urls = photos.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let sheet = try PrintSheet.render(photoURLs: urls, artwork: art.image, caption: config.printCaptionText)
            guard let jpeg = PrintSheet.jpegData(sheet) else { print("Couldn't encode the sheet."); return 1 }
            let dest = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            try jpeg.write(to: dest, options: .atomic)
            print("Wrote \(dest.path) (\(sheet.width) x \(sheet.height) px)")
            return 0
        } catch {
            print("Render failed: \(error)")
            return 1
        }
    }
}
