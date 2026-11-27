import Foundation
import Yams

/// Where source passwords are kept.
public enum PasswordStorage: String, Sendable, CaseIterable {
    /// In the system keychain (default).
    case keychain
    /// Unencrypted in the settings file. Never touches the keychain.
    case file
}

/// Everything Polly persists, stored as one YAML file (`polly.yaml`).
public struct PollySettings: Equatable, Sendable {
    public struct Server: Equatable, Sendable {
        public var server: NagiosServer
        /// Only set when `passwordStorage == .file`.
        public var password: String?

        public init(server: NagiosServer, password: String? = nil) {
            self.server = server
            self.password = password
        }
    }

    public var passwordStorage: PasswordStorage = .keychain
    public var showDockIcon = false
    /// Write `polly-debug.log` (see `WireLog`) next to the settings file.
    public var debugLog = false
    /// List a host that is down as one problem, without the problems of the services on it.
    public var hideServicesOnDownHosts = true
    public var servers: [Server] = []

    public init(passwordStorage: PasswordStorage = .keychain, showDockIcon: Bool = false, debugLog: Bool = false,
                servers: [Server] = []) {
        self.passwordStorage = passwordStorage
        self.showDockIcon = showDockIcon
        self.debugLog = debugLog
        self.servers = servers
    }
}

public struct SettingsFileError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Reads and writes `PollySettings` as YAML. Writing is done by hand (rather than through an encoder)
/// so the file gets comments, a stable key order and blank lines between sources.
public enum SettingsFile {
    // MARK: Reading

    public static func load(from url: URL) throws -> PollySettings {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ yaml: String) throws -> PollySettings {
        try parseMigrating(yaml).settings
    }

    // TODO: Remove the `servers:` migration after 2026-11-23, once every install has rewritten its file.
    /// Like `load`, but also says whether the file still lists its sources under the old `servers:` key and
    /// should be rewritten.
    public static func loadMigrating(from url: URL) throws -> (settings: PollySettings, isLegacy: Bool) {
        try parseMigrating(String(contentsOf: url, encoding: .utf8))
    }

    static func parseMigrating(_ yaml: String) throws -> (settings: PollySettings, isLegacy: Bool) {
        let raw: RawSettings
        do {
            raw = try YAMLDecoder().decode(RawSettings.self, from: yaml)
        } catch {
            throw SettingsFileError(message: "polly.yaml is not valid: \(error)")
        }

        var settings = PollySettings()
        if let storage = raw.passwordStorage {
            guard let value = PasswordStorage(rawValue: storage) else {
                throw SettingsFileError(message: "polly.yaml: passwordStorage must be 'keychain' or 'file', not '\(storage)'")
            }
            settings.passwordStorage = value
        }
        settings.showDockIcon = raw.showDockIcon ?? false
        settings.debugLog = raw.debugLog ?? false
        settings.hideServicesOnDownHosts = raw.hideServicesOnDownHosts ?? true
        if raw.sources != nil, raw.servers != nil {
            throw SettingsFileError(message: "polly.yaml: has both 'sources' and the old 'servers'; merge them into 'sources'")
        }
        settings.servers = try (raw.sources ?? raw.servers ?? []).enumerated().map { index, entry in
            guard let urlText = entry.url, let url = URL(string: urlText) else {
                throw SettingsFileError(message: "polly.yaml: source #\(index + 1) has no valid url")
            }
            var kind = BackendKind.nagios
            if let type = entry.type {
                guard let value = BackendKind(rawValue: type) else {
                    throw SettingsFileError(message: "polly.yaml: source #\(index + 1) has unknown type '\(type)'")
                }
                kind = value
            }
            if let header = entry.authHeader, let problem = SourceCredentials.problem(withHeaderName: header) {
                throw SettingsFileError(message: "polly.yaml: source #\(index + 1) has an invalid authHeader: \(problem)")
            }
            var pausedSince: Date?
            if let text = entry.pausedSince {
                guard let date = ISO8601DateFormatter().date(from: text) else {
                    throw SettingsFileError(message: "polly.yaml: source #\(index + 1) has an unreadable pausedSince '\(text)'")
                }
                pausedSince = date
            }
            let server = NagiosServer(
                id: entry.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                name: entry.name ?? url.host() ?? urlText,
                baseURL: url,
                username: entry.username ?? "",
                enabled: entry.enabled ?? true,
                pausedSince: pausedSince,
                kind: kind,
                notifications: entry.notifications ?? false,
                authHeader: entry.authHeader
            )
            return PollySettings.Server(server: server, password: entry.password.flatMap { $0.isEmpty ? nil : $0 })
        }
        return (settings, raw.servers != nil)
    }

    /// Lenient mirror of the file: every key is optional so hand-edited files with missing keys still load.
    private struct RawSettings: Decodable {
        struct RawServer: Decodable {
            var name: String?
            var type: String?
            var url: String?
            var username: String?
            var authHeader: String?
            var password: String?
            var enabled: Bool?
            var pausedSince: String?
            var notifications: Bool?
            var id: String?
        }

        var passwordStorage: String?
        var showDockIcon: Bool?
        var debugLog: Bool?
        var hideServicesOnDownHosts: Bool?
        var sources: [RawServer]?
        /// The old name of `sources`; read once and rewritten as `sources`.
        var servers: [RawServer]?
    }

    // MARK: Writing

    public static func save(_ settings: PollySettings, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(render(settings).utf8).write(to: url, options: .atomic)
        // May contain passwords: owner-only.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }

    public static func render(_ settings: PollySettings) -> String {
        var out = """
            # Polly settings
            #
            # Written by Polly whenever you change something in the app. You can edit it by hand
            # while Polly is not running; changes are read at startup.

            # Where source passwords are kept:
            #   keychain  in the system keychain (recommended)
            #   file      unencrypted, as "password:" entries in this file
            # A source with "authHeader: <name>" sends its password as the value of that header (for example
            # X-API-Key, or Authorization with "Bearer <token>" as the password) instead of username and password.
            passwordStorage: \(settings.passwordStorage.rawValue)

            # macOS only: show a Dock icon in addition to the menu bar icon.
            showDockIcon: \(settings.showDockIcon)

            # Write polly-debug.log next to this file: every request to and response from the sources,
            # without credentials. For troubleshooting only.
            debugLog: \(settings.debugLog)

            # Show a host that is down as one problem and leave out the problems of the services on it.
            hideServicesOnDownHosts: \(settings.hideServicesOnDownHosts)


            """

        if settings.servers.isEmpty {
            out += "sources: []\n"
            return out
        }

        out += "sources:\n"
        for (index, entry) in settings.servers.enumerated() {
            if index > 0 { out += "\n" }
            let server = entry.server
            out += "  - name: \(scalar(server.name))\n"
            out += "    type: \(server.kind.rawValue)\n"
            out += "    url: \(scalar(server.baseURL.absoluteString))\n"
            out += "    username: \(scalar(server.username))\n"
            if let header = server.authHeader {
                out += "    authHeader: \(scalar(header))\n"
            }
            if let password = entry.password {
                out += "    password: \(scalar(password))\n"
            }
            out += "    enabled: \(server.enabled)\n"
            if let pausedSince = server.pausedSince {
                out += "    pausedSince: \(ISO8601DateFormatter().string(from: pausedSince))\n"
            }
            out += "    notifications: \(server.notifications)\n"
            // UUIDs are hex and dashes: always safe as a plain scalar.
            out += "    id: \(server.id.uuidString.lowercased())\n"
        }
        return out
    }

    /// Formats a string as a YAML scalar: plain when that's unambiguous, double-quoted otherwise.
    static func scalar(_ value: String) -> String {
        needsQuotes(value) ? doubleQuoted(value) : value
    }

    private static let reservedWords: Set<String> = [
        "true", "false", "yes", "no", "on", "off", "y", "n", "null", "~",
    ]
    private static let plainCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-./:@+()"))
    private static let plainFirstCharacters = CharacterSet.letters.union(CharacterSet(charactersIn: "_/"))

    private static func needsQuotes(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, let last = value.unicodeScalars.last else { return true }
        return !plainFirstCharacters.contains(first)
            || last == " " || last == ":"
            || !value.unicodeScalars.allSatisfy(plainCharacters.contains)
            || value.contains(": ")
            || reservedWords.contains(value.lowercased())
    }

    private static func doubleQuoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\x%02X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
