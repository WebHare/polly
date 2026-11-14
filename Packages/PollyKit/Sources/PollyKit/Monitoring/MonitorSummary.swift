import Foundation

/// A problem together with the server it was reported by.
public struct ProblemEntry: Identifiable, Hashable, Sendable {
    public var server: NagiosServer
    public var problem: ServiceProblem
    public var id: String { "\(server.id)/\(problem.id)" }

    public init(server: NagiosServer, problem: ServiceProblem) {
        self.server = server
        self.problem = problem
    }
}

/// Everything the overview shows, derived from the servers and their latest state: which screen, the
/// problems grouped by severity, Polly's mood and the sentence that goes with it.
public struct MonitorSummary: Sendable {
    public enum Screen: Sendable { case empty, problems, unreachable, ok }
    public enum Mood: Sendable { case ok, warning, critical, unreachable }

    public struct Group: Identifiable, Sendable {
        public var severity: Severity
        public var entries: [ProblemEntry]
        public var id: Severity { severity }
    }

    /// Critical, then warning, then unknown; newest first inside a group.
    public private(set) var groups: [Group] = []
    public private(set) var hosts = 0
    public private(set) var hostsDown = 0
    public private(set) var services = 0
    /// How many enabled servers answered their last refresh, and when the latest of those answers came.
    public private(set) var answeredServers = 0
    public private(set) var lastFetched: Date?
    /// The first server that could not be reached, with its error.
    public private(set) var unreachable: (server: NagiosServer, message: String)?
    private let hasServers: Bool

    @MainActor
    public init(servers: [NagiosServer], states: [UUID: MonitorModel.ServerState]) {
        hasServers = !servers.isEmpty
        var entries: [ProblemEntry] = []
        for server in servers where server.enabled {
            switch states[server.id] {
            case .ok(let status):
                hosts += status.hosts.total
                hostsDown += status.hosts.down + status.hosts.unreachable
                services += status.services.total
                answeredServers += 1
                lastFetched = max(lastFetched ?? status.fetchedAt, status.fetchedAt)
                entries += status.problems.map { ProblemEntry(server: server, problem: $0) }
            case .failed(let message):
                if unreachable == nil { unreachable = (server, message) }
            case .loading, nil:
                break
            }
        }
        groups = [Severity.critical, .warning, .unknown].compactMap { severity in
            let matching = entries.filter { $0.problem.severity == severity }
                .sorted { ($0.problem.since ?? .distantPast) > ($1.problem.since ?? .distantPast) }
            return matching.isEmpty ? nil : Group(severity: severity, entries: matching)
        }
    }

    /// All problems in display order.
    public var entries: [ProblemEntry] { groups.flatMap(\.entries) }

    public func count(_ severity: Severity) -> Int {
        groups.first { $0.severity == severity }?.entries.count ?? 0
    }

    public var screen: Screen {
        if !hasServers { return .empty }
        if !groups.isEmpty { return .problems }
        return unreachable == nil ? .ok : .unreachable
    }

    public var mood: Mood {
        if hostsDown > 0 || count(.critical) > 0 { return .critical }
        if count(.warning) > 0 { return .warning }
        return count(.unknown) > 0 || unreachable != nil ? .unreachable : .ok
    }

    public var headline: String {
        if !hasServers { return "Polly has nothing to watch yet" }
        if hostsDown > 0 { return "Polly is squawking: \(hostsDown) \(hostsDown == 1 ? "host" : "hosts") down" }
        if count(.critical) > 0 { return "Polly is squawking: \(count(.critical)) critical" }
        if count(.warning) > 0 { return "Polly is fidgeting: \(count(.warning)) \(count(.warning) == 1 ? "warning" : "warnings")" }
        if count(.unknown) > 0 { return "Polly is confused: \(count(.unknown)) unknown" }
        if let unreachable { return "Polly can't reach \(unreachable.server.name)" }
        return "Polly is quiet. Go back to sleep."
    }

    /// Polly's words before the colon of the headline ("Polly is squawking"); nil when the headline has none.
    public var headlineKicker: String? {
        headlineParts.count == 2 ? headlineParts[0] : nil
    }

    /// The headline after the colon ("1 host down"), or all of it when there is no colon.
    public var headlineTitle: String { headlineParts.last ?? headline }

    private var headlineParts: [String] {
        headline.split(separator: ": ", maxSplits: 1).map(String.init)
    }

    /// "218 hosts and 930 services OK on 2 servers. Last checked 9 s ago." for the all-quiet screen.
    public func quietDetail(now: Date) -> String {
        var text = "\(hosts) hosts and \(services) services OK on \(answeredServers) \(answeredServers == 1 ? "server" : "servers")."
        if let lastFetched {
            text += " Last checked \(DurationFormatting.ago(now.timeIntervalSince(lastFetched)))."
        }
        return text
    }

    /// "2 critical · 3 warning · 1 unknown", leaving out what is zero.
    public var countsLine: String {
        groups.map { "\($0.entries.count) \($0.severity.word)" }.joined(separator: " · ")
    }

    /// The number next to the menu bar icon; nil when there is nothing to count.
    public var badge: String? {
        switch mood {
        case .ok: nil
        case .critical: "\(max(count(.critical), hostsDown))"
        case .warning: "\(count(.warning))"
        case .unreachable: count(.unknown) > 0 ? "\(count(.unknown))" : "?"
        }
    }
}

extension Severity {
    var word: String {
        switch self {
        case .ok: "ok"
        case .warning: "warning"
        case .unknown: "unknown"
        case .critical: "critical"
        }
    }
}

public extension HostCounts {
    var total: Int { up + down + unreachable + pending }
}

public extension ServiceCounts {
    var total: Int { ok + warning + critical + unknown + pending }
}

public extension ServerStatus {
    /// "170 hosts, 1 down · 714 services, 1 crit, 3 warn", or "48 hosts up · 216 services OK" when all is well.
    var summaryLine: String {
        let down = hosts.down + hosts.unreachable
        let hostPart = down > 0 ? "\(hosts.total) hosts, \(down) down" : "\(hosts.total) hosts up"
        let bad = [(services.critical, "crit"), (services.warning, "warn"), (services.unknown, "unknown")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        let servicePart = bad.isEmpty ? "\(services.total) services OK" : (["\(services.total) services"] + bad).joined(separator: ", ")
        return "\(hostPart) · \(servicePart)"
    }
}
