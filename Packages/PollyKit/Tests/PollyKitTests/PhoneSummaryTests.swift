import Foundation
import Testing
@testable import PollyKit

/// The pieces of `MonitorSummary` and `ServiceProblem` that the iPhone screens show.
@MainActor
@Suite struct PhoneSummaryTests {
    let nagios = NagiosServer(name: "monitor", baseURL: URL(string: "https://monitor.example.com")!, username: "")
    let other = NagiosServer(name: "ops", baseURL: URL(string: "https://ops.example.com")!, username: "")

    private func status(down: Int = 0, fetchedAt: TimeInterval = 1000, _ problems: [ServiceProblem] = []) -> MonitorModel.ServerState {
        .ok(ServerStatus(hosts: HostCounts(up: 10, down: down),
                         services: ServiceCounts(ok: 20, critical: problems.filter { $0.severity == .critical }.count),
                         problems: problems, fetchedAt: Date(timeIntervalSince1970: fetchedAt)))
    }

    @Test func headlineSplitsPollysWordsFromTheCount() {
        let summary = MonitorSummary(servers: [nagios], states: [nagios.id: status(down: 1, [
            ServiceProblem(host: "a", service: "x", severity: .critical),
        ])])
        #expect(summary.headlineKicker == "Polly is squawking")
        #expect(summary.headlineTitle == "1 host down")
    }

    @Test func headlineWithoutColonIsAllTitle() {
        let summary = MonitorSummary(servers: [nagios], states: [nagios.id: status()])
        #expect(summary.headlineKicker == nil)
        #expect(summary.headlineTitle == "Polly is quiet. Go back to sleep.")
    }

    @Test func quietDetailCountsAnsweredServersAndLastCheck() {
        let summary = MonitorSummary(servers: [nagios, other],
                                     states: [nagios.id: status(fetchedAt: 1000), other.id: status(fetchedAt: 1030)])
        #expect(summary.quietDetail(now: Date(timeIntervalSince1970: 1039))
                == "20 hosts and 40 services OK on 2 servers. Last checked 9 s ago.")
    }

    @Test func quietDetailSkipsServersThatDidNotAnswer() {
        let summary = MonitorSummary(servers: [nagios, other], states: [nagios.id: status(), other.id: .loading])
        #expect(summary.quietDetail(now: Date(timeIntervalSince1970: 1000))
                == "10 hosts and 20 services OK on 1 server. Last checked 0 s ago.")
    }

    @Test func problemStateNote() {
        var problem = ServiceProblem(host: "a", service: "SMTP queue", severity: .warning)
        #expect(problem.stateNote == "")
        problem.acknowledged = true
        #expect(problem.stateNote == " · acknowledged")
        problem.downtimeDepth = 1
        #expect(problem.stateNote == " · acknowledged · in downtime")
    }
}
