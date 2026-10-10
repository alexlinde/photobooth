import Foundation
import os

/// Logging: `os.Logger` (subsystem "PhotoBooth") plus a tiny append-only file log at
/// `<logDir>/booth-YYYYMMDD.log`. Use `BoothLog.info(.ui, "...")` etc.
public enum BoothLog {
    public enum Category: String, Sendable {
        case app, ui, booth, camera, input, storage, config, selftest, printing
    }

    private static let loggers: [Category: Logger] = {
        var d: [Category: Logger] = [:]
        for c in [Category.app, .ui, .booth, .camera, .input, .storage, .config, .selftest, .printing] {
            d[c] = Logger(subsystem: "PhotoBooth", category: c.rawValue)
        }
        return d
    }()

    public static func info(_ c: Category, _ message: String) {
        loggers[c]?.info("\(message, privacy: .public)")
        FileLog.shared.write(level: "INFO", category: c.rawValue, message)
    }

    public static func error(_ c: Category, _ message: String) {
        loggers[c]?.error("\(message, privacy: .public)")
        FileLog.shared.write(level: "ERROR", category: c.rawValue, message)
    }

    static func debug(_ c: Category, _ message: String) {
        loggers[c]?.debug("\(message, privacy: .public)")
    }
}

/// Append-only daily log file. Thread-safe; failures to write are silently ignored
/// (logging must never take the booth down).
public final class FileLog: @unchecked Sendable {
    public static let shared = FileLog()

    private let queue = DispatchQueue(label: "PhotoBooth.FileLog")
    private var directory: URL?
    private var handle: FileHandle?
    private var currentDay: String?
    /// Also echo to stderr (useful in --windowed / --self-test runs from a terminal).
    var echoToStderr = false

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Enable file logging into `dir` (created if needed). Until called, only os.Logger is used.
    public func configure(directory dir: URL) {
        queue.sync {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if directory != dir {
                try? handle?.close()
                handle = nil
                currentDay = nil
            }
            directory = dir
        }
    }

    func write(level: String, category: String, _ message: String) {
        let now = Date()
        queue.async { [self] in
            let line = "\(stampFormatter.string(from: now)) [\(level)] [\(category)] \(message)\n"
            if echoToStderr { FileHandle.standardError.write(Data(line.utf8)) }
            guard let dir = directory else { return }
            let day = dayFormatter.string(from: now)
            if day != currentDay || handle == nil {
                try? handle?.close()
                let url = dir.appendingPathComponent("booth-\(day).log")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
                currentDay = day
            }
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }

    /// Block until queued writes are done (used before exit).
    public func flush() { queue.sync {} }
}
