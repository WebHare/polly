import Foundation

/// A whitelist of display data, never the configuration or raw transport errors. Built atomically on the
/// monitor's actor; encoding and HTTP delivery can then happen off that actor.
public struct WebSnapshot: Codable, Sendable {
    public enum State: String, Codable, Sendable { case empty, paused, waiting, partial, unreachable, problems, ok }
    public struct Coverage: Codable, Sendable {
        public let active: Int
        public let fresh: Int
    }
    public struct Counts: Codable, Sendable {
        public let hosts: Int
        public let hostsDown: Int
        public let services: Int
        public let critical: Int
        public let warning: Int
        public let unknown: Int
        public let pending: Int
    }
    public struct Server: Codable, Sendable {
        public enum State: String, Codable, Sendable { case loading, ok, unreachable, paused }
        public let id: UUID
        public let name: String
        public let state: State
        public let stale: Bool
        public let ageSeconds: TimeInterval?
        public let lastAttemptAt: Date?
        public let lastSuccessAt: Date?
        public let message: String?
    }
    public struct Problem: Codable, Sendable {
        public let id: String
        public let serverID: UUID
        public let serverName: String
        public let host: String
        public let service: String
        public let severity: String
        public let since: Date?
        public let output: String
        public let longOutput: String
        public let lastCheck: Date?
        public let nextCheck: Date?
        public let acknowledged: Bool
        public let downtimeDepth: Int
        public let checkAttempt: String?
    }

    public let generatedAt: Date
    public let staleAfterSeconds: TimeInterval
    public let state: State
    public let mood: String
    public let headline: String
    public let coverage: Coverage
    public let counts: Counts
    public let servers: [Server]
    public let problems: [Problem]
    public let nextPollAt: Date?

    @MainActor
    public init(servers: [NagiosServer], states: [UUID: MonitorModel.ServerState],
                lastAttempts: [UUID: Date] = [:], lastSuccesses: [UUID: Date] = [:],
                nextPollAt: Date? = nil, now: Date = .now, redactions: [String] = []) {
        func clean(_ text: String) -> String {
            redactions.filter { !$0.isEmpty }.reduce(text) { $0.replacingOccurrences(of: $1, with: "[redacted]") }
        }
        generatedAt = now
        let freshnessLimit: TimeInterval = 150
        staleAfterSeconds = freshnessLimit
        self.nextPollAt = nextPollAt
        let summary = MonitorSummary(servers: servers, states: states)
        let active = servers.filter(\.enabled)
        let results = active.compactMap { server -> ServerStatus? in
            if case .ok(let result) = states[server.id] { return result }
            return nil
        }
        self.servers = servers.map { server in
            let state: Server.State
            var success = lastSuccesses[server.id]
            if !server.enabled { state = .paused }
            else {
                switch states[server.id] {
                case .ok(let result): state = .ok; success = result.fetchedAt
                case .failed: state = .unreachable
                case .loading, nil: state = .loading
                }
            }
            let age = success.map { max(0, now.timeIntervalSince($0)) }
            return Server(id: server.id, name: clean(server.name), state: state,
                          stale: state != .paused && (age == nil || age! >= freshnessLimit), ageSeconds: age,
                          lastAttemptAt: lastAttempts[server.id], lastSuccessAt: success,
                          message: state == .unreachable ? "Monitoring server is unreachable." : nil)
        }
        coverage = Coverage(active: active.count, fresh: self.servers.filter { $0.state == .ok && !$0.stale }.count)
        counts = Counts(hosts: summary.hosts, hostsDown: summary.hostsDown, services: summary.services,
                        critical: results.reduce(0) { $0 + $1.services.critical },
                        warning: results.reduce(0) { $0 + $1.services.warning },
                        unknown: results.reduce(0) { $0 + $1.services.unknown },
                        pending: results.reduce(0) { $0 + $1.hosts.pending + $1.services.pending })
        problems = summary.entries.map { entry in
            let p = entry.problem
            return Problem(id: clean(entry.id), serverID: entry.server.id, serverName: clean(entry.server.name),
                           host: clean(p.host), service: clean(p.service), severity: p.severity.word,
                           since: p.since, output: clean(p.output), longOutput: clean(p.longOutput),
                           lastCheck: p.lastCheck, nextCheck: p.nextCheck, acknowledged: p.acknowledged,
                           downtimeDepth: p.downtimeDepth, checkAttempt: p.checkAttempt?.label)
        }
        if servers.isEmpty { state = .empty }
        else if active.isEmpty { state = .paused }
        else if summary.screen == .problems || counts.critical + counts.warning + counts.unknown > 0 { state = .problems }
        else if self.servers.contains(where: { $0.state == .unreachable }) && results.isEmpty { state = .unreachable }
        else if results.isEmpty || (counts.pending > 0 && results.allSatisfy({ $0.hosts.up + $0.services.ok == 0 })) { state = .waiting }
        else if coverage.fresh != coverage.active || counts.pending > 0 { state = .partial }
        else { state = .ok }

        if summary.mood == .critical || counts.critical > 0 { mood = "critical" }
        else if summary.mood == .warning || counts.warning > 0 { mood = "warning" }
        else { mood = state == .ok ? "ok" : "unreachable" }
        switch state {
        case .empty: headline = "Polly has nothing to watch yet"
        case .paused: headline = "Polly is not watching: all servers are paused"
        case .waiting: headline = "Polly is checking your servers"
        case .partial: headline = "Polly is missing current data from some checks"
        case .unreachable: headline = "Polly can't reach the monitoring servers"
        case .ok: headline = "Polly is quiet. Go back to sleep."
        case .problems: headline = summary.screen == .problems ? clean(summary.headline) : "Polly has checks that need attention"
        }
    }
}
