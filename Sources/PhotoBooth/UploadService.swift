import BoothCore
import Foundation
import Observation
import SonyCamera
import Uploader

/// Owns the persistent Google Photos upload queue for one event folder.
///
/// Uploading is optional: without `google_client.json` in the output root the booth just saves
/// locally. With it but not yet signed in (`PhotoBooth --google-login`), photos queue up and
/// upload once authorized — the queue retries `notAuthorized` every few minutes, or straight
/// away after signing in from the control panel.
///
/// Observable for the control panel: the latest queue snapshot and the sign-in state.
@MainActor
@Observable
final class UploadService {
    let eventDirectory: URL
    let albumTitle: String
    @ObservationIgnored let queue: UploadQueue?
    @ObservationIgnored let auth: GoogleAuth?
    @ObservationIgnored let uploader: GooglePhotosUploader?
    /// Latest queue state (nil until the first report, or when uploads are off).
    private(set) var snapshot: UploadQueueSnapshot?
    /// nil = no google_client.json (uploads off).
    private(set) var signedIn: Bool?
    private(set) var signingIn = false
    var signInError: String?
    /// Signed in with the scope that lets us list the booth's albums.
    private(set) var canListAlbums = false
    /// Albums from Google's last listing (nil until a Refresh succeeds).
    private(set) var remoteAlbums: [RemoteAlbum]?
    /// Albums remembered on this Mac (title -> ID).
    private(set) var localAlbumTitles: [String] = []
    private(set) var refreshingAlbums = false
    var albumsError: String?
    @ObservationIgnored private var watcher: Task<Void, Never>?

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
            self.auth = nil
            uploader = nil
            return
        }
        self.auth = auth
        let stateDir = config.outputRootURL.appendingPathComponent(".upload", isDirectory: true)
        let uploader = GooglePhotosUploader(auth: auth, albumTitle: albumTitle,
                                            stateURL: stateDir.appendingPathComponent("album.json"))
        self.uploader = uploader
        let q = UploadQueue(stateURL: stateDir.appendingPathComponent("queue-\(config.eventFolderName).json"),
                            uploader: uploader)
        queue = q
        signedIn = false
        let folder = eventDirectory
        watcher = Task { [weak self] in
            await self?.refreshAuthState()
            if self?.signedIn == false {
                BoothLog.error(.storage, "Google Photos not signed in — photos will queue until you sign in from the control panel")
            }
            self?.localAlbumTitles = await uploader.knownAlbums().keys.sorted()
            // Catch photos saved but never enqueued (crash between the two), then run.
            await q.reconcile(folder: folder)
            await q.start()
            var last: UploadQueueSnapshot?
            for await s in q.updates() where s != last {
                last = s
                self?.snapshot = s
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

    /// Control panel "Sign in": the same browser flow as `--google-login`, then retries the
    /// queue straight away.
    func signIn() async {
        guard let auth, !signingIn else { return }
        signingIn = true
        signInError = nil
        defer { signingIn = false }
        BoothLog.info(.storage, "Google sign-in started from the control panel")
        do {
            try await auth.authorizeInteractively()
            BoothLog.info(.storage, "Google sign-in succeeded")
        } catch {
            BoothLog.error(.storage, "Google sign-in failed: \(error)")
            signInError = "\(error)"
        }
        await refreshAuthState()
        if signedIn == true {
            await queue?.retryNow()
            if canListAlbums { await refreshAlbums() }
        }
    }

    /// Control panel "Refresh": asks Google for the albums this app created.
    func refreshAlbums() async {
        guard let uploader, !refreshingAlbums else { return }
        refreshingAlbums = true
        albumsError = nil
        defer { refreshingAlbums = false }
        do {
            remoteAlbums = try await uploader.listAppAlbums()
        } catch {
            BoothLog.error(.storage, "Listing albums failed: \(error)")
            albumsError = "\(error)"
        }
        localAlbumTitles = await uploader.knownAlbums().keys.sorted()
        await refreshAuthState()
    }

    /// Reads the sign-in state off the main thread: a Keychain read can block on an access
    /// prompt (e.g. after a rebuild changes the code signature), which must not freeze the booth.
    private func refreshAuthState() async {
        guard let auth else { return }
        let (authorized, canList) = await Task.detached { (auth.isAuthorized, auth.canListAlbums) }.value
        signedIn = authorized
        canListAlbums = canList
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

    /// Local only: a rejected frame is never uploaded.
    func storeRejected(_ photo: CapturedPhoto) async throws -> URL? {
        try await local.storeRejected(photo)
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
