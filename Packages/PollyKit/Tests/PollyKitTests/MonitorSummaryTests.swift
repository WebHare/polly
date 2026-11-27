import Foundation
import Testing
@testable import PollyKit

@MainActor
@Suite struct MonitorSummaryTests {
    let nagios = NagiosServer(name: "monitor", baseURL: URL(string: "https://monitor.example.com")!, username: "")
    let other = NagiosServer(name: "ops", baseURL: URL(string: "https://ops.example.com")!, username: "")

    private func status(down: Int = 0, _ problems: [ServiceProblem]) -> MonitorModel.ServerState {
        .ok(ServerStatus(hosts: HostCounts(up: 10, down: down),
                         services: ServiceCounts(ok: 20, warning: problems.filter { $0.severity == .warning }.count,
                                                 critical: problems.filter { $0.severity == .critical }.count,
                                                 unknown: problems.filter { $0.severity == .unknown }.count),
                         problems: problems, fetchedAt: Date(timeIntervalSince1970: 1000)))
    }

    @Test func groupsRunCriticalWarningUnknownNewestFirst() {
        let problems = [
            ServiceProblem(host: "a", service: "old warn", severity: .warning, since: Date(timeIntervalSince1970: 10)),
            ServiceProblem(host: "b", service: "unk", severity: .unknown, since: Date(timeIntervalSince1970: 50)),
            ServiceProblem(host: "c", service: "crit", severity: .critical, since: Date(timeIntervalSince1970: 20)),
            ServiceProblem(host: "d", service: "new warn", severity: .warning, since: Date(timeIntervalSince1970: 90)),
            ServiceProblem(host: "e", service: "undated warn", severity: .warning),
        ]
        let summary = MonitorSummary(servers: [nagios], states: [nagios.id: status(down: 1, problems)])
        #expect(summary.groups.map(\.severity) == [.critical, .warning, .unknown])
        #expect(summary.groups[1].entries.map(\.problem.service) == ["new warn", "old warn", "undated warn"])
        #expect(summary.entries.count == 5)
        #expect(summary.screen == .problems)
        #expect(summary.mood == .critical)
        #expect(summary.headline == "Polly is squawking: 1 host down")
        #expect(summary.countsLine == "1 critical · 3 warning · 1 unknown")
        #expect(summary.badge == "1")
    }

    @Test func warningsOnlyFidget() {
        let problems = [ServiceProblem(host: "a", service: "x", severity: .warning),
                        ServiceProblem(host: "a", service: "y", severity: .warning)]
        let summary = MonitorSummary(servers: [nagios], states: [nagios.id: status(problems)])
        #expect(summary.mood == .warning)
        #expect(summary.headline == "Polly is fidgeting: 2 warnings")
        #expect(summary.badge == "2")
    }

    @Test func criticalWithoutHostDown() {
        let summary = MonitorSummary(servers: [nagios],
                                     states: [nagios.id: status([ServiceProblem(host: "a", service: "x", severity: .critical)])])
        #expect(summary.headline == "Polly is squawking: 1 critical")
    }

    @Test func emptyOkAndUnreachableScreens() {
        #expect(MonitorSummary(servers: [], states: [:]).screen == .empty)
        #expect(MonitorSummary(servers: [], states: [:]).headline == "Polly has nothing to watch yet")
        let ok = MonitorSummary(servers: [nagios, other], states: [nagios.id: status([]), other.id: status([])])
        #expect(ok.screen == .ok)
        #expect(ok.mood == .ok)
        #expect(ok.badge == nil)
        #expect(ok.hosts == 20)
        #expect(ok.services == 40)
        let failed = MonitorSummary(servers: [nagios, other], states: [nagios.id: .failed("Timed out."), other.id: status([])])
        #expect(failed.screen == .unreachable)
        #expect(failed.mood == .unreachable)
        #expect(failed.badge == "?")
        #expect(failed.unreachable?.server.name == "monitor")
        #expect(failed.unreachable?.message == "Timed out.")
    }

    /// A disabled or paused server has no state and must not count, whatever is left in `states`.
    @Test func disabledAndPausedServersAreIgnored() {
        var disabled = nagios
        disabled.enabled = false
        var paused = other
        paused.pausedSince = Date(timeIntervalSince1970: 0)
        let summary = MonitorSummary(servers: [disabled, paused], states: [disabled.id: .failed("x"), paused.id: .failed("x")])
        #expect(summary.unreachable == nil)
        #expect(summary.screen == .waiting)
        #expect(summary.headline == "Polly is not watching: all sources are paused")
    }

    /// A host can be down while none of its services is reported as a problem (yet).
    @Test func hostDownWithoutServiceProblemsIsNotQuiet() {
        let summary = MonitorSummary(servers: [nagios], states: [nagios.id: status(down: 1, [])])
        #expect(summary.screen == .problems)
        #expect(summary.mood == .critical)
        #expect(summary.badge == "1")
    }

    /// A host that is down is one line: its own, not one for every service on it.
    @Test func servicesOnADownHostAreHidden() {
        let problems = [
            ServiceProblem.host("a", .down, since: Date(timeIntervalSince1970: 5)),
            ServiceProblem(host: "a", service: "HTTP", severity: .critical, since: Date(timeIntervalSince1970: 50)),
            ServiceProblem(host: "a", service: "Disk", severity: .warning),
            ServiceProblem(host: "b", service: "HTTP", severity: .critical, since: Date(timeIntervalSince1970: 20)),
            ServiceProblem.host("c", .unreachable, since: Date(timeIntervalSince1970: 10)),
        ]
        let summary = MonitorSummary(servers: [nagios], states: [nagios.id: status(down: 2, problems)])
        #expect(summary.entries.map(\.problem.id) == ["b/HTTP", "c/", "a/"])
        #expect(summary.entries.map(\.problem.title) == ["HTTP", "Host unreachable", "Host down"])
        #expect(summary.countsLine == "3 critical")
        #expect(summary.headline == "Polly is squawking: 2 hosts down")
        #expect(summary.badge == "3")
    }

    /// With the filter off, every service problem is listed next to its down host.
    @Test func servicesOnADownHostCanBeShown() {
        let problems = [ServiceProblem.host("a", .down), ServiceProblem(host: "a", service: "HTTP", severity: .critical)]
        let summary = MonitorSummary(servers: [nagios], states: [nagios.id: status(down: 1, problems)],
                                     hideServicesOnDownHosts: false)
        #expect(summary.entries.map(\.problem.id).sorted() == ["a/", "a/HTTP"])
    }

    /// The same host name on another server is another host.
    @Test func aDownHostOnlyHidesItsOwnServersServices() {
        let summary = MonitorSummary(servers: [nagios, other], states: [
            nagios.id: status(down: 1, [ServiceProblem.host("a", .down)]),
            other.id: status([ServiceProblem(host: "a", service: "HTTP", severity: .critical)]),
        ])
        #expect(summary.entries.map(\.problem.id).sorted() == ["a/", "a/HTTP"])
    }

    /// Before the first answer nothing is known, which must not look like "all is well".
    @Test func nothingCheckedYetIsNotOk() {
        for states in [[:], [nagios.id: MonitorModel.ServerState.loading]] {
            let summary = MonitorSummary(servers: [nagios], states: states)
            #expect(summary.screen == .waiting)
            #expect(summary.mood == .unreachable)
            #expect(summary.badge == "?")
            #expect(summary.headline == "Polly is checking your sources")
        }
    }

    @Test func serverLines() {
        guard case .ok(let bad) = status(down: 1, [ServiceProblem(host: "a", service: "x", severity: .critical),
                                                  ServiceProblem(host: "a", service: "y", severity: .warning)]),
              case .ok(let good) = status([]) else { return }
        #expect(bad.summaryLine == "11 hosts, 1 down · 22 services, 1 crit, 1 warn")
        #expect(good.summaryLine == "10 hosts up · 20 services OK")
    }

    /// Each problem count is its own part, so the views can put a small status icon in front of it.
    @Test func serverLineMarksEachProblemCount() {
        let line = ServerLine(server: nagios, state: status(down: 1, [
            ServiceProblem(host: "a", service: "x", severity: .critical),
            ServiceProblem(host: "a", service: "y", severity: .warning),
            ServiceProblem(host: "a", service: "z", severity: .unknown)]))
        #expect(line.icon == .reachable)
        #expect(line.tint == nil)
        #expect(line.parts == [.init("11 hosts, "), .init("1 down", .critical), .init(" · 23 services, "),
                               .init("1 crit", .critical), .init(", "), .init("1 warn", .warning), .init(", "),
                               .init("1 unknown", .unknown)])
        #expect(line.text == "11 hosts, 1 down · 23 services, 1 crit, 1 warn, 1 unknown")
    }

    /// Notifications switched off on the monitoring system itself are easy to forget, so every source line says so.
    @Test func serverLineSaysWhenTheMonitorSendsNoNotifications() {
        guard case .ok(var status) = status([]) else { return }
        status.notificationsEnabled = false
        let line = ServerLine(server: nagios, state: .ok(status))
        #expect(line.parts == [.init("10 hosts up · 20 services OK · "), .init("notifications off", .warning)])
        status.notificationsEnabled = true
        #expect(ServerLine(server: nagios, state: .ok(status)).text == "10 hosts up · 20 services OK")
        status.notificationsEnabled = nil
        #expect(ServerLine(server: nagios, state: .ok(status)).text == "10 hosts up · 20 services OK")
    }

    /// Problems on the monitored hosts don't make the monitor itself look broken.
    @Test func serverIconOnlyShowsWhetherTheMonitorAnswers() {
        let fine = ServerLine(server: nagios, state: status([]))
        #expect(fine.icon == .reachable)
        #expect(fine.parts == [.init("10 hosts up · 20 services OK")])

        let down = ServerLine(server: nagios, state: .failed("The request timed out."))
        #expect(down.icon == .unreachable)
        #expect(down.tint == .critical)
        #expect(down.text == "Unreachable · The request timed out.")

        #expect(ServerLine(server: nagios, state: .loading).icon == .loading)
        #expect(ServerLine(server: nagios, state: nil).text == "https://monitor.example.com")

        var disabled = nagios
        disabled.enabled = false
        let disabledLine = ServerLine(server: disabled, state: .failed("x"))
        #expect(disabledLine.icon == .disabled)
        #expect(disabledLine.text == "Disabled")
        #expect(disabledLine.tint == nil)
    }
}

struct RelativeTimeTests {
    @Test func agoAndUntil() {
        #expect(DurationFormatting.ago(14) == "14 s ago")
        #expect(DurationFormatting.ago(-3) == "0 s ago")
        #expect(DurationFormatting.ago(240) == "4 min ago")
        #expect(DurationFormatting.ago(7300) == "2 h ago")
        #expect(DurationFormatting.until(46) == "in 46 s")
        #expect(DurationFormatting.until(125) == "in 2 min")
        #expect(DurationFormatting.until(-5) == "due now")
    }
}

/// Disabled sources (the switch in Settings) are left out completely; paused sources (the switch in the source
/// detail) are listed, but not checked or counted.
@MainActor
@Suite struct PausedAndDisabledSummaryTests {
    let prod = NagiosServer(name: "prod", baseURL: URL(string: "https://prod.example.com")!, username: "")
    let staging = NagiosServer(name: "staging", baseURL: URL(string: "https://staging.example.com")!, username: "")

    private func warnings(_ count: Int) -> MonitorModel.ServerState {
        .ok(ServerStatus(hosts: HostCounts(up: 1), services: ServiceCounts(ok: 1, warning: count),
                         problems: (0..<count).map { ServiceProblem(host: "h", service: "s\($0)", severity: .warning) },
                         fetchedAt: Date(timeIntervalSince1970: 1000)))
    }

    private var pausedStaging: NagiosServer {
        var server = staging
        server.pausedSince = Date(timeIntervalSince1970: 55_800) // 15:30 UTC
        return server
    }

    @Test func aPausedSourceIsNotCounted() {
        let summary = MonitorSummary(servers: [prod, pausedStaging], states: [prod.id: warnings(1), staging.id: warnings(2)])
        #expect(summary.count(.warning) == 1)
        #expect(summary.paused == 1)
        #expect(summary.mood == .warning)
        #expect(summary.badge == "1")
    }

    @Test func everySourcePausedIsQuietWithThePausedCount() {
        let summary = MonitorSummary(servers: [pausedStaging], states: [:])
        #expect(summary.screen == .waiting)
        #expect(summary.isPaused)
        #expect(summary.headline == "Polly is not watching: all sources are paused")
        #expect(summary.mood == .ok)
        #expect(summary.badge == nil)
        #expect(summary.paused == 1)
    }

    @Test func aDisabledSourceIsLeftOut() {
        var disabled = staging
        disabled.enabled = false
        let summary = MonitorSummary(servers: [prod, disabled], states: [prod.id: warnings(1), staging.id: warnings(2)])
        #expect(summary.count(.warning) == 1)
        #expect(summary.paused == 0)
    }

    @Test func everySourceDisabledHasNothingToWatch() {
        var disabled = staging
        disabled.enabled = false
        let summary = MonitorSummary(servers: [disabled], states: [:])
        #expect(summary.screen == .empty)
        #expect(summary.allDisabled)
        #expect(summary.headline == "Polly has nothing to watch: all sources are disabled")
        #expect(summary.mood == .ok)
        #expect(summary.badge == nil)
        #expect(!MonitorSummary(servers: [], states: [:]).allDisabled)
    }

    /// A disabled source that is also paused is just disabled.
    @Test func aDisabledPausedSourceIsNotCountedAsPaused() {
        var both = pausedStaging
        both.enabled = false
        #expect(MonitorSummary(servers: [prod, both], states: [:]).paused == 0)
    }

    @Test func sourceLines() {
        let utc = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let now = Date(timeIntervalSince1970: 57_600)
        let today = ServerLine(server: pausedStaging, state: warnings(2), now: now, timeZone: utc, locale: locale)
        #expect(today.icon == .paused)
        #expect(today.text == "Paused since 15:30 · not checked")
        let earlier = ServerLine(server: pausedStaging, state: nil, now: now + 3 * 86400, timeZone: utc, locale: locale)
        // Another day also names the date; its exact form is up to the locale.
        #expect(earlier.text.hasPrefix("Paused since ") && earlier.text.contains("1970") && earlier.text.contains("15:30"))
        var disabled = pausedStaging
        disabled.enabled = false
        let line = ServerLine(server: disabled, state: nil)
        #expect(line.icon == .disabled)
        #expect(line.text == "Disabled")
    }
}
