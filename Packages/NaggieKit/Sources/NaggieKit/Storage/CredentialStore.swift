import Foundation
import Security

/// Stores server passwords outside naggie.yaml, so they are not lying around in plain text.
public protocol CredentialStore: Sendable {
    func password(for serverID: UUID) throws -> String?
    /// Passing `nil` (or an empty string) removes the stored password.
    func setPassword(_ password: String?, for serverID: UUID) throws
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

public struct KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String = "nl.webhare.naggie.server") {
        self.service = service
    }

    private func baseQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    public func password(for serverID: UUID) throws -> String? {
        var query = baseQuery(serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setPassword(_ password: String?, for serverID: UUID) throws {
        let query = baseQuery(serverID)
        guard let password, !password.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }
}

/// Non-persistent store for tests and previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var passwords: [UUID: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func password(for serverID: UUID) throws -> String? {
        lock.withLock { passwords[serverID] }
    }

    public func setPassword(_ password: String?, for serverID: UUID) throws {
        lock.withLock {
            if let password, !password.isEmpty { passwords[serverID] = password } else { passwords[serverID] = nil }
        }
    }
}
