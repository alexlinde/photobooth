import Testing
import Foundation
@testable import Uploader

struct GooglePhotosUploaderTests {
    func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }
    let okItem: [String: Any] = ["newMediaItemResults": [["status": ["message": "Success"], "uploadToken": "x"]]]

    func setup(id: String = UUID().uuidString, auth: FakeAuth = FakeAuth(),
               handler: @escaping (StubProtocol.Req) -> StubProtocol.Resp)
        -> (GooglePhotosUploader, URL, String, URL) {
        let dir = tempDir()
        let session = StubProtocol.session(id: id, handler: handler)
        let state = dir.appendingPathComponent("album.json")
        let up = GooglePhotosUploader(auth: auth, albumTitle: "Party", stateURL: state, session: session)
        return (up, makeJPEG(in: dir, name: "20260101-120000.jpg"), id, state)
    }

    @Test func happyPathCreatesAlbumOnce() async throws {
        let counter = Counter()
        let (up, file, id, state) = setup { r in
            switch r.url.path {
            case "/v1/albums": return .init(status: 200, body: self.json(["id": "ALB1"]))
            case "/v1/uploads": return .init(status: 200, body: Data("TOKEN".utf8))
            default: counter.inc(); return .init(status: 200, body: self.json(self.okItem))
            }
        }
        try await up.upload(fileURL: file)
        try await up.upload(fileURL: file)
        let log = StubProtocol.log(id)
        #expect(log.filter { $0.url.path == "/v1/albums" }.count == 1)
        let upload = log.first { $0.url.path == "/v1/uploads" }!
        #expect(upload.headers["x-goog-upload-protocol"] == "raw")
        #expect(upload.headers["x-goog-upload-content-type"] == "image/jpeg")
        #expect(upload.headers["authorization"] == "Bearer tok0")
        #expect(upload.body.count == 8)
        let create = log.first { $0.url.path == "/v1/mediaItems:batchCreate" }!
        let j = try JSONSerialization.jsonObject(with: create.body) as! [String: Any]
        #expect(j["albumId"] as? String == "ALB1")
        let item = (j["newMediaItems"] as! [[String: Any]])[0]["simpleMediaItem"] as! [String: Any]
        #expect(item["uploadToken"] as? String == "TOKEN" && item["fileName"] as? String == "20260101-120000.jpg")
        // album id persisted and reused by a fresh instance
        let up2 = GooglePhotosUploader(auth: FakeAuth(), albumTitle: "Party", stateURL: state,
                                       session: StubProtocol.session(id: id) { _ in
                                           .init(status: 200, body: self.json(self.okItem)) })
        _ = up2
        #expect(counter.value == 2)
    }

    @Test func refreshOn401ThenRetry() async throws {
        let auth = FakeAuth()
        let hits = Counter()
        let (up, file, _, _) = setup(auth: auth) { r in
            switch r.url.path {
            case "/v1/albums": return .init(status: 200, body: self.json(["id": "A"]))
            case "/v1/uploads":
                if r.headers["authorization"] == "Bearer tok0" { hits.inc(); return .init(status: 401, body: Data()) }
                return .init(status: 200, body: Data("T".utf8))
            default: return .init(status: 200, body: self.json(self.okItem))
            }
        }
        try await up.upload(fileURL: file)
        #expect(hits.value == 1 && auth.refreshes == 1)
    }

    @Test func persistent401IsNotAuthorized() async throws {
        let (up, file, _, _) = setup { r in
            r.url.path == "/v1/albums" ? .init(status: 200, body: self.json(["id": "A"])) : .init(status: 401, body: Data())
        }
        await #expect(throws: UploadError.notAuthorized) { try await up.upload(fileURL: file) }
    }

    @Test func statusMapping() async throws {
        for (status, transient) in [(429, true), (500, true), (503, true), (400, false), (403, false)] {
            let (up, file, _, _) = setup { r in
                r.url.path == "/v1/albums" ? .init(status: 200, body: self.json(["id": "A"]))
                    : .init(status: status, body: Data("nope".utf8))
            }
            do { try await up.upload(fileURL: file); Issue.record("expected throw") }
            catch let e as UploadError {
                switch e {
                case .transient: #expect(transient, "status \(status)")
                case .permanent(let m): #expect(!transient && m.contains("nope"), "status \(status)")
                default: Issue.record("unexpected \(e)")
                }
            }
        }
    }

    @Test func albumMissingRecreatesOnce() async throws {
        let albums = Counter()
        let creates = Counter()
        let (up, file, _, _) = setup { r in
            switch r.url.path {
            case "/v1/albums":
                albums.inc()
                return .init(status: 200, body: self.json(["id": "A\(albums.value)"]))
            case "/v1/uploads": return .init(status: 200, body: Data("T".utf8))
            default:
                creates.inc()
                if creates.value == 1 {
                    return .init(status: 400, body: Data("Request contains an invalid album ID".utf8))
                }
                return .init(status: 200, body: self.json(self.okItem))
            }
        }
        try await up.upload(fileURL: file)
        #expect(albums.value == 2 && creates.value == 2)
    }

    @Test func albumPermissionErrorDoesNotRecreate() async throws {
        let albums = Counter()
        let (up, file, _, _) = setup { r in
            switch r.url.path {
            case "/v1/albums":
                albums.inc()
                return .init(status: 200, body: self.json(["id": "A"]))
            case "/v1/uploads": return .init(status: 200, body: Data("T".utf8))
            default:
                return .init(status: 403, body: Data("PERMISSION_DENIED: insufficient scopes to add to album".utf8))
            }
        }
        await #expect(throws: UploadError.self) { try await up.upload(fileURL: file) }
        #expect(albums.value == 1)
    }

    @Test func albumMissingTwiceFails() async throws {
        let (up, file, id, _) = setup { r in
            switch r.url.path {
            case "/v1/albums": return .init(status: 200, body: self.json(["id": "A"]))
            case "/v1/uploads": return .init(status: 200, body: Data("T".utf8))
            default: return .init(status: 404, body: Data("album not found".utf8))
            }
        }
        await #expect(throws: UploadError.self) { try await up.upload(fileURL: file) }
        #expect(StubProtocol.log(id).filter { $0.url.path.hasSuffix("batchCreate") }.count == 2)
    }

    @Test func perItemFailureStatus() async throws {
        let (up, file, _, _) = setup { r in
            switch r.url.path {
            case "/v1/albums": return .init(status: 200, body: self.json(["id": "A"]))
            case "/v1/uploads": return .init(status: 200, body: Data("T".utf8))
            default: return .init(status: 200, body: self.json(
                ["newMediaItemResults": [["status": ["code": 3, "message": "bad media"]]]]))
            }
        }
        do { try await up.upload(fileURL: file); Issue.record("expected throw") }
        catch UploadError.permanent(let m) { #expect(m.contains("bad media")) }
    }
}

struct AlbumStateTests {
    func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }
    let okItem: [String: Any] = ["newMediaItemResults": [["status": ["message": "Success"], "uploadToken": "x"]]]

    func makeUploader(title: String, state: URL, canList: Bool = false, id: String = UUID().uuidString,
                      handler: @escaping (StubProtocol.Req) -> StubProtocol.Resp) -> (GooglePhotosUploader, String) {
        (GooglePhotosUploader(auth: FakeAuth(canListAlbums: canList), albumTitle: title, stateURL: state,
                              session: StubProtocol.session(id: id, handler: handler)), id)
    }

    func savedAlbums(_ url: URL) -> [String: String] {
        let j = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return j["albums"] as! [String: String]
    }

    @Test func migratesOldSingleAlbumFile() async throws {
        let dir = tempDir()
        let state = dir.appendingPathComponent("album.json")
        try json(["albumId": "OLD", "albumTitle": "Party"]).write(to: state)
        let (up, id) = makeUploader(title: "Party", state: state) { r in
            r.url.path == "/v1/uploads" ? .init(status: 200, body: Data("T".utf8)) : .init(status: 200, body: self.json(self.okItem))
        }
        #expect(await up.knownAlbums() == ["Party": "OLD"])
        #expect(savedAlbums(state) == ["Party": "OLD"])  // rewritten in the new format
        try await up.upload(fileURL: makeJPEG(in: dir, name: "a.jpg"))
        let log = StubProtocol.log(id)
        #expect(!log.contains { $0.url.path == "/v1/albums" })
        let j = try JSONSerialization.jsonObject(with: log.first { $0.url.path.hasSuffix("batchCreate") }!.body) as! [String: Any]
        #expect(j["albumId"] as? String == "OLD")
    }

    @Test func switchingTitlesBackAndForthReusesAlbums() async throws {
        let dir = tempDir()
        let state = dir.appendingPathComponent("album.json")
        let file = makeJPEG(in: dir, name: "a.jpg")
        let n = Counter()
        let id = UUID().uuidString
        func up(_ title: String) -> GooglePhotosUploader {
            makeUploader(title: title, state: state, id: id) { r in
                switch r.url.path {
                case "/v1/albums": n.inc(); return .init(status: 200, body: self.json(["id": "ID-\(title)"]))
                case "/v1/uploads": return .init(status: 200, body: Data("T".utf8))
                default: return .init(status: 200, body: self.json(self.okItem))
                }
            }.0
        }
        for t in ["A", "B", "A", "B", "A"] { try await up(t).upload(fileURL: file) }
        #expect(n.value == 2)
        #expect(savedAlbums(state) == ["A": "ID-A", "B": "ID-B"])
    }

    func listing(_ pages: [[String: Any]]) -> (StubProtocol.Req) -> StubProtocol.Resp {
        { r in
            guard r.url.path == "/v1/albums", r.method == "GET" else {
                return r.url.path == "/v1/uploads" ? .init(status: 200, body: Data("T".utf8))
                    : r.url.path == "/v1/albums" ? .init(status: 200, body: self.json(["id": "CREATED"]))
                    : .init(status: 200, body: self.json(self.okItem))
            }
            let token = URLComponents(url: r.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "pageToken" }?.value
            return .init(status: 200, body: self.json(pages[token.flatMap(Int.init) ?? 0]))
        }
    }

    @Test func listsAlbumsWithPaginationAndMerges() async throws {
        let state = tempDir().appendingPathComponent("album.json")
        let (up, id) = makeUploader(title: "Party", state: state, canList: true, handler: listing([
            ["albums": [["id": "1", "title": "Party", "mediaItemsCount": "12", "productUrl": "https://photos.google.com/a1"]],
             "nextPageToken": "1"],
            ["albums": [["id": "2", "title": "Wedding", "productUrl": "https://photos.google.com/a2"]]],
        ]))
        let albums = try await up.listAppAlbums()
        #expect(albums.map(\.id) == ["1", "2"])
        #expect(albums[0].mediaItemsCount == 12 && albums[1].mediaItemsCount == nil)
        #expect(albums[1].productUrl?.absoluteString == "https://photos.google.com/a2")
        let reqs = StubProtocol.log(id)
        #expect(reqs.count == 2 && reqs.allSatisfy { $0.method == "GET" })
        #expect(reqs[0].url.query?.contains("pageSize=50") == true)
        #expect(reqs[1].url.query?.contains("pageToken=1") == true)
        #expect(await up.knownAlbums() == ["Party": "1", "Wedding": "2"])
        #expect(savedAlbums(state) == ["Party": "1", "Wedding": "2"])
    }

    @Test func remoteIdReplacesLocalOne() async throws {
        let state = tempDir().appendingPathComponent("album.json")
        try json(["albums": ["Party": "STALE"]]).write(to: state)
        let (up, _) = makeUploader(title: "Party", state: state, canList: true, handler: listing([
            ["albums": [["id": "REAL", "title": "Party"]]]]))
        _ = try await up.listAppAlbums()
        #expect(await up.knownAlbums() == ["Party": "REAL"])
    }

    @Test func ensureAlbumFindsRemoteAlbumInsteadOfCreating() async throws {
        let dir = tempDir()
        let state = dir.appendingPathComponent("album.json")
        let (up, id) = makeUploader(title: "Party", state: state, canList: true, handler: listing([
            ["albums": [["id": "OTHERMAC", "title": "Party"]]]]))
        try await up.upload(fileURL: makeJPEG(in: dir, name: "a.jpg"))
        let log = StubProtocol.log(id)
        #expect(!log.contains { $0.method == "POST" && $0.url.path == "/v1/albums" })
        let j = try JSONSerialization.jsonObject(with: log.first { $0.url.path.hasSuffix("batchCreate") }!.body) as! [String: Any]
        #expect(j["albumId"] as? String == "OTHERMAC")
    }

    @Test func listing403FallsBackToCreate() async throws {
        let dir = tempDir()
        let state = dir.appendingPathComponent("album.json")
        let file = makeJPEG(in: dir, name: "a.jpg")
        let (up, id) = makeUploader(title: "Party", state: state, canList: true) { r in
            switch (r.method, r.url.path) {
            case ("GET", "/v1/albums"):
                return .init(status: 403, body: Data(#"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED"}}"#.utf8))
            case ("POST", "/v1/albums"): return .init(status: 200, body: self.json(["id": "NEW"]))
            case (_, "/v1/uploads"): return .init(status: 200, body: Data("T".utf8))
            default: return .init(status: 200, body: self.json(self.okItem))
            }
        }
        try await up.upload(fileURL: file)
        #expect(await up.knownAlbums() == ["Party": "NEW"])
        let log = StubProtocol.log(id)
        #expect(log.filter { $0.method == "GET" }.count == 1)
        #expect(log.filter { $0.method == "POST" && $0.url.path == "/v1/albums" }.count == 1)
    }

    @Test func goneAlbumIsRecreatedAndMapUpdated() async throws {
        let dir = tempDir()
        let state = dir.appendingPathComponent("album.json")
        try json(["albums": ["Party": "DEAD", "Other": "KEEP"]]).write(to: state)
        let creates = Counter()
        let (up, _) = makeUploader(title: "Party", state: state) { r in
            switch r.url.path {
            case "/v1/albums": return .init(status: 200, body: self.json(["id": "FRESH"]))
            case "/v1/uploads": return .init(status: 200, body: Data("T".utf8))
            default:
                creates.inc()
                return creates.value == 1 ? .init(status: 400, body: Data("Request contains an invalid album ID".utf8))
                    : .init(status: 200, body: self.json(self.okItem))
            }
        }
        try await up.upload(fileURL: makeJPEG(in: dir, name: "a.jpg"))
        #expect(savedAlbums(state) == ["Party": "FRESH", "Other": "KEEP"])
    }
}

struct GoogleAuthScopeTests {
    func setup(refreshScope: String?) throws -> (GoogleAuth, InMemoryTokenStore) {
        let dir = tempDir()
        let cfg = dir.appendingPathComponent("google_client.json")
        try Data(#"{"installed":{"client_id":"cid","token_uri":"https://oauth.test/token"}}"#.utf8).write(to: cfg)
        let store = InMemoryTokenStore(token: "refresh", scopes: nil)
        var body: [String: Any] = ["access_token": "acc", "expires_in": 3600]
        if let refreshScope { body["scope"] = refreshScope }
        let session = StubProtocol.session(id: UUID().uuidString) { _ in
            .init(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
        }
        return (GoogleAuth(clientConfigURL: cfg, tokenStore: store, session: session), store)
    }

    @Test func refreshRecordsScope() async throws {
        let (auth, _) = try setup(refreshScope: "\(photosAppendOnlyScope) \(photosReadAppCreatedScope)")
        #expect(!auth.canListAlbums && auth.grantedScopes.isEmpty)
        _ = try await auth.accessToken(forceRefresh: true)
        #expect(auth.canListAlbums)
        #expect(auth.grantedScopes == [photosAppendOnlyScope, photosReadAppCreatedScope])
    }

    @Test func appendOnlyScopeCannotList() async throws {
        let (auth, _) = try setup(refreshScope: photosAppendOnlyScope)
        _ = try await auth.accessToken(forceRefresh: true)
        #expect(!auth.canListAlbums && auth.grantedScopes == [photosAppendOnlyScope])
    }

    @Test func refreshWithoutScopeKeepsPreviousValue() async throws {
        let (auth, store) = try setup(refreshScope: nil)
        try store.saveScopes("\(photosAppendOnlyScope) \(photosReadAppCreatedScope)")
        _ = try await auth.accessToken(forceRefresh: true)
        #expect(auth.canListAlbums)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func inc() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
