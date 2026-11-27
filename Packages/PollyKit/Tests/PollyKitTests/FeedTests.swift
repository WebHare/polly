import Foundation
import Testing
@testable import PollyKit

/// Reading a Polly feed (see doc/feed-format.md) into a status, without a network.
struct FeedTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(_ json: String, statusCode: Int = 200) throws -> ServerStatus {
        try FeedDocument.status(from: Data(json.utf8), statusCode: statusCode, fetchedAt: fetchedAt)
    }

    private func failure(_ json: String, statusCode: Int = 200) -> String? {
        do {
            _ = try status(json, statusCode: statusCode)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func readsTheFullFormat() throws {
        let result = try status("""
            {
              "polly": 1,
              "url": "https://portal.example.com/tickets",
              "okCount": 14,
              "noun": { "one": "ticket", "other": "tickets" },
              "unknownKeysAreIgnored": true,
              "items": [
                {
                  "id": "ticket-48213",
                  "group": "utwente_base",
                  "title": "Copy pasten stuk",
                  "severity": "warning",
                  "since": "2026-11-26T20:54:15+01:00",
                  "due": "2026-12-03T13:00:00.500+01:00",
                  "summary": "Onbevestigd · P4",
                  "details": "Labels: P4\\nGitLab issue",
                  "acknowledged": true,
                  "url": "https://portal.example.com/ticket/48213",
                  "fields": [ { "label": "Status", "value": "Onbevestigd" }, { "label": "Toegekend aan", "value": "Rob" } ]
                },
                { "id": 7, "group": "acme", "title": "Crash", "severity": "CRITICAL" }
              ]
            }
            """)
        #expect(result.itemNoun == ItemNoun(one: "ticket", other: "tickets"))
        #expect(result.services == ServiceCounts(ok: 14, warning: 1, critical: 1))
        #expect(result.hosts == HostCounts())
        #expect(result.fetchedAt == fetchedAt)
        #expect(result.notificationsEnabled == nil)

        let ticket = try #require(result.problems.first { $0.itemID == "ticket-48213" })
        #expect(ticket.host == "utwente_base")
        #expect(ticket.service == "Copy pasten stuk")
        #expect(ticket.title == "Copy pasten stuk")
        #expect(ticket.severity == .warning)
        #expect(ticket.since == Date(timeIntervalSince1970: 1_795_722_855))
        #expect(ticket.due == Date(timeIntervalSince1970: 1_796_299_200.5))
        #expect(ticket.output == "Onbevestigd · P4")
        #expect(ticket.longOutput == "Labels: P4\nGitLab issue")
        #expect(ticket.acknowledged)
        #expect(ticket.link == URL(string: "https://portal.example.com/ticket/48213"))
        #expect(ticket.fields == [ProblemField(label: "Status", value: "Onbevestigd"),
                                  ProblemField(label: "Toegekend aan", value: "Rob")])
        #expect(ticket.lastCheck == fetchedAt)
        #expect(ticket.id == "ticket-48213")

        // A numeric id is accepted; an item without a link opens the feed's own page.
        let crash = try #require(result.problems.first { $0.itemID == "7" })
        #expect(crash.severity == .critical)
        #expect(crash.link == URL(string: "https://portal.example.com/tickets"))
        #expect(!crash.acknowledged)
        #expect(crash.fields.isEmpty)

        // Worst first, like the other sources.
        #expect(result.problems.map(\.severity) == [.critical, .warning])
    }

    @Test func aMinimalFeedHasDefaults() throws {
        let result = try status(#"{"polly":1,"items":[]}"#)
        #expect(result.problems.isEmpty)
        #expect(result.services == ServiceCounts())
        #expect(result.itemNoun == ItemNoun(one: "item", other: "items"))
        #expect(result.severity == .ok)
    }

    @Test func itemsWithTheSameTitleStaySeparate() throws {
        let result = try status("""
            {"polly":1,"items":[{"id":"a","group":"g","title":"Same","severity":"warning"},
                                {"id":"b","group":"g","title":"Same","severity":"warning"}]}
            """)
        #expect(Set(result.problems.map(\.id)) == ["a", "b"])
    }

    @Test func linksOtherThanWebPagesAreIgnored() throws {
        let result = try status("""
            {"polly":1,"url":"javascript:alert(1)","items":[{"id":"a","group":"g","title":"t","severity":"unknown","url":"file:///etc/passwd"}]}
            """)
        #expect(result.problems[0].link == nil)
        #expect(result.problems[0].severity == .unknown)
    }

    @Test func refusesWhatIsNotAFeed() {
        #expect(failure("<html>login</html>") == "The response is not JSON, so it is not a Polly feed.")
        #expect(failure(#"{"items":[]}"#) == "The response is not a Polly feed: it has no \"polly\" version.")
        #expect(failure(#"{"polly":2,"items":[]}"#) == "This feed uses format version 2, which this version of Polly can't read. Update Polly.")
        #expect(failure(#"{"polly":1}"#) == "The feed has no \"items\" list.")
    }

    @Test func refusesItemsItCannotShow() {
        #expect(failure(#"{"polly":1,"items":[{"group":"g","title":"t","severity":"warning"}]}"#)
            == "Feed item #1 has no \"id\".")
        #expect(failure(#"{"polly":1,"items":[{"id":"a","title":"t","severity":"warning"}]}"#)
            == "Feed item #1 has no \"group\".")
        #expect(failure(#"{"polly":1,"items":[{"id":"a","group":"g","severity":"warning"}]}"#)
            == "Feed item #1 has no \"title\".")
        #expect(failure(#"{"polly":1,"items":[{"id":"a","group":"g","title":"t","severity":"ok"}]}"#)
            == "Feed item #1 has severity \"ok\"; it must be critical, warning or unknown.")
        #expect(failure(#"{"polly":1,"items":[{"id":"a","group":"g","title":"t","severity":"warning","since":"yesterday"}]}"#)
            == "Feed item #1 has an invalid \"since\" date: use ISO 8601 with a time zone, like 2026-11-27T10:15:00+01:00.")
        #expect(failure("""
            {"polly":1,"items":[{"id":"a","group":"g","title":"t","severity":"warning"},{"id":"a","group":"g","title":"u","severity":"warning"}]}
            """) == "Feed item #2 has the same id as an earlier item: \"a\".")
    }

    @Test func httpErrorsUseTheFeedsMessage() {
        #expect(failure(#"{"error":"Token expired"}"#, statusCode: 401) == "Authentication failed (HTTP 401): Token expired")
        #expect(failure("", statusCode: 403) == "Authentication failed (HTTP 403). Check the credentials.")
        #expect(failure(#"{"error":"Database down"}"#, statusCode: 500) == "The feed returned HTTP 500: Database down")
        #expect(failure("oops", statusCode: 404) == "The feed returned HTTP 404.")
        #expect(failure(#"{"polly":1,"error":"Not configured"}"#) == "The feed reported an error: Not configured")
    }

    @Test func summaryLineUsesTheFeedsNoun() throws {
        let quiet = try status(#"{"polly":1,"okCount":1,"noun":{"one":"ticket","other":"tickets"},"items":[]}"#)
        #expect(quiet.summaryLine == "1 ticket OK")
        let busy = try status("""
            {"polly":1,"okCount":14,"noun":{"one":"ticket","other":"tickets"},"items":[
              {"id":"a","group":"g","title":"t","severity":"critical"},{"id":"b","group":"g","title":"u","severity":"warning"}]}
            """)
        #expect(busy.summaryLine == "16 tickets, 1 crit, 1 warn")
        #expect(busy.summaryParts.map(\.severity) == [nil, .critical, nil, .warning])
    }

    @MainActor @Test func overviewCountsFeedItemsApart() throws {
        let feed = NagiosServer(name: "Tickets", baseURL: URL(string: "https://portal.example.com/feed")!, username: "", kind: .feed)
        let nagios = NagiosServer(name: "monitor", baseURL: URL(string: "https://monitor.example.com")!, username: "")
        let feedStatus = try status(#"{"polly":1,"okCount":16,"items":[]}"#)
        let nagiosStatus = ServerStatus(hosts: HostCounts(up: 10), services: ServiceCounts(ok: 20), problems: [], fetchedAt: fetchedAt)

        let both = MonitorSummary(servers: [nagios, feed], states: [nagios.id: .ok(nagiosStatus), feed.id: .ok(feedStatus)])
        #expect(both.hosts == 10)
        #expect(both.services == 20)
        #expect(both.items == 16)
        #expect(both.quietDetail(now: fetchedAt) == "10 hosts, 20 services and 16 items OK on 2 sources. Last checked 0 s ago.")

        let only = MonitorSummary(servers: [feed], states: [feed.id: .ok(feedStatus)])
        #expect(only.quietDetail(now: fetchedAt) == "16 items OK on 1 source. Last checked 0 s ago.")
    }

    @Test func dueIsShownRelativeToNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DurationFormatting.due(now.addingTimeInterval(6 * 86400 + 60), now: now) == "in 6d")
        #expect(DurationFormatting.due(now.addingTimeInterval(-7200), now: now) == "2h overdue")
        #expect(DurationFormatting.due(now, now: now) == "due now")
    }

    @Test func notificationsFollowTheItemID() {
        let before = [ServiceProblem(host: "g", service: "Old title", severity: .warning, itemID: "a")]
        let renamed = [ServiceProblem(host: "g", service: "New title", severity: .warning, itemID: "a")]
        #expect(NotificationPolicy.changes(previous: before, current: renamed).isEmpty)
        let escalated = [ServiceProblem(host: "g", service: "New title", severity: .critical, itemID: "a")]
        #expect(NotificationPolicy.changes(previous: before, current: escalated).raised.map(\.id) == ["a"])
    }
}
