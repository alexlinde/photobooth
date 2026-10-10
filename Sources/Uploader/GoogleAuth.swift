import Foundation
import Network
import AppKit
import os

private let log = Logger(subsystem: "PhotoBooth", category: "upload")

public let photosAppendOnlyScope = "https://www.googleapis.com/auth/photoslibrary.appendonly"

/// What the Photos uploader needs from auth. `GoogleAuth` conforms; tests use a fake.
public protocol AccessTokenProviding: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

struct GoogleClientConfig: Sendable {
    var clientID: String
    var clientSecret: String?
    var authURI: URL
    var tokenURI: URL

    static func load(from url: URL) throws -> GoogleClientConfig {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = (root["installed"] ?? root["web"]) as? [String: Any],
              let id = inner["client_id"] as? String else {
            throw UploadError.permanent("Invalid Google client config JSON at \(url.path)")
        }
        return GoogleClientConfig(
            clientID: id,
            clientSecret: inner["client_secret"] as? String,
            authURI: URL(string: inner["auth_uri"] as? String ?? "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenURI: URL(string: inner["token_uri"] as? String ?? "https://oauth2.googleapis.com/token")!)
    }
}

public final class GoogleAuth: AccessTokenProviding, @unchecked Sendable {
    private let clientConfigURL: URL
    private let store: TokenStore
    private let session: URLSession
    private let lock = NSLock()
    private var cached: (token: String, expiry: Date)?

    public init(clientConfigURL: URL,
                keychainService: String = "com.somefamilies.photobooth.google",
                tokenStore: TokenStore? = nil,
                session: URLSession = .shared) {
        self.clientConfigURL = clientConfigURL
        self.store = tokenStore ?? KeychainTokenStore(service: keychainService)
        self.session = session
    }

    /// True when a refresh token is stored.
    public var isAuthorized: Bool { ((try? store.load()) ?? nil) != nil }

    public func signOut() throws {
        setCached(nil, nil)
        try store.delete()
    }

    private func getCached() -> (token: String, expiry: Date)? {
        lock.lock(); defer { lock.unlock() }; return cached
    }
    private func setCached(_ t: String?, _ expiresIn: TimeInterval?) {
        lock.lock(); defer { lock.unlock() }
        cached = t.map { ($0, Date().addingTimeInterval(expiresIn ?? 3000)) }
    }

    public func accessToken() async throws -> String {
        try await accessToken(forceRefresh: false)
    }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh {
            if let c = getCached(), c.expiry > Date().addingTimeInterval(60) { return c.token }
        }
        guard let refresh = try? store.load() else { throw UploadError.notAuthorized }
        let cfg = try GoogleClientConfig.load(from: clientConfigURL)
        var form = ["client_id": cfg.clientID, "grant_type": "refresh_token", "refresh_token": refresh]
        if let s = cfg.clientSecret { form["client_secret"] = s }
        let resp = try await tokenRequest(cfg.tokenURI, form)
        if resp.error == "invalid_grant" {
            log.error("Refresh token rejected (invalid_grant); clearing")
            try? signOut()
            throw UploadError.notAuthorized
        }
        guard let token = resp.accessToken else {
            let msg = "Token refresh failed: \(resp.error ?? "unknown")"
            if resp.status >= 500 || resp.status == 429 { throw UploadError.transient(msg) }
            throw UploadError.permanent(msg)
        }
        setCached(token, resp.expiresIn)
        return token
    }

    // MARK: Interactive flow

    public func authorizeInteractively() async throws {
        let cfg = try GoogleClientConfig.load(from: clientConfigURL)
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeState()

        let server = LoopbackServer()
        let port = try await server.start()
        defer { server.cancel() }
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(url: cfg.authURI, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "client_id", value: cfg.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: photosAppendOnlyScope),
            .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        let authURL = comps.url!
        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }

        let params = try await server.waitForCallback(timeout: 300)
        if let err = params["error"] { throw UploadError.permanent("Authorization denied: \(err)") }
        guard params["state"] == state else { throw UploadError.permanent("OAuth state mismatch") }
        guard let code = params["code"] else { throw UploadError.permanent("No authorization code returned") }

        var form = ["client_id": cfg.clientID, "code": code, "code_verifier": verifier,
                    "redirect_uri": redirect, "grant_type": "authorization_code"]
        if let s = cfg.clientSecret { form["client_secret"] = s }
        let resp = try await tokenRequest(cfg.tokenURI, form)
        guard let access = resp.accessToken, let refresh = resp.refreshToken else {
            throw UploadError.permanent("Code exchange failed: \(resp.error ?? "no refresh token returned")")
        }
        try store.save(refresh)
        setCached(access, resp.expiresIn)
        log.info("Google authorization complete")
    }

    // MARK: Token endpoint

    struct TokenResponse {
        var status: Int
        var accessToken: String?
        var refreshToken: String?
        var expiresIn: TimeInterval?
        var error: String?
    }

    private func tokenRequest(_ url: URL, _ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        req.httpBody = Data(form.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.sorted().joined(separator: "&").utf8)
        do {
            let (data, r) = try await session.data(for: req)
            let status = (r as? HTTPURLResponse)?.statusCode ?? 0
            let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return TokenResponse(
                status: status,
                accessToken: j["access_token"] as? String,
                refreshToken: j["refresh_token"] as? String,
                expiresIn: (j["expires_in"] as? NSNumber)?.doubleValue,
                error: j["error"] as? String)
        } catch let e as URLError {
            throw UploadError.transient("Network error contacting Google: \(e.localizedDescription)")
        }
    }
}

// MARK: - One-shot loopback HTTP listener

final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PhotoBooth.oauth.loopback")
    private let stream: AsyncStream<[String: String]>
    private let cont: AsyncStream<[String: String]>.Continuation

    init() {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try! NWListener(using: params, on: .any)
        var c: AsyncStream<[String: String]>.Continuation!
        stream = AsyncStream { c = $0 }
        cont = c
    }

    /// Starts listening and returns the ephemeral port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<UInt16, Error>) in
            let once = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resume(_ r: Result<UInt16, Error>) {
                let first = once.withLock { done -> Bool in if done { return false }; done = true; return true }
                if first { k.resume(with: r) }
            }
            listener.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    if let p = self?.listener.port?.rawValue { resume(.success(p)) }
                    else { resume(.failure(UploadError.permanent("Loopback listener has no port"))) }
                case .failed(let e): resume(.failure(UploadError.permanent("Loopback listener failed: \(e)")))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        let stream = self.stream
        return try await withThrowingTaskGroup(of: [String: String].self) { g in
            g.addTask {
                for await p in stream { return p }
                throw UploadError.permanent("Authorization cancelled")
            }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw UploadError.permanent("Timed out waiting for Google authorization")
            }
            defer { g.cancelAll() }
            return try await g.next()!
        }
    }

    func cancel() { listener.cancel(); cont.finish() }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let line = text.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            var params: [String: String] = [:]
            if parts.count >= 2, let c = URLComponents(string: "http://127.0.0.1" + parts[1]) {
                for q in c.queryItems ?? [] { params[q.name] = q.value ?? "" }
            }
            let relevant = params["code"] != nil || params["error"] != nil
            let body = relevant
                ? "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:20vh\"><h2>Photo Booth is connected to Google Photos.</h2><p>You can close this window.</p></body></html>"
                : "Not found"
            let resp = "HTTP/1.1 \(relevant ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if relevant { self.cont.yield(params) }
        }
    }
}
