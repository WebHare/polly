import Foundation
import Testing
@testable import NaggieKit

struct SettingsFileTests {
    @Test func roundTripsTrickyStrings() throws {
        let names = ["yes", "a: b", "#hash", "trailing ", "quote\"back\\slash", "ümlaut ✓", "multi\nline", "123", "", "- dash", "ok:"]
        var settings = NaggieSettings(passwordStorage: .file, showDockIcon: true)
        for name in names {
            let server = NagiosServer(name: name, baseURL: URL(string: "https://mon.example.com/sub")!, username: name, enabled: false)
            settings.servers.append(.init(server: server, password: name.isEmpty ? nil : name))
        }
        let yaml = SettingsFile.render(settings)
        #expect(try SettingsFile.parse(yaml) == settings)
    }

    @Test func plainScalarsWhereSafe() {
        #expect(SettingsFile.scalar("Production") == "Production")
        #expect(SettingsFile.scalar("https://mon.example.com:8443/ops") == "https://mon.example.com:8443/ops")
        #expect(SettingsFile.scalar("no") == "\"no\"")
        #expect(SettingsFile.scalar("p@ss: word") == "\"p@ss: word\"")
    }

    @Test func rendersReadableFile() {
        let id = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        let settings = NaggieSettings(servers: [
            .init(server: NagiosServer(id: id, name: "Production", baseURL: URL(string: "https://mon.example.com")!, username: "alice")),
            .init(server: NagiosServer(id: id, name: "Test", baseURL: URL(string: "http://test.local")!, username: "", enabled: false)),
        ])
        let yaml = SettingsFile.render(settings)
        #expect(yaml.contains("""
            servers:
              - name: Production
                url: https://mon.example.com
                username: alice
                enabled: true
                id: 3f2504e0-4f89-11d3-9a0c-0305e82c3301

              - name: Test
                url: http://test.local
                username: ""
                enabled: false
            """))
    }

    @Test func toleratesMinimalHandWrittenFile() throws {
        let settings = try SettingsFile.parse("""
            servers:
            - url: https://mon.example.com
            """)
        #expect(settings.passwordStorage == .keychain)
        #expect(settings.servers.count == 1)
        #expect(settings.servers[0].server.name == "mon.example.com")
        #expect(settings.servers[0].server.enabled)
    }

    @Test func rejectsBadValues() {
        #expect(throws: SettingsFileError.self) { try SettingsFile.parse("passwordStorage: cloud") }
        #expect(throws: SettingsFileError.self) { try SettingsFile.parse("servers:\n  - name: x\n") }
    }
}
