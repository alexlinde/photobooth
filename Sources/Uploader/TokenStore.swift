import Foundation
import Security

/// Storage for the long-lived refresh token.
public protocol TokenStore: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    public init(token: String? = nil) { self.token = token }
    public func load() throws -> String? { lock.lock(); defer { lock.unlock() }; return token }
    public func save(_ t: String) throws { lock.lock(); token = t; lock.unlock() }
    public func delete() throws { lock.lock(); token = nil; lock.unlock() }
}

public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String
    public init(service: String, account: String = "refresh_token") {
        self.service = service; self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let d = out as? Data else { throw keychainError(st) }
        return String(data: d, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        let st = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecSuccess { return }
        guard st == errSecItemNotFound else { throw keychainError(st) }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let a = SecItemAdd(add as CFDictionary, nil)
        guard a == errSecSuccess else { throw keychainError(a) }
    }

    public func delete() throws {
        let st = SecItemDelete(baseQuery as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw keychainError(st) }
    }

    private func keychainError(_ st: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(st),
                userInfo: [NSLocalizedDescriptionKey: "Keychain error \(st)"])
    }
}
