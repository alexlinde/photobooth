import Foundation
import os

private let log = Logger(subsystem: "PhotoBooth", category: "upload")

/// An album this app created, as reported by `albums.list`.
public struct RemoteAlbum: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var mediaItemsCount: Int?
    public var productUrl: URL?

    public init(id: String, title: String, mediaItemsCount: Int? = nil, productUrl: URL? = nil) {
        self.id = id; self.title = title; self.mediaItemsCount = mediaItemsCount; self.productUrl = productUrl
    }
}

public actor GooglePhotosUploader: PhotoUploading {
    /// Every album this app has created or discovered: title -> album ID. `created` (album ID ->
    /// creation time, only for albums made on this Mac) breaks ties if a listing has two albums
    /// with one title. The pre-map format `{albumId, albumTitle}` is migrated on load.
    private struct State {
        var albums: [String: String] = [:]
        var created: [String: Double] = [:]

        static func load(from url: URL) -> (state: State, migrated: Bool) {
            guard let d = try? Data(contentsOf: url),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (State(), false) }
            if let a = j["albums"] as? [String: String] {
                return (State(albums: a, created: j["created"] as? [String: Double] ?? [:]), false)
            }
            if let id = j["albumId"] as? String, let t = j["albumTitle"] as? String {
                return (State(albums: [t: id]), true)
            }
            return (State(), false)
        }

        var json: [String: Any] { ["albums": albums, "created": created] }
    }

    private let auth: AccessTokenProviding
    private let albumTitle: String
    private let stateURL: URL
    private let session: URLSession
    private var state: State
    private var recreatedAlbum = false
    /// Listing failed for lack of the read scope; don't ask again this run.
    private var listingDenied = false

    static func isAlbumGone(_ message: String) -> Bool {
        let m = message.lowercased()
        guard m.contains("album") else { return false }
        if m.contains("permission") || m.contains("insufficient") || m.contains("scope") { return false }
        return m.contains("not found") || m.contains("not_found") || m.contains("http 404") || m.contains("invalid album")
    }

    /// A 403 caused by a missing OAuth scope (as opposed to any other refusal).
    static func isScopeDenied(_ message: String) -> Bool {
        let m = message.lowercased()
        guard m.hasPrefix("http 403") else { return false }
        return m.contains("insufficient") || m.contains("permission_denied") || m.contains("scope")
    }

    static let base = "https://photoslibrary.googleapis.com/v1"

    public init(auth: AccessTokenProviding, albumTitle: String, stateURL: URL, session: URLSession = .shared) {
        self.auth = auth
        self.albumTitle = albumTitle
        self.stateURL = stateURL
        self.session = session
        let (s, migrated) = State.load(from: stateURL)
        self.state = s
        if migrated { Self.write(s, to: stateURL) }
    }

    /// Albums remembered on this Mac (title -> album ID), without asking Google.
    public func knownAlbums() -> [String: String] { state.albums }

    /// Lists the albums this app created (needs the `readonly.appcreateddata` scope) and merges
    /// them into the remembered set: Google is authoritative for IDs, and unknown titles are added.
    public func listAppAlbums() async throws -> [RemoteAlbum] {
        var out: [RemoteAlbum] = []
        var pageToken: String?
        for _ in 0..<100 {
            var comps = URLComponents(string: Self.base + "/albums")!
            comps.queryItems = [.init(name: "pageSize", value: "50")]
                + (pageToken.map { [.init(name: "pageToken", value: $0)] } ?? [])
            let data: Data
            do { (data, _) = try await send(url: comps.url!, method: "GET") }
            catch UploadError.permanent(let msg) where Self.isScopeDenied(msg) {
                listingDenied = true
                throw UploadError.permanent(msg)
            }
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UploadError.transient("albums.list returned invalid JSON")
            }
            for a in j["albums"] as? [[String: Any]] ?? [] {
                guard let id = a["id"] as? String, let title = a["title"] as? String else { continue }
                let count = (a["mediaItemsCount"] as? String).flatMap(Int.init) ?? (a["mediaItemsCount"] as? NSNumber)?.intValue
                out.append(RemoteAlbum(id: id, title: title, mediaItemsCount: count,
                                       productUrl: (a["productUrl"] as? String).flatMap(URL.init(string:))))
            }
            guard let next = j["nextPageToken"] as? String, !next.isEmpty else { break }
            pageToken = next
        }
        merge(out)
        return out
    }

    private func merge(_ remote: [RemoteAlbum]) {
        var byTitle: [String: [String]] = [:]
        for a in remote { byTitle[a.title, default: []].append(a.id) }
        for (title, ids) in byTitle {
            if let known = state.albums[title], ids.contains(known) { continue }
            // Same title twice and neither remembered: newest known creation time, else the last listed.
            state.albums[title] = ids.dropFirst().reduce(ids[0]) { best, id in
                (state.created[id] ?? 0) >= (state.created[best] ?? 0) ? id : best
            }
        }
        saveState()
    }

    public func upload(fileURL: URL) async throws {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw UploadError.permanent("Cannot read \(fileURL.lastPathComponent): \(error.localizedDescription)") }

        var albumId = try await ensureAlbum()
        let uploadToken = try await uploadBytes(data)
        do {
            try await createMediaItem(token: uploadToken, albumId: albumId, name: fileURL.lastPathComponent)
        } catch UploadError.permanent(let msg) where !recreatedAlbum && Self.isAlbumGone(msg) {
            // Only for a missing album, and at most once per run: a permission/scope error that
            // merely mentions "album" must not spawn a new album for every photo.
            log.error("Album not found; recreating once")
            recreatedAlbum = true
            clearAlbum()
            albumId = try await ensureAlbum(listFirst: false)
            try await createMediaItem(token: uploadToken, albumId: albumId, name: fileURL.lastPathComponent)
        }
    }

    // MARK: Steps

    private func ensureAlbum(listFirst: Bool = true) async throws -> String {
        if let id = state.albums[albumTitle] { return id }
        // Another Mac may already have made this album: look before creating a duplicate.
        if listFirst, auth.canListAlbums, !listingDenied {
            do { _ = try await listAppAlbums() }
            catch UploadError.permanent(let msg) where Self.isScopeDenied(msg) {
                log.info("Album listing not permitted (scope not granted); creating the album")
            }
            if let id = state.albums[albumTitle] { return id }
        }
        let body = try JSONSerialization.data(withJSONObject: ["album": ["title": albumTitle]])
        let (data, _) = try await send(path: "/albums", contentType: "application/json", body: body)
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = j["id"] as? String else {
            throw UploadError.transient("albums.create returned no id")
        }
        state.albums[albumTitle] = id
        state.created[id] = Date().timeIntervalSince1970
        saveState()
        log.info("Created album")
        return id
    }

    private func uploadBytes(_ bytes: Data) async throws -> String {
        let (data, _) = try await send(path: "/uploads", contentType: "application/octet-stream", body: bytes,
                                       extra: ["X-Goog-Upload-Content-Type": "image/jpeg",
                                               "X-Goog-Upload-Protocol": "raw"])
        guard let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { throw UploadError.transient("Empty upload token") }
        return t
    }

    private func createMediaItem(token: String, albumId: String, name: String) async throws {
        let payload: [String: Any] = [
            "albumId": albumId,
            "newMediaItems": [["description": "",
                               "simpleMediaItem": ["uploadToken": token, "fileName": name]]],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await send(path: "/mediaItems:batchCreate", contentType: "application/json", body: body)
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = j["newMediaItemResults"] as? [[String: Any]], let first = results.first else {
            throw UploadError.transient("batchCreate returned no results")
        }
        if let st = first["status"] as? [String: Any] {
            let code = (st["code"] as? NSNumber)?.intValue ?? 0
            let msg = st["message"] as? String ?? ""
            if code != 0 {
                let text = "batchCreate item failed (code \(code)): \(msg)"
                if [2, 4, 8, 10, 13, 14].contains(code) { throw UploadError.transient(text) }
                throw UploadError.permanent(text)
            }
        }
    }

    // MARK: HTTP

    private func send(path: String, contentType: String, body: Data,
                      extra: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        try await send(url: URL(string: Self.base + path)!, method: "POST", contentType: contentType, body: body, extra: extra)
    }

    private func send(url: URL, method: String, contentType: String? = nil, body: Data? = nil,
                      extra: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var forceRefresh = false
        for attempt in 0..<2 {
            let token = try await auth.accessToken(forceRefresh: forceRefresh)
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.httpBody = body
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            for (k, v) in extra { req.setValue(v, forHTTPHeaderField: k) }

            let data: Data, resp: HTTPURLResponse
            do {
                let (d, r) = try await session.data(for: req)
                guard let h = r as? HTTPURLResponse else { throw UploadError.transient("Non-HTTP response") }
                data = d; resp = h
            } catch let e as URLError {
                if e.code == .cancelled { throw CancellationError() }
                throw UploadError.transient("Network error: \(e.localizedDescription)")
            }
            switch resp.statusCode {
            case 200..<300: return (data, resp)
            case 401:
                if attempt == 0 { forceRefresh = true; continue }
                throw UploadError.notAuthorized
            case 429, 500..<600:
                throw UploadError.transient("HTTP \(resp.statusCode): \(snippet(data))")
            default:
                throw UploadError.permanent("HTTP \(resp.statusCode): \(snippet(data))")
            }
        }
        throw UploadError.notAuthorized
    }

    private func snippet(_ d: Data) -> String {
        String((String(data: d, encoding: .utf8) ?? "").prefix(300))
    }

    /// Forgets the configured title's album (the others stay remembered).
    private func clearAlbum() { state.albums[albumTitle] = nil; saveState() }

    private func saveState() { Self.write(state, to: stateURL) }

    private static func write(_ state: State, to stateURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: state.json, options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        } catch {
            log.error("Failed to save album state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
