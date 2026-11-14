import Foundation
import SQLite3

/// One-time import of `naggie.sqlite`, used by builds before settings moved to `naggie.yaml`.
/// After a successful import the database files are renamed to `*.imported`.
/// This file (and the sqlite3 link in Package.swift) can be removed once no old installs remain.
enum LegacySQLiteImport {
    static func run(in directory: URL) -> NaggieSettings? {
        let dbURL = directory.appending(path: "naggie.sqlite")
        let path = dbURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer {
            sqlite3_close(handle)
        }

        var settings = NaggieSettings()
        if rows(handle, "SELECT value FROM settings WHERE key = 'password_storage'").first?["value"] == "database" {
            settings.passwordStorage = .file
        }
        // The Dock icon setting used to live in UserDefaults.
        settings.showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")

        for row in rows(handle, "SELECT * FROM servers ORDER BY name COLLATE NOCASE") {
            guard let id = row["id"].flatMap(UUID.init(uuidString:)),
                  let url = row["base_url"].flatMap(URL.init(string:)) else { continue }
            let server = NagiosServer(id: id, name: row["name"] ?? url.host() ?? url.absoluteString, baseURL: url,
                                      username: row["username"] ?? "", enabled: row["enabled"] != "0")
            settings.servers.append(.init(server: server, password: settings.passwordStorage == .file ? row["password"] : nil))
        }

        sqlite3_close(handle)
        handle = nil
        for suffix in ["", "-wal", "-shm"] {
            let from = directory.appending(path: "naggie.sqlite\(suffix)")
            try? FileManager.default.moveItem(at: from, to: directory.appending(path: "naggie.sqlite\(suffix).imported"))
        }
        return settings
    }

    /// All columns as text; good enough for this import.
    private static func rows(_ handle: OpaquePointer?, _ sql: String) -> [[String: String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [[String: String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String] = [:]
            for col in 0..<sqlite3_column_count(stmt) {
                guard let text = sqlite3_column_text(stmt, col) else { continue }
                row[String(cString: sqlite3_column_name(stmt, col))] = String(cString: text)
            }
            result.append(row)
        }
        return result
    }
}
