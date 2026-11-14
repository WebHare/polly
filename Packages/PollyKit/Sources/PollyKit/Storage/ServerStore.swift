import Foundation

/// Persists servers and settings in a single YAML file (see `SettingsFile`). Passwords go either to a
/// `CredentialStore` (the keychain) or into that file, depending on `passwordStorage`.
///
/// The file is read once at startup and rewritten after every change.
public final class ServerStore: @unchecked Sendable {
    /// `nil` keeps everything in memory only (tests, or when the file can't be read).
    public let fileURL: URL?
    private let credentials: CredentialStore
    private var settings: PollySettings
    private let lock = NSRecursiveLock()

    public init(fileURL: URL?, credentials: CredentialStore, initial: PollySettings = PollySettings()) throws {
        self.fileURL = fileURL
        self.credentials = credentials
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            settings = try SettingsFile.load(from: fileURL)
        } else {
            settings = initial
        }
    }

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Polly", directoryHint: .isDirectory)
    }

    /// Opens `Application Support/Polly/polly.yaml`. On first run this imports the servers from the
    /// SQLite database used by earlier builds, if there is one.
    public static func makeDefault() throws -> ServerStore {
        let fileURL = defaultDirectory.appending(path: "polly.yaml")
        let exists = FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
        let imported = exists ? nil : LegacySQLiteImport.run(in: defaultDirectory)
        let store = try ServerStore(fileURL: fileURL, credentials: KeychainCredentialStore(),
                                    initial: imported ?? PollySettings())
        if !exists {
            try store.withSettings { _ in } // write the file so it's there to look at / edit
        }
        return store
    }

    /// Applies `change` to a copy of the settings, writes the file, and only then commits the copy.
    private func withSettings<T>(_ change: (inout PollySettings) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var copy = settings
        let result = try change(&copy)
        if let fileURL {
            try SettingsFile.save(copy, to: fileURL)
        }
        settings = copy
        return result
    }

    private func read<T>(_ body: (PollySettings) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(settings)
    }

    // MARK: - Settings

    public var passwordStorage: PasswordStorage { read(\.passwordStorage) }

    public var showDockIcon: Bool { read(\.showDockIcon) }

    public func setShowDockIcon(_ show: Bool) throws {
        try withSettings { $0.showDockIcon = show }
    }

    public var debugLog: Bool { read(\.debugLog) }

    public func setDebugLog(_ enabled: Bool) throws {
        try withSettings { $0.debugLog = enabled }
    }

    /// Switches password storage and moves all existing passwords to the new location.
    /// Switching away from the keychain reads and removes the existing keychain items (this may prompt
    /// once); after that the keychain is no longer accessed.
    public func setPasswordStorage(_ newValue: PasswordStorage) throws {
        let current = read(\.passwordStorage)
        guard newValue != current else { return }
        let ids = read { $0.servers.map(\.server.id) }

        switch newValue {
        case .file:
            // Read everything first so a keychain failure leaves nothing half-migrated.
            let passwords = try Dictionary(uniqueKeysWithValues: ids.map { ($0, try credentials.password(for: $0)) })
            try withSettings { settings in
                for index in settings.servers.indices {
                    settings.servers[index].password = passwords[settings.servers[index].server.id] ?? nil
                }
                settings.passwordStorage = .file
            }
            for id in ids {
                try? credentials.setPassword(nil, for: id)
            }
        case .keychain:
            for entry in read(\.servers) {
                try credentials.setPassword(entry.password, for: entry.server.id)
            }
            try withSettings { settings in
                for index in settings.servers.indices {
                    settings.servers[index].password = nil
                }
                settings.passwordStorage = .keychain
            }
        }
    }

    // MARK: - Servers

    /// Servers in file order (new servers are appended; reorder them by editing the file).
    public func allServers() -> [NagiosServer] {
        read { $0.servers.map(\.server) }
    }

    public func add(_ server: NagiosServer, password: String?) throws {
        let storage = read(\.passwordStorage)
        if storage == .keychain {
            try credentials.setPassword(password, for: server.id)
        }
        try withSettings {
            $0.servers.append(.init(server: server, password: storage == .file ? Self.nonEmpty(password) : nil))
        }
    }

    public func update(_ server: NagiosServer, password: String?) throws {
        let storage = read(\.passwordStorage)
        if storage == .keychain {
            try credentials.setPassword(password, for: server.id)
        }
        try withSettings { settings in
            guard let index = settings.servers.firstIndex(where: { $0.server.id == server.id }) else { return }
            settings.servers[index] = .init(server: server, password: storage == .file ? Self.nonEmpty(password) : nil)
        }
    }

    /// Pauses or resumes monitoring of a server without touching its password.
    public func setEnabled(_ enabled: Bool, for id: UUID) throws {
        try withSettings { settings in
            guard let index = settings.servers.firstIndex(where: { $0.server.id == id }) else { return }
            settings.servers[index].server.enabled = enabled
        }
    }

    public func setNotifications(_ enabled: Bool, for id: UUID) throws {
        try withSettings { settings in
            guard let index = settings.servers.firstIndex(where: { $0.server.id == id }) else { return }
            settings.servers[index].server.notifications = enabled
        }
    }

    public func delete(_ id: UUID) throws {
        let storage = read(\.passwordStorage)
        try withSettings { $0.servers.removeAll { $0.server.id == id } }
        if storage == .keychain {
            try credentials.setPassword(nil, for: id)
        }
    }

    public func password(for id: UUID) throws -> String? {
        let (storage, filePassword) = read { settings in
            (settings.passwordStorage, settings.servers.first { $0.server.id == id }?.password)
        }
        switch storage {
        case .keychain: return try credentials.password(for: id)
        case .file: return filePassword
        }
    }

    private static func nonEmpty(_ password: String?) -> String? {
        guard let password, !password.isEmpty else { return nil }
        return password
    }
}
