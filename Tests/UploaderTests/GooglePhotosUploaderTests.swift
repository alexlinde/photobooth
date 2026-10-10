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

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func inc() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
