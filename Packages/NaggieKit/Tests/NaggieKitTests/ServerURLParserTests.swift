import Foundation
import Testing
@testable import NaggieKit

struct ServerURLParserTests {
    @Test func extractsCredentials() throws {
        let parsed = try #require(ServerURLParser.parse("https://alice:s3cret@monitor.example.com/"))
        #expect(parsed.baseURL.absoluteString == "https://monitor.example.com")
        #expect(parsed.username == "alice")
        #expect(parsed.password == "s3cret")
    }

    @Test func decodesPercentEncodedCredentials() throws {
        let parsed = try #require(ServerURLParser.parse("https://bob%40corp:p%3Ass%2Fword@nagios.local:8443"))
        #expect(parsed.username == "bob@corp")
        #expect(parsed.password == "p:ss/word")
        #expect(parsed.baseURL.absoluteString == "https://nagios.local:8443")
    }

    @Test func usernameOnly() throws {
        let parsed = try #require(ServerURLParser.parse("http://admin@10.0.0.5"))
        #expect(parsed.username == "admin")
        #expect(parsed.password == nil)
    }

    @Test func stripsNagiosPathQueryAndFragment() throws {
        let parsed = try #require(ServerURLParser.parse("https://mon.example.com/ops/nagios/cgi-bin/status.cgi?host=all#top"))
        #expect(parsed.baseURL.absoluteString == "https://mon.example.com/ops")
    }

    @Test func addsSchemeWhenMissing() throws {
        let parsed = try #require(ServerURLParser.parse("  mon.example.com  "))
        #expect(parsed.baseURL.absoluteString == "https://mon.example.com")
    }

    @Test func rejectsGarbage() {
        #expect(ServerURLParser.parse("") == nil)
        #expect(ServerURLParser.parse("ftp://mon.example.com") == nil)
        #expect(ServerURLParser.parse("https://") == nil)
    }

    @Test func statusJSONURL() {
        let server = NagiosServer(name: "x", baseURL: URL(string: "https://mon.example.com/ops")!, username: "")
        #expect(server.statusJSONURL.absoluteString == "https://mon.example.com/ops/nagios/cgi-bin/statusjson.cgi")
    }

    @MainActor @Test func addServerModelMovesCredentialsOutOfURL() {
        let model = AddServerModel()
        model.urlText = "https://alice:s3cret@monitor.example.com/nagios/"
        #expect(model.urlText == "https://monitor.example.com")
        #expect(model.username == "alice")
        #expect(model.password == "s3cret")
    }
}
