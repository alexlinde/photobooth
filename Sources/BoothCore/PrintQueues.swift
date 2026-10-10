import Foundation

/// A CUPS printer's state, from `lpstat -l -p NAME`.
public struct PrinterStatus: Equatable, Sendable {
    public enum State: String, Sendable { case idle, printing, stopped }
    public var name: String
    public var state: State
    /// The job being printed ("Canon_CP910-47"), when printing.
    public var activeJob: String?
    /// The printer's status line, e.g. "Looking for printer." or "Waiting for job to complete."
    /// (for a stopped queue, the reason it stopped).
    public var message: String?
    /// IPP printer-state-reasons, e.g. "media-empty-error", "media-needed".
    public var alerts: [String]

    public init(name: String, state: State, activeJob: String? = nil, message: String? = nil, alerts: [String] = []) {
        self.name = name
        self.state = state
        self.activeJob = activeJob
        self.message = message
        self.alerts = alerts
    }

    /// The backend is still trying to reach the printer (on its own that's normal for a few seconds).
    public var isSearching: Bool {
        message?.localizedCaseInsensitiveContains("looking for printer") == true || alerts.contains("connecting-to-device")
    }
}

/// A queued job, from `lpstat -o NAME`.
public struct PrintJob: Equatable, Sendable, Identifiable {
    public var id: String
    public var user: String
    public var bytes: Int?
    public var submitted: String
}

/// What the print window says about the printer: text for the attendant plus a status colour.
public struct PrinterAttention: Equatable, Sendable {
    public enum Level: Sendable { case ready, warning, problem, info }
    public var text: String
    public var level: Level
    public init(_ text: String, _ level: Level) {
        self.text = text
        self.level = level
    }
}

/// Parsing for the CUPS command-line tools (`lpstat`, `lp`) and the attendant wording for printer
/// alerts. Pure, so it's unit-tested; the app runs the tools.
public enum PrintQueues {
    /// After this long "Looking for printer" counts as unreachable.
    public static let searchGraceSeconds: TimeInterval = 20

    static let paperText = "Out of paper or a sheet didn't feed — reload the paper cassette (fan the sheets); the print continues by itself"
    static let inkText = "Ink cassette used up or missing — put in a new one; the print continues by itself"
    static let jamText = "Paper jam — pull out the paper cassette, remove the stuck sheet, and put it back"
    static let unreachableText = "Printer not reachable — is it on and on the same Wi-Fi?"
    /// Reasons that need no action.
    static let benignAlerts: Set<String> = ["none", "cups-waiting-for-job-completed", "connecting-to-device"]

    /// Queue names from `lpstat -e` (one per line); also accepts `lpstat -p` lines.
    public static func parseDestinations(_ out: String) -> [String] {
        out.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("printer ") { return line.split(separator: " ").dropFirst().first.map(String.init) }
            return line.isEmpty || line.contains(" ") ? nil : line
        }
    }

    /// The first queue that looks like a SELPHY: name contains "selphy" or a model like "CP910"
    /// (case-insensitive). nil = none.
    public static func autoPick(_ names: [String]) -> String? {
        names.first { n in
            n.localizedCaseInsensitiveContains("selphy") || n.range(of: #"cp\d{3,4}"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Fields `lpstat -l` prints after the status line.
    private static let fieldPrefixes = ["Form mounted:", "Content types:", "Printer types:", "Description:", "Alerts:",
                                        "Location:", "Connection:", "Interface:", "On fault:", "After fault:"]

    /// Parses `lpstat -l -p NAME`. nil when the output has no line for `printer`.
    public static func parseStatus(_ out: String, printer: String) -> PrinterStatus? {
        let lines = out.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("printer \(printer) ") }) else { return nil }
        let header = lines[start]
        let rest = header.dropFirst("printer \(printer) ".count)
        var status = PrinterStatus(name: printer, state: .idle)
        if rest.hasPrefix("now printing ") {
            status.state = .printing
            let job = rest.dropFirst("now printing ".count).prefix { !$0.isWhitespace }
            status.activeJob = job.hasSuffix(".") ? String(job.dropLast()) : String(job)
        } else if rest.hasPrefix("disabled") {
            status.state = .stopped
        }
        var messages: [String] = []
        var inFields = false
        for line in lines[(start + 1)...] {
            if line.hasPrefix("printer ") { break }  // the next printer (lpstat -p without a name)
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if fieldPrefixes.contains(where: t.hasPrefix) { inFields = true }
            if t.hasPrefix("Alerts:") {
                status.alerts = t.dropFirst("Alerts:".count).split(separator: " ").map(String.init).filter { $0 != "none" }
            } else if !inFields {
                messages.append(t)
            }
        }
        status.message = messages.isEmpty ? nil : messages.joined(separator: " ")
        return status
    }

    /// Parses `lpstat -o NAME`: `Canon_CP910-47  alexlinde  6427648  Sat Oct 10 11:18:07 2026`.
    public static func parseJobs(_ out: String) -> [PrintJob] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, f[0].contains("-") else { return nil }
            return PrintJob(id: String(f[0]), user: String(f[1]), bytes: Int(f[2]), submitted: f.dropFirst(3).joined(separator: " "))
        }
    }

    /// The job ID from `lp`'s "request id is Canon_CP910-48 (1 file(s))".
    public static func parseRequestID(_ out: String) -> String? {
        guard let r = out.range(of: "request id is ") else { return nil }
        let id = out[r.upperBound...].prefix { !$0.isWhitespace }
        return id.isEmpty ? nil : String(id)
    }

    /// Attendant wording for the printer's state. `searchingFor` is how long it has been
    /// "Looking for printer" (0 when it isn't).
    public static func attention(_ status: PrinterStatus?, printer: String?, searchingFor: TimeInterval) -> PrinterAttention {
        guard let printer else {
            return PrinterAttention("No printer — add the SELPHY in System Settings → Printers & Scanners", .problem)
        }
        guard let s = status else {
            return PrinterAttention("\(printer) isn't set up on this Mac — add it in System Settings → Printers & Scanners", .problem)
        }
        let alerts = s.alerts
        if s.state == .stopped || alerts.contains(where: { $0.hasPrefix("offline") }) || searchingFor > searchGraceSeconds {
            return PrinterAttention(unreachableText, .problem)
        }
        if alerts.contains(where: { $0.hasPrefix("media-empty") || $0.hasPrefix("media-needed") }) {
            return PrinterAttention(paperText, .warning)
        }
        if alerts.contains(where: { $0.hasPrefix("media-jam") }) {
            return PrinterAttention(jamText, .warning)
        }
        if alerts.contains(where: { $0.hasPrefix("marker-supply-empty") || $0.contains("ribbon") }) {
            return PrinterAttention(inkText, .warning)
        }
        let other = alerts.filter { !benignAlerts.contains($0) }
        if !other.isEmpty {
            return PrinterAttention("Printer reports: " + other.joined(separator: ", ") + (s.message.map { " (\($0))" } ?? ""), .warning)
        }
        switch s.state {
        case .printing:
            return PrinterAttention("Printing" + (s.activeJob.map { " \($0)" } ?? "") + (s.message.map { " — \($0)" } ?? ""), .ready)
        case .idle:
            return PrinterAttention(s.message.map { "Ready — \($0)" } ?? "Ready", .ready)
        case .stopped:
            return PrinterAttention(unreachableText, .problem)
        }
    }
}
