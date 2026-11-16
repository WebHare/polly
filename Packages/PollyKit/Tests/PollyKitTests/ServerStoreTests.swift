import Foundation
import Testing
@testable import PollyKit

struct ServerStoreTests {
    #if canImport(Security)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POLLY_KEYCHAIN_TESTS"] != nil))
    func realKeychainRoundTrip() throws {
        // A unique service keeps this opt-in check away from the app's real credentials.
        let credentials = KeychainCredentialStore(service: "nl.webhare.polly.test.\(UUID().uuidString)")
        let id = UUID()
        defer { try? credentials.setPassword(nil, for: id) }
        #expect(try credentials.password(for: id) == nil)
        try credentials.setPassword("first", for: id)
        #expect(try credentials.password(for: id) == "first")
        try credentials.setPassword("updated", for: id)
        #expect(try credentials.password(for: id) == "updated")
        try credentials.setPassword(nil, for: id)
        #expect(try credentials.password(for: id) == nil)
    }
    #endif

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "polly-test-\(UUID().uuidString).yaml")
    }

    @Test func addListUpdateDeletePersists() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let keychain = InMemoryCredentialStore()
        let store = try ServerStore(fileURL: file, credentials: keychain)
        var server = NagiosServer(name: "Prod", baseURL: URL(string: "https://mon.example.com")!, username: "alice")
        try store.add(server, password: "pw")

        #expect(store.allServers() == [server])
        #expect(try store.password(for: server.id) == "pw")
        // A fresh store reading the same file sees the same servers.
        #expect(try ServerStore(fileURL: file, credentials: keychain).allServers() == [server])
        // Keychain mode: no password in the file.
        #expect(try !String(contentsOf: file, encoding: .utf8).contains("    password:"))

        server.name = "Production"
        try store.update(server, password: nil)
        #expect(store.allServers().first?.name == "Production")
        #expect(try store.password(for: server.id) == nil)

        try store.setEnabled(false, for: server.id)
        #expect(try ServerStore(fileURL: file, credentials: keychain).allServers().first?.enabled == false)

        try store.delete(server.id)
        #expect(store.allServers().isEmpty)
    }

    // TODO: Remove with the `servers:` migration after 2026-11-23.
    @Test func migratesLegacyServersKeyOnce() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try "servers:\n  - name: Prod\n    url: https://mon.example.com\n".write(to: file, atomically: true, encoding: .utf8)

        let store = try ServerStore(fileURL: file, credentials: InMemoryCredentialStore())
        #expect(store.allServers().map(\.name) == ["Prod"])
        let rewritten = try String(contentsOf: file, encoding: .utf8)
        #expect(rewritten.contains("\nsources:\n  - name: Prod\n"))
        #expect(!rewritten.contains("servers:"))
    }

    @Test func switchingPasswordStorageMovesPasswords() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let keychain = InMemoryCredentialStore()
        let store = try ServerStore(fileURL: file, credentials: keychain)
        let server = NagiosServer(name: "Prod", baseURL: URL(string: "https://mon.example.com")!, username: "alice")
        #expect(store.passwordStorage == .keychain)
        try store.add(server, password: "pw")
        #expect(try keychain.password(for: server.id) == "pw")

        try store.setPasswordStorage(.file)
        #expect(store.passwordStorage == .file)
        #expect(try keychain.password(for: server.id) == nil)
        #expect(try store.password(for: server.id) == "pw")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("password: pw"))

        // New servers in file mode never reach the keychain.
        let other = NagiosServer(name: "Test", baseURL: URL(string: "https://test.example.com")!, username: "bob")
        try store.add(other, password: "pw2")
        #expect(try keychain.password(for: other.id) == nil)
        #expect(try ServerStore(fileURL: file, credentials: keychain).password(for: other.id) == "pw2")

        try store.setPasswordStorage(.keychain)
        #expect(try keychain.password(for: server.id) == "pw")
        #expect(try keychain.password(for: other.id) == "pw2")
        #expect(try !String(contentsOf: file, encoding: .utf8).contains("    password:"))
    }

    @Test func settingsPersist() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try ServerStore(fileURL: file, credentials: InMemoryCredentialStore()).setShowDockIcon(true)
        #expect(try ServerStore(fileURL: file, credentials: InMemoryCredentialStore()).showDockIcon)

        let store = try ServerStore(fileURL: file, credentials: InMemoryCredentialStore())
        let server = NagiosServer(name: "Prod", baseURL: URL(string: "https://mon.example.com")!, username: "alice")
        try store.add(server, password: nil)
        try store.setNotifications(true, for: server.id)
        try store.setDebugLog(true)
        let reopened = try ServerStore(fileURL: file, credentials: InMemoryCredentialStore())
        #expect(reopened.allServers().first?.notifications == true)
        #expect(reopened.debugLog)
    }
}
