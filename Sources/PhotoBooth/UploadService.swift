import BoothCore
import Foundation
import SonyCamera
import Uploader

/// Owns the persistent Google Photos upload queue for one event folder.
///
/// Uploading is optional: without `google_client.json` in the output root the booth just saves
/// locally. With it but not yet signed in (`PhotoBooth --google-login`), photos queue up and
/// upload once authorized — the queue retries `notAuthorized` every few minutes.
@MainActor
final class UploadService {
    let eventDirectory: URL
    let albumTitle: String
    let queue: UploadQueue?
    private var watcher: Task<Void, Never>?

    static func clientConfigURL(_ config: BoothConfig) -> URL {
        config.outputRootURL.appendingPathComponent("google_client.json")
    }

    static func makeAuth(_ config: BoothConfig) -> GoogleAuth? {
        let url = clientConfigURL(config)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return GoogleAuth(clientConfigURL: url)
    }

    init(config: BoothConfig) {
        eventDirectory = config.eventDirectoryURL
        albumTitle = config.albumName
        guard let auth = Self.makeAuth(config) else {
            BoothLog.info(.storage, "No \(Self.clientConfigURL(config).path); Google Photos upload disabled (local save only)")
            queue = nil
            return
        }
        if !auth.isAuthorized {
            BoothLog.error(.storage, "Google Photos not signed in — photos will queue until you run `PhotoBooth --google-login`")
        }
        let stateDir = config.outputRootURL.appendingPathComponent(".upload", isDirectory: true)
        let uploader = GooglePhotosUploader(auth: auth, albumTitle: albumTitle,
                                            stateURL: stateDir.appendingPathComponent("album.json"))
        let q = UploadQueue(stateURL: stateDir.appendingPathComponent("queue-\(config.eventFolderName).json"),
                            uploader: uploader)
        queue = q
        let folder = eventDirectory
        watcher = Task {
            // Catch photos saved but never enqueued (crash between the two), then run.
            await q.reconcile(folder: folder)
            await q.start()
            var last: UploadQueueSnapshot?
            for await s in q.updates() where s != last {
                last = s
                BoothLog.info(.storage, "Uploads: \(s.uploaded) done, \(s.pending) pending, \(s.inFlight) in flight, "
                    + "\(s.failedPermanently) failed\(s.isPausedOffline ? ", offline" : "")"
                    + (s.lastError.map { " — last error: \($0)" } ?? ""))
            }
        }
    }

    func matches(_ config: BoothConfig) -> Bool {
        config.eventDirectoryURL == eventDirectory && config.albumName == albumTitle
            && (queue != nil) == FileManager.default.fileExists(atPath: Self.clientConfigURL(config).path)
    }

    func stop() {
        watcher?.cancel()
        if let queue { Task { await queue.stop() } }
    }
}

/// Saves locally first (the source of truth), then hands the file to the upload queue.
struct UploadingPhotoSink: PhotoSink {
    let local: LocalFolderPhotoSink
    let queue: UploadQueue?

    func store(_ photo: CapturedPhoto) async throws -> URL {
        let url = try await local.store(photo)
        if let queue { await queue.enqueue(url) }
        return url
    }
}

/// `PhotoBooth --google-login`: one-time interactive sign-in; stores the refresh token in Keychain.
enum GoogleLogin {
    @MainActor
    static func run(configPath: String?) async -> Int32 {
        let (config, error) = ConfigLoader.load(path: configPath)
        if let error { print("config: \(error.description) (continuing with defaults)") }
        guard let auth = UploadService.makeAuth(config) else {
            print("""
            Missing \(UploadService.clientConfigURL(config).path).
            Create a Desktop-app OAuth client in Google Cloud Console and save its JSON there (see README).
            """)
            return 1
        }
        print("Opening your browser to sign in to Google Photos…")
        do {
            try await auth.authorizeInteractively()
            print("Signed in. Uploads will go to the album \"\(config.albumName)\".")
            return 0
        } catch {
            print("Sign-in failed: \(error)")
            return 1
        }
    }
}
