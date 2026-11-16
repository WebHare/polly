import Foundation
import Testing
@testable import PollyKit

struct SettingsFileTests {
    @Test func roundTripsTrickyStrings() throws {
        let names = ["yes", "a: b", "#hash", "trailing ", "quote\"back\\slash", "ümlaut ✓", "multi\nline", "123", "", "- dash", "ok:"]
        var settings = PollySettings(passwordStorage: .file, showDockIcon: true)
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
        let settings = PollySettings(servers: [
            .init(server: NagiosServer(id: id, name: "Production", baseURL: URL(string: "https://mon.example.com")!, username: "alice")),
            .init(server: NagiosServer(id: id, name: "Test", baseURL: URL(string: "http://test.local")!, username: "", enabled: false)),
        ])
        let yaml = SettingsFile.render(settings)
        #expect(yaml.contains("""
            sources:
              - name: Production
                type: nagios
                url: https://mon.example.com
                username: alice
                enabled: true
                notifications: false
                id: 3f2504e0-4f89-11d3-9a0c-0305e82c3301

              - name: Test
                type: nagios
                url: http://test.local
                username: ""
                enabled: false
            """))
    }

    @Test func toleratesMinimalHandWrittenFile() throws {
        let settings = try SettingsFile.parse("""
            sources:
            - url: https://mon.example.com
            """)
        #expect(settings.passwordStorage == .keychain)
        #expect(settings.servers.count == 1)
        #expect(settings.servers[0].server.name == "mon.example.com")
        #expect(settings.servers[0].server.enabled)
    }

    @Test func rejectsBadValues() {
        #expect(throws: SettingsFileError.self) { try SettingsFile.parse("passwordStorage: cloud") }
        #expect(throws: SettingsFileError.self) { try SettingsFile.parse("sources:\n  - name: x\n") }
        #expect(throws: SettingsFileError.self) { try SettingsFile.parse("sources:\n  - url: https://x.example\n    type: zabbix\n") }
    }

    @Test func roundTripsBackendNotificationsAndDebugLog() throws {
        var settings = PollySettings(debugLog: true)
        settings.servers.append(.init(server: NagiosServer(name: "Prod", baseURL: URL(string: "https://mon.example.com")!,
                                                           username: "alice", notifications: true)))
        let parsed = try SettingsFile.parse(SettingsFile.render(settings))
        #expect(parsed == settings)
        #expect(parsed.servers[0].server.kind == .nagios)
        // Files written before these keys existed keep loading with the defaults.
        let old = try SettingsFile.parse("sources:\n  - url: https://mon.example.com\n")
        #expect(!old.debugLog)
        #expect(!old.servers[0].server.notifications)
    }

    // TODO: Remove with the `servers:` migration after 2026-11-23.
    @Test func readsLegacyServersKey() throws {
        let legacy = try SettingsFile.parseMigrating("servers:\n  - url: https://mon.example.com\n")
        #expect(legacy.isLegacy)
        #expect(legacy.settings.servers.map(\.server.name) == ["mon.example.com"])
        #expect(try !SettingsFile.parseMigrating("sources:\n  - url: https://mon.example.com\n").isLegacy)
        #expect(try !SettingsFile.parseMigrating("debugLog: true\n").isLegacy)
        // Both keys: refuse rather than silently dropping one of the lists.
        #expect(throws: SettingsFileError.self) {
            try SettingsFile.parse("servers:\n  - url: https://a.example\nsources:\n  - url: https://b.example\n")
        }
    }
}
