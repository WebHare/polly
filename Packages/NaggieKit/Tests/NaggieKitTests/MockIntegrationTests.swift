/* node mock/nagios-mock.mjs --no-rotate &
   NAGGIE_MOCK_URL=http://localhost:8080 swift test --package-path Packages/NaggieKit --filter MockIntegrationTests */
import Foundation
import Testing
@testable import NaggieKit

/// Runs the real client against `mock/nagios-mock.mjs`. The mock is developed together with the client:
/// when a real Nagios turns out to behave differently, change the mock first and let these tests fail.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NAGGIE_MOCK_URL"] != nil))
struct MockIntegrationTests {
    private let base = URL(string: ProcessInfo.processInfo.environment["NAGGIE_MOCK_URL"] ?? "http://localhost:8080")!
    private let host = "web1.example.com"

    private func client(path: String = "", password: String = "nagios", cookies: Bool = true) -> NagiosClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = cookies
        let server = NagiosServer(name: "Mock", baseURL: path.isEmpty ? base : base.appending(path: path), username: "nagiosadmin")
        return NagiosClient(server: server, password: password, session: URLSession(configuration: configuration))
    }

    /// Mock-only control endpoints: put the inventory in a known state.
    private func control(_ path: String) async throws {
        let (_, response) = try await URLSession.shared.data(from: URL(string: path, relativeTo: base)!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    private func problem(_ service: String) async throws -> ServiceProblem? {
        try await client().fetchStatus().problems.first { $0.host == host && $0.service == service }
    }

    @Test func statusCarriesCheckDetails() async throws {
        try await control("/mock/reset")
        #expect(try await client().fetchStatus().problems.isEmpty)
        try await control("/mock/set?host=\(host)&service=HTTP&status=critical")
        let found = try #require(try await problem("HTTP"))
        #expect(found.severity == .critical)
        #expect(!found.output.isEmpty)
        #expect(found.lastCheck != nil)
        #expect(!found.acknowledged)
        #expect(found.downtimeDepth == 0)
    }

    @Test func relatedURLComesFromTheCheckPage() async throws {
        let http = ServiceProblem(host: host, service: "HTTP", severity: .critical)
        #expect(try client().checkURL(for: http).path() == "/nagios/cgi-bin/extinfo.cgi")
        let action = try await client().relatedURL(for: http)
        #expect(action.scheme == "https")
        #expect(action.query()?.contains("&") == true)
        // A notes URL may be relative to the Nagios server.
        let notes = try await client().relatedURL(for: ServiceProblem(host: host, service: "PING", severity: .critical))
        #expect(notes.host() == base.host())
        await #expect(throws: BackendError.self) {
            try await client().relatedURL(for: ServiceProblem(host: host, service: "Load", severity: .critical))
        }
    }

    @Test func acknowledgeAndDowntimeChangeTheCheck() async throws {
        try await control("/mock/reset")
        try await control("/mock/set?host=\(host)&service=HTTP&status=critical")
        let target = try #require(try await problem("HTTP"))

        let acknowledge = try await client().prepareCommand(.acknowledge, for: target)
        #expect(!acknowledge.defaults.author.isEmpty)
        try await acknowledge.submit(CommandInput(author: acknowledge.defaults.author, comment: "Investigating"))
        #expect(try await problem("HTTP")?.acknowledged == true)

        let downtime = try await client().prepareCommand(.downtime, for: target)
        var input = downtime.defaults
        #expect(!input.start.isEmpty && !input.end.isEmpty)
        input.comment = "Maintenance"
        try await downtime.submit(input)
        #expect(try await problem("HTTP")?.downtimeDepth == 1)
    }

    /// What monitor.webhare.net does: no CSRF token in the form at all, and ISO dates.
    @Test func serverWithoutCSRFTokenAndWithISODates() async throws {
        try await control("/mock/reset")
        try await control("/mock/config?csrf=off&dateFormat=iso8601")
        try await control("/mock/set?host=\(host)&service=HTTP&status=critical")
        let target = try #require(try await problem("HTTP"))

        let acknowledge = try await client().prepareCommand(.acknowledge, for: target)
        try await acknowledge.submit(CommandInput(author: acknowledge.defaults.author, comment: "Investigating"))
        #expect(try await problem("HTTP")?.acknowledged == true)

        let downtime = try await client().prepareCommand(.downtime, for: target)
        var input = downtime.defaults
        #expect(input.start.hasPrefix("20"))
        input.comment = "Maintenance"
        try await downtime.submit(input)
        #expect(try await problem("HTTP")?.downtimeDepth == 1)
        try await control("/mock/reset")
    }

    /// Proves the form's CSRF cookie really travels from the GET to the POST.
    @Test func commandWithoutTheFormCookieIsRejected() async throws {
        try await control("/mock/reset")
        try await control("/mock/set?host=\(host)&service=HTTP&status=critical")
        let target = try #require(try await problem("HTTP"))
        let command = try await client(cookies: false).prepareCommand(.acknowledge, for: target)
        await #expect(throws: BackendError.self) { try await command.submit(CommandInput(author: "x", comment: "y")) }
        #expect(try await problem("HTTP")?.acknowledged == false)
    }

    @Test func redirectsAndBadCredentialsFail() async {
        await #expect(throws: NagiosClientError.redirect) { try await client(path: "redirect").testConnection() }
        await #expect(throws: NagiosClientError.unauthorized) { try await client(password: "wrong").testConnection() }
    }
}
