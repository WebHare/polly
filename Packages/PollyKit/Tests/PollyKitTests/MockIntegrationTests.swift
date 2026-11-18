/* node mock/nagios-mock.mjs --no-rotate &
   POLLY_MOCK_URL=http://localhost:8080 swift test --package-path Packages/PollyKit --filter MockIntegrationTests */
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PollyKit

/// Runs the real client against `mock/nagios-mock.mjs`. The mock is developed together with the client:
/// when a real Nagios turns out to behave differently, change the mock first and let these tests fail.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["POLLY_MOCK_URL"] != nil))
struct MockIntegrationTests {
    private let base = URL(string: ProcessInfo.processInfo.environment["POLLY_MOCK_URL"] ?? "http://localhost:8080")!
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

    private func hostProblem() async throws -> ServiceProblem? {
        try await client().fetchStatus().problems.first { $0.host == host && $0.isHost }
    }

    @Test func downHostIsAProblemOfItsOwn() async throws {
        try await control("/mock/reset")
        try await control("/mock/sethost?host=\(host)&status=down")
        let down = try #require(try await hostProblem())
        #expect(down.hostState == .down)
        #expect(down.severity == .critical)
        #expect(!down.output.isEmpty)
        #expect(down.since != nil)
        try await control("/mock/sethost?host=\(host)&status=unreachable")
        #expect(try await hostProblem()?.hostState == .unreachable)
        try await control("/mock/reset")
        #expect(try await hostProblem() == nil)
    }

    @Test func acknowledgeAndDowntimeADownHost() async throws {
        try await control("/mock/reset")
        try await control("/mock/sethost?host=\(host)&status=down")
        let target = try #require(try await hostProblem())
        #expect(try client().checkURL(for: target).query()?.contains("type=1") == true)
        #expect(try await client().relatedURL(for: target).host() == "runbook.example.com")

        let acknowledge = try await client().prepareCommand(.acknowledge, for: target)
        try await acknowledge.submit(CommandInput(author: acknowledge.defaults.author, comment: "Investigating"))
        #expect(try await hostProblem()?.acknowledged == true)

        let downtime = try await client().prepareCommand(.downtime, for: try #require(try await hostProblem()))
        #expect(downtime.options == [.hostScope])
        var input = downtime.defaults
        input.comment = "Maintenance"
        input.scope = .hostAndServices
        try await downtime.submit(input)
        #expect(try await hostProblem()?.downtimeDepth == 1)
        let services = try #require(try await statusJSON("servicelist")["servicelist"] as? [String: [String: [String: Any]]])
        #expect(services[host]?.values.allSatisfy { $0["scheduled_downtime_depth"] as? Int == 1 } == true)
        try await control("/mock/reset")
    }

    /// A normal host acknowledgement ends when the host comes back up, like a sticky one.
    @Test func hostAcknowledgementEndsOnRecovery() async throws {
        try await control("/mock/reset")
        try await control("/mock/sethost?host=\(host)&status=down")
        let acknowledge = try await client().prepareCommand(.acknowledge, for: try #require(try await hostProblem()))
        try await acknowledge.submit(CommandInput(author: "x", comment: "Investigating"))
        try await control("/mock/sethost?host=\(host)&status=up")
        try await control("/mock/sethost?host=\(host)&status=down")
        #expect(try await hostProblem()?.acknowledged == false)
        try await control("/mock/reset")
    }

    /// The raw statusjson.cgi entry, for what Polly doesn't decode (host downtime, acknowledgement type).
    private func statusJSON(_ query: String) async throws -> [String: Any] {
        var request = URLRequest(url: base.appending(path: "nagios/cgi-bin/statusjson.cgi").appending(queryItems: [
            URLQueryItem(name: "query", value: query), URLQueryItem(name: "details", value: "true")]))
        request.setValue("Basic " + Data("nagiosadmin:nagios".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["data"] as? [String: Any])
    }

    /// Polly sends sticky acknowledgements: they survive WARNING -> CRITICAL and end on recovery, like in Nagios.
    @Test func stickyAcknowledgementLastsUntilRecovery() async throws {
        try await control("/mock/reset")
        try await control("/mock/set?host=\(host)&service=HTTP&status=warning")
        let target = try #require(try await problem("HTTP"))
        let acknowledge = try await client().prepareCommand(.acknowledge, for: target)
        try await acknowledge.submit(CommandInput(author: acknowledge.defaults.author, comment: "Investigating"))
        try await control("/mock/set?host=\(host)&service=HTTP&status=critical")
        #expect(try await problem("HTTP")?.acknowledged == true)
        try await control("/mock/set?host=\(host)&service=HTTP&status=ok")
        try await control("/mock/set?host=\(host)&service=HTTP&status=critical")
        #expect(try await problem("HTTP")?.acknowledged == false)
    }

    /// The downtime form offers both options against the mock; this schedules the host, its services and the
    /// acknowledgement in one go. Four forms are fetched before anything is posted, so this also proves that the
    /// CSRF cookie of the first form stays valid for the others.
    @Test func downtimeForHostAndServicesWithAcknowledgement() async throws {
        try await control("/mock/reset")
        try await control("/mock/set?host=\(host)&service=HTTP&status=critical")
        let target = try #require(try await problem("HTTP"))
        let downtime = try await client().prepareCommand(.downtime, for: target)
        #expect(downtime.options == [.hostScope, .alsoAcknowledge])
        #expect(downtime.defaults.alsoAcknowledge)
        var input = downtime.defaults
        input.comment = "Replacing the disks"
        input.scope = .hostAndServices
        input.end = try #require(downtime.end(for: .oneHour, from: input.start))
        try await downtime.submit(input)

        let http = try #require(try await problem("HTTP"))
        #expect(http.downtimeDepth == 1)
        #expect(http.acknowledged)
        let services = try #require(try await statusJSON("servicelist")["servicelist"] as? [String: [String: [String: Any]]])
        #expect(services[host]?.values.allSatisfy { $0["scheduled_downtime_depth"] as? Int == 1 } == true)
        #expect(services["web2.example.com"]?["HTTP"]?["scheduled_downtime_depth"] as? Int == 0)
        let hosts = try #require(try await statusJSON("hostlist")["hostlist"] as? [String: [String: Any]])
        #expect(hosts[host]?["scheduled_downtime_depth"] as? Int == 1)
        // The acknowledgement that comes with a downtime is sticky too.
        #expect(services[host]?["HTTP"]?["acknowledgement_type"] as? Int == 2)
    }

    /// An already acknowledged problem doesn't offer "also acknowledge".
    @Test func acknowledgedProblemOffersNoSecondAcknowledgement() async throws {
        try await control("/mock/reset")
        try await control("/mock/set?host=\(host)&service=HTTP&status=critical")
        let acknowledge = try await client().prepareCommand(.acknowledge, for: try #require(try await problem("HTTP")))
        try await acknowledge.submit(CommandInput(author: "x", comment: "Investigating"))
        let downtime = try await client().prepareCommand(.downtime, for: try #require(try await problem("HTTP")))
        #expect(downtime.options == [.hostScope])
        #expect(!downtime.defaults.alsoAcknowledge)
        var input = downtime.defaults
        input.comment = "x"
        input.alsoAcknowledge = true
        #expect(throws: BackendError.self) { try downtime.validate(input) }
    }

    /// Two overlapping downtimes count twice in scheduled_downtime_depth.
    @Test func overlappingDowntimesAddUp() async throws {
        try await control("/mock/reset")
        try await control("/mock/set?host=\(host)&service=HTTP&status=critical")
        for _ in 0..<2 {
            let downtime = try await client().prepareCommand(.downtime, for: try #require(try await problem("HTTP")))
            var input = downtime.defaults
            input.comment = "Maintenance"
            input.alsoAcknowledge = false
            try await downtime.submit(input)
        }
        #expect(try await problem("HTTP")?.downtimeDepth == 2)
    }

    /// date_format=euro: the presets still produce the server's notation.
    @Test func presetsUseTheServerNotation() async throws {
        try await control("/mock/reset")
        try await control("/mock/config?dateFormat=euro")
        try await control("/mock/set?host=\(host)&service=HTTP&status=critical")
        let downtime = try await client().prepareCommand(.downtime, for: try #require(try await problem("HTTP")))
        var input = downtime.defaults
        // The prefilled end is 2 hours after the start, so the "2 hours" preset reproduces it.
        #expect(downtime.end(for: .twoHours, from: input.start) == input.end)
        input.end = try #require(downtime.end(for: .thirtyMinutes, from: input.start))
        input.comment = "Short break"
        input.alsoAcknowledge = false
        try await downtime.submit(input)
        #expect(try await problem("HTTP")?.downtimeDepth == 1)
        try await control("/mock/reset")
    }

    /// Regression test for a startup crash with `async let` in `fetchStatus()`: a refused server next to busy ones
    /// crashed the process ("freed pointer was not the last allocation", or a jump into freed memory). It is timing
    /// dependent, so it catches a regression most of the time, not always. Needs nothing listening on 127.0.0.1:9.
    /// Real HTTP avoids Linux URLProtocol's unsafe task-registry access from delayed stub callbacks.
    @Test func refusedServerNextToBusyOnesDoesNotCrash() async throws {
        try await control("/mock/reset")
        let busy = client()
        let refused = NagiosClient(endpoint: URL(string: "http://127.0.0.1:9/nagios/cgi-bin/statusjson.cgi")!,
                                   username: "", password: nil)
        for _ in 0..<20 {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<64 {
                    group.addTask {
                        do {
                            let status = try await busy.fetchStatus()
                            #expect(status.hosts.up == 6)
                            #expect(status.services.ok == 23)
                        } catch {
                            Issue.record("Mock request failed: \(error)")
                        }
                    }
                    group.addTask {
                        do {
                            _ = try await refused.fetchStatus()
                            Issue.record("A refused connection must fail")
                        } catch NagiosClientError.transport { } catch {
                            Issue.record("Expected a transport failure, got \(error)")
                        }
                    }
                }
            }
        }
    }

    @Test func redirectsAndBadCredentialsFail() async {
        await #expect(throws: NagiosClientError.redirect) { try await client(path: "redirect").testConnection() }
        await #expect(throws: NagiosClientError.unauthorized) { try await client(password: "wrong").testConnection() }
    }

    @Test func programWideNotificationsCanBeSwitched() async throws {
        try await control("/mock/reset")
        #expect(try await client().fetchStatus().notificationsEnabled == true)
        try await client().setNotificationsEnabled(false)
        #expect(try await client().fetchStatus().notificationsEnabled == false)
        try await client().setNotificationsEnabled(true)
        #expect(try await client().fetchStatus().notificationsEnabled == true)
    }

    /// `CMT_DISABLE_NOTIFICATIONS=2` in cgi.cfg makes a comment required; the form then has author and comment fields.
    @Test func programWideNotificationsWithARequiredComment() async throws {
        try await control("/mock/reset")
        try await control("/mock/config?notificationComment=2&csrf=off")
        try await client().setNotificationsEnabled(false)
        #expect(try await client().fetchStatus().notificationsEnabled == false)
        try await control("/mock/reset")
    }

    /// Without `authorized_for_system_commands` Nagios shows the form but refuses the commit.
    @Test func programWideNotificationsNeedSystemCommandPermission() async throws {
        try await control("/mock/reset")
        try await control("/mock/config?systemCommands=off")
        await #expect(throws: BackendError.self) { try await client().setNotificationsEnabled(false) }
        #expect(try await client().fetchStatus().notificationsEnabled == true)
        try await control("/mock/reset")
    }
}
