import Foundation
import Security

/// Which secret the app stores. The account name is what appears in Keychain Access.
public enum KeyAccount: String, CaseIterable, Sendable {
    case elevenLabs = "elevenlabs"
    case anthropic = "anthropic"

    public var service: DictationError.Service {
        switch self {
        case .elevenLabs: return .elevenLabs
        case .anthropic: return .anthropic
        }
    }
}

public enum KeychainError: Error, Equatable {
    case status(OSStatus)
    case notUTF8
}

/// Generic-password items in the login keychain under one service name.
/// Values are never written anywhere else by this app.
public struct KeychainStore: Sendable {
    public static let appService = "Lavalier"
    public let service: String

    public init(service: String = KeychainStore.appService) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(baseQuery(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Lavalier (\(account))"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func get(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = out as? Data else { return nil }
        guard let s = String(data: data, encoding: .utf8) else { throw KeychainError.notUTF8 }
        return s
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    /// Presence check without decrypting the value (attributes only), so it never triggers a Keychain prompt.
    public func has(account: String) -> Bool {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }

    // Typed helpers
    public func set(_ value: String, for account: KeyAccount) throws { try set(value, account: account.rawValue) }
    public func get(_ account: KeyAccount) throws -> String? { try get(account: account.rawValue) }
    public func delete(_ account: KeyAccount) throws { try delete(account: account.rawValue) }
    public func has(_ account: KeyAccount) -> Bool { has(account: account.rawValue) }
}

/// Where the pipeline gets keys from. The app uses the Keychain; the test harness uses the environment.
public protocol KeyProvider: Sendable {
    func key(for account: KeyAccount) throws -> String
}

public struct KeychainKeyProvider: KeyProvider {
    public let store: KeychainStore
    public init(store: KeychainStore = KeychainStore()) { self.store = store }
    public func key(for account: KeyAccount) throws -> String {
        guard let v = try store.get(account), !v.isEmpty else { throw DictationError.missingKey(account.service) }
        return v
    }
}

/// Reads ELEVENLABS_API_KEY and ANTHROPIC_API_KEY from the process environment. Test harness only.
public struct EnvironmentKeyProvider: KeyProvider {
    public init() {}
    public func key(for account: KeyAccount) throws -> String {
        let name = account == .elevenLabs ? "ELEVENLABS_API_KEY" : "ANTHROPIC_API_KEY"
        guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else {
            throw DictationError.missingKey(account.service)
        }
        return v
    }
}
