import Foundation
#if canImport(Security)
import Security
#endif

/// Stores server passwords outside polly.yaml, so they are not lying around in plain text.
public protocol CredentialStore: Sendable {
    func password(for serverID: UUID) throws -> String?
    /// Passing `nil` (or an empty string) removes the stored password.
    func setPassword(_ password: String?, for serverID: UUID) throws
    /// Like `setPassword(_:for:)`; `synchronizable` keeps it in iCloud Keychain, so the user's other devices have it.
    func setPassword(_ password: String?, for serverID: UUID, synchronizable: Bool) throws
    /// Moves a stored password into or out of iCloud Keychain; does nothing when it is already there or missing.
    func setSynchronizable(_ synchronizable: Bool, for serverID: UUID) throws
}

public extension CredentialStore {
    func setPassword(_ password: String?, for serverID: UUID, synchronizable: Bool) throws {
        try setPassword(password, for: serverID)
    }

    func setSynchronizable(_ synchronizable: Bool, for serverID: UUID) throws {}
}

#if canImport(Security)
public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Passwords in the keychain. A synchronizable password lives in iCloud Keychain, which on macOS is the data
/// protection keychain; the others stay in the keychain of this device. Reading looks in both, so switching sync
/// off or on never loses a password.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String = "nl.webhare.polly.server") {
        self.service = service
    }

    private func query(_ id: UUID, synchronizable: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// The build has no keychain access group (no provisioning profile, such as an ad-hoc signed build), so it
    /// can't use iCloud Keychain.
    private static func unavailable(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == errSecNotAvailable
    }

    private func read(_ id: UUID, synchronizable: Bool) throws -> String? {
        var query = query(id, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound || (synchronizable && Self.unavailable(status)) { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Writes the password in one place; returns the status, so a missing iCloud Keychain can fall back.
    private func write(_ data: Data, _ id: UUID, synchronizable: Bool) -> OSStatus {
        let query = query(id, synchronizable: synchronizable)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    private func remove(_ id: UUID, synchronizable: Bool) throws {
        let status = SecItemDelete(query(id, synchronizable: synchronizable) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || (synchronizable && Self.unavailable(status)) else {
            throw KeychainError(status: status)
        }
    }

    public func password(for serverID: UUID) throws -> String? {
        try read(serverID, synchronizable: true) ?? read(serverID, synchronizable: false)
    }

    public func setPassword(_ password: String?, for serverID: UUID) throws {
        try setPassword(password, for: serverID, synchronizable: false)
    }

    public func setPassword(_ password: String?, for serverID: UUID, synchronizable: Bool) throws {
        guard let password, !password.isEmpty else {
            try remove(serverID, synchronizable: true)
            try remove(serverID, synchronizable: false)
            return
        }
        let data = Data(password.utf8)
        var stored = synchronizable
        var status = write(data, serverID, synchronizable: synchronizable)
        if synchronizable, Self.unavailable(status) {
            stored = false
            status = write(data, serverID, synchronizable: false)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        // Only one copy, so a later change can't leave an old password behind in the other place.
        try remove(serverID, synchronizable: !stored)
    }

    public func setSynchronizable(_ synchronizable: Bool, for serverID: UUID) throws {
        guard try read(serverID, synchronizable: synchronizable) == nil,
              let password = try read(serverID, synchronizable: !synchronizable) else { return }
        try setPassword(password, for: serverID, synchronizable: synchronizable)
    }
}

#endif

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
