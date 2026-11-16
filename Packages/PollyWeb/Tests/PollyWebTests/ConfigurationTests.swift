/* swift test --package-path /absolute/path/to/polly/Packages/PollyWeb --filter ConfigurationTests */
import Foundation
import PollyKit
import Testing
import Vapor
@testable import PollyWeb

struct ConfigurationTests {
    private func withConfig(_ yaml: String, test: ([String: String]) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "polly-web-\(UUID()).yaml")
        defer { try? FileManager.default.removeItem(at: url) }
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        try test(["POLLY_CONFIG": url.path])
        #expect(try String(contentsOf: url, encoding: .utf8) == yaml)
    }

    @Test func loadsAnExplicitReadOnlyFile() throws {
        try withConfig("passwordStorage: file\nservers: []") { env in
            let config = try WebConfiguration(environment: env)
            #expect(config.settings.servers.isEmpty)
            #expect(config.settings.passwordStorage == .file)
        }
        try withConfig("""
            passwordStorage: file
            debugLog: true
            servers:
              - url: http://127.0.0.1:8089
                username: nagiosadmin
                password: upstream-secret
                notifications: true
            """) { env in
            let config = try WebConfiguration(environment: env)
            #expect(config.settings.servers.count == 1)
            #expect(config.settings.servers[0].password == "upstream-secret")
            #expect(!config.settings.debugLog)
            #expect(!config.settings.servers[0].server.notifications)
        }
    }

    @Test func rejectsMissingConfiguration() {
        #expect(throws: (any Error).self) { try WebConfiguration(environment: [:]) }
        #expect(throws: (any Error).self) { try WebConfiguration(environment: ["POLLY_CONFIG": "/missing/polly.yaml"]) }
    }

    @Test func loadsCurrentSourceKeyWithoutRewriting() throws {
        try withConfig("""
            passwordStorage: file
            sources:
              - name: Current format
                url: https://nagios.example.test
                username: nagiosadmin
                password: upstream-secret
            """) { env in
            let config = try WebConfiguration(environment: env)
            print("Current configuration format: expected 1 source, observed \(config.settings.servers.count)")
            #expect(config.settings.servers.count == 1)
            #expect(config.settings.servers.first?.server.name == "Current format")
        }
    }

    @Test func viewerSecretsAndBindingAreValidated() throws {
        try withConfig("passwordStorage: file\nservers: []") { environment in
            let config = try WebConfiguration(environment: environment)
            #expect(throws: (any Error).self) { try config.validate(address: .hostname("0.0.0.0", port: 8088)) }
            try config.validate(address: .hostname("127.0.0.1", port: 8088))
            try config.validate(address: .hostname("::1", port: 8088))
            for extra in [["POLLY_VIEWER_USERNAME": "viewer"], ["POLLY_VIEWER_PASSWORD_HASH_FILE": "/missing"]] {
                #expect(throws: (any Error).self) { try WebConfiguration(environment: environment.merging(extra) { _, new in new }) }
            }
            let file = FileManager.default.temporaryDirectory.appending(path: "polly-secret-\(UUID())")
            defer { try? FileManager.default.removeItem(at: file) }
            let env = environment.merging(["POLLY_VIEWER_USERNAME": "viewer", "POLLY_VIEWER_PASSWORD_HASH_FILE": file.path]) { _, new in new }
            for invalid in ["plaintext-secret", "$2b$31$" + String(repeating: "a", count: 53), ""] {
                try invalid.write(to: file, atomically: true, encoding: .utf8)
                #expect(throws: WebConfigurationError.self) { try WebConfiguration(environment: env) }
            }
            try Bcrypt.hash("viewer-secret", cost: 10).write(to: file, atomically: true, encoding: .utf8)
            try WebConfiguration(environment: env).validate(address: .hostname("0.0.0.0", port: 8088))
        }
    }

    @Test func rejectsUnsupportedAndUnsafeConfigurationWithoutEchoingIt() throws {
        let duplicate = UUID().uuidString
        let cases = [
            "passwordStorage: keychain\nservers: []",
            "servers: []",
            "passwordStorage: file\nservers: [upstream-secret",
            "passwordStorage: file\nservers:\n  - url: https://site.test\n    type: url\n    enabled: false",
            "passwordStorage: file\nservers:\n  - url: https://site.test\n    id: \(duplicate)\n  - url: https://other.test\n    id: \(duplicate)",
        ] + ["file:///tmp/polly.yaml", "ftp://site.test", "https://user:upstream-secret@site.test", "https://site.test/#upstream-secret", "relative", "https:///"].map {
            "passwordStorage: file\nservers:\n  - url: \($0)"
        }
        for yaml in cases {
            try withConfig(yaml) { env in
                do {
                    _ = try WebConfiguration(environment: env)
                    Issue.record("Invalid configuration was accepted")
                } catch {
                    #expect(!error.localizedDescription.contains("upstream-secret"))
                }
            }
        }
    }
}
