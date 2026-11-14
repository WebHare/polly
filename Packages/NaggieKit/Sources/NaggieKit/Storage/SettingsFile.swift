import Foundation
import Yams

/// Where server passwords are kept.
public enum PasswordStorage: String, Sendable, CaseIterable {
    /// In the system keychain (default).
    case keychain
    /// Unencrypted in the settings file. Never touches the keychain.
    case file
}

/// Everything Naggie persists, stored as one YAML file (`naggie.yaml`).
public struct NaggieSettings: Equatable, Sendable {
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
    public var servers: [Server] = []

    public init(passwordStorage: PasswordStorage = .keychain, showDockIcon: Bool = false, servers: [Server] = []) {
        self.passwordStorage = passwordStorage
        self.showDockIcon = showDockIcon
        self.servers = servers
    }
}

public struct SettingsFileError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Reads and writes `NaggieSettings` as YAML. Writing is done by hand (rather than through an encoder)
/// so the file gets comments, a stable key order and blank lines between servers.
public enum SettingsFile {
    // MARK: Reading

    public static func load(from url: URL) throws -> NaggieSettings {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ yaml: String) throws -> NaggieSettings {
        let raw: RawSettings
        do {
            raw = try YAMLDecoder().decode(RawSettings.self, from: yaml)
        } catch {
            throw SettingsFileError(message: "naggie.yaml is not valid: \(error)")
        }

        var settings = NaggieSettings()
        if let storage = raw.passwordStorage {
            guard let value = PasswordStorage(rawValue: storage) else {
                throw SettingsFileError(message: "naggie.yaml: passwordStorage must be 'keychain' or 'file', not '\(storage)'")
            }
            settings.passwordStorage = value
        }
        settings.showDockIcon = raw.showDockIcon ?? false
        settings.servers = try (raw.servers ?? []).enumerated().map { index, entry in
            guard let urlText = entry.url, let url = URL(string: urlText) else {
                throw SettingsFileError(message: "naggie.yaml: server #\(index + 1) has no valid url")
            }
            let server = NagiosServer(
                id: entry.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                name: entry.name ?? url.host() ?? urlText,
                baseURL: url,
                username: entry.username ?? "",
                enabled: entry.enabled ?? true
            )
            return NaggieSettings.Server(server: server, password: entry.password.flatMap { $0.isEmpty ? nil : $0 })
        }
        return settings
    }

    /// Lenient mirror of the file: every key is optional so hand-edited files with missing keys still load.
    private struct RawSettings: Decodable {
        struct RawServer: Decodable {
            var name: String?
            var url: String?
            var username: String?
            var password: String?
            var enabled: Bool?
            var id: String?
        }

        var passwordStorage: String?
        var showDockIcon: Bool?
        var servers: [RawServer]?
    }

    // MARK: Writing

    public static func save(_ settings: NaggieSettings, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(render(settings).utf8).write(to: url, options: .atomic)
        // May contain passwords: owner-only.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }

    public static func render(_ settings: NaggieSettings) -> String {
        var out = """
            # Naggie settings
            #
            # Written by Naggie whenever you change something in the app. You can edit it by hand
            # while Naggie is not running; changes are read at startup.

            # Where server passwords are kept:
            #   keychain  in the system keychain (recommended)
            #   file      unencrypted, as "password:" entries in this file
            passwordStorage: \(settings.passwordStorage.rawValue)

            # macOS only: show a Dock icon in addition to the menu bar icon.
            showDockIcon: \(settings.showDockIcon)


            """

        if settings.servers.isEmpty {
            out += "servers: []\n"
            return out
        }

        out += "servers:\n"
        for (index, entry) in settings.servers.enumerated() {
            if index > 0 { out += "\n" }
            let server = entry.server
            out += "  - name: \(scalar(server.name))\n"
            out += "    url: \(scalar(server.baseURL.absoluteString))\n"
            out += "    username: \(scalar(server.username))\n"
            if let password = entry.password {
                out += "    password: \(scalar(password))\n"
            }
            out += "    enabled: \(server.enabled)\n"
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
