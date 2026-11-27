/* swift test --package-path /absolute/path/to/polly/Packages/PollyKit --filter WebSnapshotTests */
import Foundation
import Testing
@testable import PollyKit

@MainActor
struct WebSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let first = NagiosServer(name: "First", baseURL: URL(string: "http://private.test")!, username: "private-user")
    private let second = NagiosServer(name: "Second", baseURL: URL(string: "http://other.test")!, username: "")

    private func status(at: Date? = nil, pending: Int = 0, problems: [ServiceProblem] = []) -> MonitorModel.ServerState {
        .ok(ServerStatus(hosts: HostCounts(up: pending == 0 ? 1 : 0, pending: pending),
                         services: ServiceCounts(ok: pending == 0 ? 3 : 0, pending: pending),
                         problems: problems, fetchedAt: at ?? now))
    }

    @Test func completeFreshCoverageIsRequiredForHealthy() {
        let complete = WebSnapshot(servers: [first, second], states: [first.id: status(), second.id: status()], now: now)
        #expect(complete.state == .ok)
        #expect(complete.coverage.fresh == 2)
        #expect(complete.counts.hosts == 2)
        #expect(complete.counts.services == 6)
        for state in [MonitorModel.ServerState.loading, .failed("secret error"), status(at: now - 150), status(pending: 1)] {
            let partial = WebSnapshot(servers: [first, second], states: [first.id: status(), second.id: state], now: now)
            #expect(partial.state == .partial)
            #expect(partial.mood == "unreachable")
            #expect(partial.coverage.fresh == (state == status(pending: 1) ? 2 : 1))
        }
    }

    @Test func emptyPausedWaitingUnreachableAndPendingAreDistinct() {
        #expect(WebSnapshot(servers: [], states: [:], now: now).state == .empty)
        var paused = first
        paused.pausedSince = now - 60
        let snapshot = WebSnapshot(servers: [paused], states: [:], now: now)
        #expect(snapshot.state == .paused)
        #expect(snapshot.servers[0].state == .paused)
        // A disabled source is left out, as if it wasn't configured.
        var disabled = second
        disabled.enabled = false
        let withDisabled = WebSnapshot(servers: [paused, disabled], states: [:], now: now)
        #expect(withDisabled.servers.map(\.id) == [paused.id])
        #expect(withDisabled.state == .paused)
        #expect(WebSnapshot(servers: [disabled], states: [:], now: now).state == .empty)
        #expect(WebSnapshot(servers: [first], states: [:], now: now).state == .waiting)
        #expect(WebSnapshot(servers: [first], states: [first.id: .failed("secret")], now: now).state == .unreachable)
        #expect(WebSnapshot(servers: [first], states: [first.id: status(pending: 1)], now: now).state == .waiting)
    }

    @Test func freshAPIResponseDoesNotRefreshOldSourceData() {
        let snapshot = WebSnapshot(servers: [first], states: [first.id: status(at: now - 151)], now: now)
        #expect(snapshot.generatedAt == now)
        #expect(snapshot.servers[0].ageSeconds == 151)
        #expect(snapshot.servers[0].stale)
        #expect(snapshot.servers[0].lastSuccessAt == now - 151)
        #expect(snapshot.state != .ok)
    }

    @Test func failedSourceRetainsTimesButDoesNotHideOtherProblems() {
        let problems = [ServiceProblem(host: "a", service: "warn", severity: .warning),
                        ServiceProblem(host: "b", service: "critical", severity: .critical, acknowledged: true, downtimeDepth: 2)]
        let snapshot = WebSnapshot(servers: [first, second], states: [first.id: status(problems: problems), second.id: .failed("password")],
                                   lastAttempts: [second.id: now], lastSuccesses: [second.id: now - 60], now: now)
        #expect(snapshot.state == .problems)
        #expect(snapshot.mood == "critical")
        #expect(snapshot.coverage.fresh == 1)
        #expect(snapshot.problems.map(\.service) == ["critical", "warn"])
        #expect(snapshot.problems[0].acknowledged)
        #expect(snapshot.problems[0].downtimeDepth == 2)
        #expect(snapshot.servers[1].lastAttemptAt == now)
        #expect(snapshot.servers[1].lastSuccessAt == now - 60)
    }

    /// A down host is one problem named "Host down", unless the user wants its services listed too.
    @Test func downHostIsOneProblem() {
        let problems = [ServiceProblem.host("a", .down), ServiceProblem(host: "a", service: "HTTP", severity: .critical)]
        let snapshot = WebSnapshot(servers: [first], states: [first.id: status(problems: problems)], now: now)
        #expect(snapshot.problems.map(\.service) == ["Host down"])
        let all = WebSnapshot(servers: [first], states: [first.id: status(problems: problems)], now: now,
                              hideServicesOnDownHosts: false)
        #expect(all.problems.map(\.service).sorted() == ["HTTP", "Host down"])
    }

    @Test func publicPayloadDoesNotEncodeConfigurationOrRawErrors() throws {
        let snapshot = WebSnapshot(servers: [first], states: [first.id: .failed("private-user password http://private.test")], now: now)
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        for forbidden in ["private.test", "private-user", "password", "baseURL", "username", "Authorization"] {
            #expect(!json.contains(forbidden))
        }
    }
}
