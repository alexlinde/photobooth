import Foundation
import os

private let log = Logger(subsystem: "PhotoBooth", category: "upload")

public actor GooglePhotosUploader: PhotoUploading {
    private struct State: Codable { var albumId: String?; var albumTitle: String? }

    private let auth: AccessTokenProviding
    private let albumTitle: String
    private let stateURL: URL
    private let session: URLSession
    private var state: State
    private var recreatedAlbum = false

    static func isAlbumGone(_ message: String) -> Bool {
        let m = message.lowercased()
        guard m.contains("album") else { return false }
        if m.contains("permission") || m.contains("insufficient") || m.contains("scope") { return false }
        return m.contains("not found") || m.contains("not_found") || m.contains("http 404") || m.contains("invalid album")
    }

    static let base = "https://photoslibrary.googleapis.com/v1"

    public init(auth: AccessTokenProviding, albumTitle: String, stateURL: URL, session: URLSession = .shared) {
        self.auth = auth
        self.albumTitle = albumTitle
        self.stateURL = stateURL
        self.session = session
        if let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: d) {
            self.state = s
        } else {
            self.state = State()
        }
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
            albumId = try await ensureAlbum()
            try await createMediaItem(token: uploadToken, albumId: albumId, name: fileURL.lastPathComponent)
        }
    }

    // MARK: Steps

    private func ensureAlbum() async throws -> String {
        if let id = state.albumId, state.albumTitle == albumTitle { return id }
        let body = try JSONSerialization.data(withJSONObject: ["album": ["title": albumTitle]])
        let (data, _) = try await send(path: "/albums", contentType: "application/json", body: body)
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = j["id"] as? String else {
            throw UploadError.transient("albums.create returned no id")
        }
        state = State(albumId: id, albumTitle: albumTitle)
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
        var forceRefresh = false
        for attempt in 0..<2 {
            let token = try await auth.accessToken(forceRefresh: forceRefresh)
            var req = URLRequest(url: URL(string: Self.base + path)!)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
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

    private func clearAlbum() { state = State(); saveState() }

    private func saveState() {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            log.error("Failed to save album state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
