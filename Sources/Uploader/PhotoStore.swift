import Foundation

/// Local save: the source of truth. Files land in `root/<eventName>/YYYYMMDD-HHMMSS.jpg`.
public struct PhotoStore: Sendable {
    public let root: URL
    public let eventName: String
    private let timeZone: TimeZone

    public init(root: URL, eventName: String, timeZone: TimeZone = .current) {
        self.root = root
        self.eventName = eventName
        self.timeZone = timeZone
    }

    public var eventFolder: URL {
        var name = eventName
        for bad in ["/", ":", "\0"] { name = name.replacingOccurrences(of: bad, with: "-") }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "Event" }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// Writes the JPEG atomically and returns its URL. Adds "-2", "-3"... on name collision.
    @discardableResult
    public func save(jpeg: Data, capturedAt: Date) throws -> URL {
        let fm = FileManager.default
        let folder = eventFolder
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = f.string(from: capturedAt)

        var n = 1
        while true {
            let name = n == 1 ? "\(base).jpg" : "\(base)-\(n).jpg"
            let url = folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) {
                try jpeg.write(to: url, options: .atomic)
                return url
            }
            n += 1
        }
    }
}
