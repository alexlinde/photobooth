import Darwin
import Foundation
import SonyCamera

/// Where captured photos go. The local file is the source of truth: `store` must only
/// return once the JPEG is safely on disk.
// TODO(integration): replace `LocalFolderPhotoSink` with the Uploader module's local-save +
// upload-queue implementation (conform it to `PhotoSink`, or wrap it) in `AppBooth.makeSink`.
public protocol PhotoSink: Sendable {
    func store(_ photo: CapturedPhoto) async throws -> URL
    /// A frame the booth threw away (missed flash), kept for diagnostics only: never uploaded,
    /// never listed with the photos. nil = not kept.
    func storeRejected(_ photo: CapturedPhoto) async throws -> URL?
}

public extension PhotoSink {
    func storeRejected(_ photo: CapturedPhoto) async throws -> URL? { nil }
}

/// Interim sink: writes `<eventDirectory>/YYYYMMDD-HHMMSS.jpg` atomically, adding `-2`,
/// `-3`, … on name collisions (never overwrites).
public struct LocalFolderPhotoSink: PhotoSink {
    let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func store(_ photo: CapturedPhoto) async throws -> URL {
        let dir = directory
        return try await Task.detached(priority: .userInitiated) {
            try Self.write(photo, into: dir)
        }.value
    }

    /// `<eventDirectory>/rejected/YYYYMMDD-HHMMSS.jpg`: a subfolder, so the photo listings and the
    /// upload queue (which only look at the event folder's own JPEGs) skip it.
    public func storeRejected(_ photo: CapturedPhoto) async throws -> URL? {
        let dir = directory.appendingPathComponent("rejected", isDirectory: true)
        return try await Task.detached(priority: .utility) {
            try Self.write(photo, into: dir)
        }.value
    }

    static func baseName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    static func write(_ photo: CapturedPhoto, into dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write to a temp file in the same directory, then rename into place exclusively.
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).jpg")
        try photo.jpeg.write(to: tmp, options: .atomic)
        defer { try? fm.removeItem(at: tmp) }
        let base = baseName(for: photo.capturedAt)
        for n in 1...999 {
            let name = n == 1 ? "\(base).jpg" : "\(base)-\(n).jpg"
            let dest = dir.appendingPathComponent(name)
            let rc = tmp.path.withCString { src in
                dest.path.withCString { dst in renamex_np(src, dst, UInt32(RENAME_EXCL)) }
            }
            if rc == 0 { return dest }
            if errno != EEXIST {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSFilePathErrorKey: dest.path,
                    NSLocalizedDescriptionKey: "Could not save \(name): \(String(cString: strerror(errno)))",
                ])
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dir.path])
    }
}
