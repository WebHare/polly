import Foundation
import Testing
@testable import NaggieKit

struct ServerStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "naggie-test-\(UUID().uuidString).yaml")
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
