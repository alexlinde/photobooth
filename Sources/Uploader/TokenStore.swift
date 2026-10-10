import Foundation
import Security

/// Storage for the long-lived refresh token.
public protocol TokenStore: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
    /// Space-separated scopes Google reported for this sign-in (nil = unknown). Passing nil clears it.
    func loadScopes() throws -> String?
    func saveScopes(_ scopes: String?) throws
}

public extension TokenStore {
    func loadScopes() throws -> String? { nil }
    func saveScopes(_ scopes: String?) throws {}
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var scopes: String?
    public init(token: String? = nil, scopes: String? = nil) { self.token = token; self.scopes = scopes }
    public func loadScopes() throws -> String? { lock.lock(); defer { lock.unlock() }; return scopes }
    public func saveScopes(_ s: String?) throws { lock.lock(); scopes = s; lock.unlock() }
    public func load() throws -> String? { lock.lock(); defer { lock.unlock() }; return token }
    public func save(_ t: String) throws { lock.lock(); token = t; lock.unlock() }
    public func delete() throws { lock.lock(); token = nil; lock.unlock() }
}

public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String
    public let scopeAccount: String
    public init(service: String, account: String = "refresh_token", scopeAccount: String = "granted_scope") {
        self.service = service; self.account = account; self.scopeAccount = scopeAccount
    }

    public func load() throws -> String? { try load(account: account) }
    public func save(_ token: String) throws { try save(token, account: account) }
    public func delete() throws { try delete(account: account); try delete(account: scopeAccount) }
    public func loadScopes() throws -> String? { try load(account: scopeAccount) }
    public func saveScopes(_ scopes: String?) throws {
        if let scopes { try save(scopes, account: scopeAccount) } else { try delete(account: scopeAccount) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func load(account: String) throws -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let d = out as? Data else { throw keychainError(st) }
        return String(data: d, encoding: .utf8)
    }

    private func save(_ token: String, account: String) throws {
        let data = Data(token.utf8)
        let st = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecSuccess { return }
        guard st == errSecItemNotFound else { throw keychainError(st) }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let a = SecItemAdd(add as CFDictionary, nil)
        guard a == errSecSuccess else { throw keychainError(a) }
    }

    private func delete(account: String) throws {
        let st = SecItemDelete(baseQuery(account) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw keychainError(st) }
    }

    private func keychainError(_ st: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(st),
                userInfo: [NSLocalizedDescriptionKey: "Keychain error \(st)"])
    }
}
