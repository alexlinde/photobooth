import Foundation
@testable import Uploader

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("uploader-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func makeJPEG(in dir: URL, name: String, bytes: Int = 8) -> URL {
    let u = dir.appendingPathComponent(name)
    try! Data(repeating: 0xFF, count: bytes).write(to: u)
    return u
}

func waitUntil(timeout: TimeInterval = 5, _ cond: @escaping () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await cond()
}

final class FakeClock: QueueClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_000_000)
    private var _sleeps: [TimeInterval] = []
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return _now }
    var sleeps: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _sleeps }
    func sleep(seconds: TimeInterval) async throws {
        record(seconds)
        await Task.yield()
    }
    private func record(_ s: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _sleeps.append(s); _now = _now.addingTimeInterval(s)
    }
}

/// Time never advances: sleeps last until cancelled (the queue's wake signal cancels them).
final class StuckClock: QueueClock, @unchecked Sendable {
    func now() -> Date { Date(timeIntervalSince1970: 1_000_000) }
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
}

final class FakePathMonitor: PathMonitoring, @unchecked Sendable {
    private let stream: AsyncStream<Bool>
    private let cont: AsyncStream<Bool>.Continuation
    init() {
        var c: AsyncStream<Bool>.Continuation!
        stream = AsyncStream { c = $0 }
        cont = c
    }
    func updates() -> AsyncStream<Bool> { stream }
    func set(_ online: Bool) { cont.yield(online) }
}

/// Scripted uploader: pops a result per call; records calls.
final class ScriptedUploader: PhotoUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<Void, UploadError>]
    private var _calls: [String] = []
    init(_ script: [Result<Void, UploadError>]) { self.script = script }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func next(_ name: String) -> Result<Void, UploadError> {
        lock.lock(); defer { lock.unlock() }
        _calls.append(name)
        return script.isEmpty ? .success(()) : script.removeFirst()
    }
    func upload(fileURL: URL) async throws {
        try next(fileURL.lastPathComponent).get()
    }
}

final class FakeAuth: AccessTokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _refreshes = 0
    private let failRefresh: Bool
    let canListAlbums: Bool
    init(failRefresh: Bool = false, canListAlbums: Bool = false) {
        self.failRefresh = failRefresh; self.canListAlbums = canListAlbums
    }
    var refreshes: Int { lock.lock(); defer { lock.unlock() }; return _refreshes }
    func accessToken(forceRefresh: Bool) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        if forceRefresh {
            if failRefresh { throw UploadError.notAuthorized }
            _refreshes += 1
        }
        return "tok\(_refreshes)"
    }
}

/// URLProtocol stub keyed by a per-test header so tests can run in parallel.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Req { var url: URL; var method: String = "GET"; var headers: [String: String]; var body: Data }
    struct Resp { var status: Int; var body: Data }
    nonisolated(unsafe) static var handlers: [String: (Req) -> Resp] = [:]
    nonisolated(unsafe) static var requests: [String: [Req]] = [:]
    static let lock = NSLock()

    static func session(id: String, handler: @escaping (Req) -> Resp) -> URLSession {
        lock.lock(); handlers[id] = handler; requests[id] = []; lock.unlock()
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        c.httpAdditionalHeaders = ["X-Test-ID": id]
        return URLSession(configuration: c)
    }
    static func log(_ id: String) -> [Req] { lock.lock(); defer { lock.unlock() }; return requests[id] ?? [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
        }
        var h: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { h[k.lowercased()] = v }
        let id = h["x-test-id"] ?? ""
        let req = Req(url: request.url!, method: request.httpMethod ?? "GET", headers: h, body: body)
        Self.lock.lock()
        Self.requests[id, default: []].append(req)
        let handler = Self.handlers[id]
        Self.lock.unlock()
        let r = handler?(req) ?? Resp(status: 500, body: Data())
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
