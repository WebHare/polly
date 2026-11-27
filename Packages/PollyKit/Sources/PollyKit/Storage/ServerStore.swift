import Foundation

/// Persists sources and settings in a single YAML file (see `SettingsFile`). Passwords go either to a
/// `CredentialStore` (the keychain) or into that file, depending on `passwordStorage`.
///
/// The file is read once at startup and rewritten after every change.
public final class ServerStore: @unchecked Sendable {
    /// `nil` keeps everything in memory only (tests, or when the file can't be read).
    public let fileURL: URL?
    private let credentials: CredentialStore
    private var settings: PollySettings
    private let lock = NSRecursiveLock()
    /// The iCloud list as this device last synced it, when there is no file to keep it next to.
    private var memorySyncBase: String?
    /// Passwords already moved into or out of iCloud Keychain to match the setting, this launch.
    private var passwordsInPlace: Set<UUID> = []

    public init(fileURL: URL?, credentials: CredentialStore, initial: PollySettings = PollySettings()) throws {
        self.fileURL = fileURL
        self.credentials = credentials
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            let (loaded, isLegacy) = try SettingsFile.loadMigrating(from: fileURL)
            settings = loaded
            // TODO: Remove the `servers:` migration after 2026-11-23.
            if isLegacy {
                try SettingsFile.save(loaded, to: fileURL)
            }
        } else {
            settings = initial
        }
    }

    #if canImport(Security)
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Polly", directoryHint: .isDirectory)
    }

    /// Opens `Application Support/Polly/polly.yaml`, creating it on first run.
    public static func makeDefault() throws -> ServerStore {
        let fileURL = defaultDirectory.appending(path: "polly.yaml")
        let exists = FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
        let store = try ServerStore(fileURL: fileURL, credentials: KeychainCredentialStore())
        if !exists {
            try store.withSettings { _ in } // write the file so it's there to look at / edit
        }
        return store
    }

    #endif

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

    public var hideServicesOnDownHosts: Bool { read(\.hideServicesOnDownHosts) }

    public func setHideServicesOnDownHosts(_ hide: Bool) throws {
        try withSettings { $0.hideServicesOnDownHosts = hide }
    }

    public var syncWithICloud: Bool { read(\.syncWithICloud) }

    /// Turns syncing on or off, and moves the keychain passwords into or out of iCloud Keychain to match.
    public func setSyncWithICloud(_ sync: Bool) throws {
        try withSettings { $0.syncWithICloud = sync }
        lock.withLock { passwordsInPlace = [] }
        guard read(\.passwordStorage) == .keychain else { return }
        for id in read({ $0.servers.map(\.server.id) }) {
            try credentials.setSynchronizable(sync, for: id)
        }
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
                try credentials.setPassword(entry.password, for: entry.server.id, synchronizable: read(\.syncWithICloud))
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
            try credentials.setPassword(password, for: server.id, synchronizable: read(\.syncWithICloud))
        }
        try withSettings {
            $0.servers.append(.init(server: server, password: storage == .file ? Self.nonEmpty(password) : nil))
        }
    }

    public func update(_ server: NagiosServer, password: String?) throws {
        let storage = read(\.passwordStorage)
        if storage == .keychain {
            try credentials.setPassword(password, for: server.id, synchronizable: read(\.syncWithICloud))
        }
        try withSettings { settings in
            guard let index = settings.servers.firstIndex(where: { $0.server.id == server.id }) else { return }
            settings.servers[index] = .init(server: server, password: storage == .file ? Self.nonEmpty(password) : nil)
        }
    }

    /// Pauses a server from that moment, or resumes it with nil.
    public func setPaused(since date: Date?, for id: UUID) throws {
        try withSettings { settings in
            guard let index = settings.servers.firstIndex(where: { $0.server.id == id }) else { return }
            settings.servers[index].server.pausedSince = date
        }
    }

    /// Disables or enables a server without touching its password.
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
        case .keychain:
            // Passwords stored before syncing (or with it off on this device) move to match the setting, once.
            let sync = read(\.syncWithICloud)
            if lock.withLock({ passwordsInPlace.insert(id).inserted }) {
                try? credentials.setSynchronizable(sync, for: id)
            }
            return try credentials.password(for: id)
        case .file: return filePassword
        }
    }

    // MARK: - iCloud

    private var syncBaseURL: URL? {
        fileURL?.deletingLastPathComponent().appending(path: "polly-sync.yaml")
    }

    /// The iCloud list as this device last synced it; nil before the first sync.
    public func syncBase() -> [SyncedSource]? {
        let text = lock.withLock { () -> String? in
            guard let url = syncBaseURL else { return memorySyncBase }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return text.flatMap { try? SyncedSource.parse($0) }
    }

    public func setSyncBase(_ base: [SyncedSource]?) throws {
        try lock.withLock {
            let text = base.map(SyncedSource.render)
            guard let url = syncBaseURL else { memorySyncBase = text; return }
            if let text {
                try Data(text.utf8).write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Takes over the merged list: sources keep their password, also when a source got the ID it has in iCloud.
    public func applySync(_ merge: SourceSync.Merge) throws {
        let storage = read(\.passwordStorage)
        let sync = read(\.syncWithICloud)
        if storage == .keychain {
            for (old, new) in merge.renamed {
                // The password in iCloud Keychain under the new ID, if any, is the one the other devices use.
                if try credentials.password(for: new) == nil, let password = try credentials.password(for: old) {
                    try credentials.setPassword(password, for: new, synchronizable: sync)
                }
                try credentials.setPassword(nil, for: old)
            }
        }
        try withSettings { settings in
            let entries = Dictionary(settings.servers.map { ($0.server.id, $0) }, uniquingKeysWith: { first, _ in first })
            let oldID = Dictionary(merge.renamed.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            settings.servers = merge.servers.map { server in
                let entry = entries[server.id] ?? oldID[server.id].flatMap { entries[$0] }
                return PollySettings.Server(server: server, password: storage == .file ? entry?.password : nil)
            }
        }
        if storage == .keychain {
            for id in merge.deleted {
                try? credentials.setPassword(nil, for: id)
            }
        }
    }

    private static func nonEmpty(_ password: String?) -> String? {
        guard let password, !password.isEmpty else { return nil }
        return password
    }
}
