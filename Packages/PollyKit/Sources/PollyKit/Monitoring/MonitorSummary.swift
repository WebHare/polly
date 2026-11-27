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
    /// `empty`: no servers, or all of them disabled. `waiting`: none has answered yet or all of them are paused.
    public enum Screen: Sendable { case empty, problems, unreachable, waiting, ok }
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
    /// Items of sources that count items instead of hosts and services (feeds).
    public private(set) var items = 0
    /// How many enabled servers answered their last refresh, and when the latest of those answers came.
    public private(set) var answeredServers = 0
    public private(set) var lastFetched: Date?
    /// The first server that could not be reached, with its error.
    public private(set) var unreachable: (server: NagiosServer, message: String)?
    /// Enabled servers that are paused: listed, but not checked or counted.
    public private(set) var paused = 0
    /// There are servers, but every one of them is disabled.
    public let allDisabled: Bool
    private let hasServers: Bool
    /// Servers that are enabled and not paused, and how many of those have a result.
    private var watching = 0
    private var checked = 0

    @MainActor
    public init(servers: [NagiosServer], states: [UUID: MonitorModel.ServerState], hideServicesOnDownHosts: Bool = true) {
        // Disabled servers are left out as if they weren't configured.
        hasServers = servers.contains(where: \.enabled)
        allDisabled = !servers.isEmpty && !hasServers
        var entries: [ProblemEntry] = []
        for server in servers where server.enabled {
            guard !server.isPaused else {
                paused += 1
                continue
            }
            watching += 1
            switch states[server.id] {
            case .ok(let status):
                checked += 1
                hosts += status.hosts.total
                hostsDown += status.hosts.down + status.hosts.unreachable
                if status.itemNoun != nil {
                    items += status.services.total
                } else {
                    services += status.services.total
                }
                answeredServers += 1
                lastFetched = max(lastFetched ?? status.fetchedAt, status.fetchedAt)
                let shown = hideServicesOnDownHosts ? status.problems.hidingServicesOnDownHosts : status.problems
                entries += shown.map { ProblemEntry(server: server, problem: $0) }
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

    /// Every enabled server is paused.
    public var isPaused: Bool { hasServers && watching == 0 }

    /// All problems in display order.
    public var entries: [ProblemEntry] { groups.flatMap(\.entries) }

    public func count(_ severity: Severity) -> Int {
        groups.first { $0.severity == severity }?.entries.count ?? 0
    }

    public var screen: Screen {
        if !hasServers { return .empty }
        // A host can be down while none of its services is listed as a problem.
        if !groups.isEmpty || hostsDown > 0 { return .problems }
        if unreachable != nil { return .unreachable }
        // Nothing checked is not the same as nothing wrong.
        return checked == 0 ? .waiting : .ok
    }

    public var mood: Mood {
        if hostsDown > 0 || count(.critical) > 0 { return .critical }
        if count(.warning) > 0 { return .warning }
        // Paused servers are not a reason to worry: the menu bar shows how many there are instead.
        if !hasServers || isPaused { return .ok }
        return count(.unknown) > 0 || unreachable != nil || checked == 0 ? .unreachable : .ok
    }

    public var headline: String {
        if allDisabled { return "Polly has nothing to watch: all sources are disabled" }
        if !hasServers { return "Polly has nothing to watch yet" }
        if hostsDown > 0 { return "Polly is squawking: \(hostsDown) \(hostsDown == 1 ? "host" : "hosts") down" }
        if count(.critical) > 0 { return "Polly is squawking: \(count(.critical)) critical" }
        if count(.warning) > 0 { return "Polly is fidgeting: \(count(.warning)) \(count(.warning) == 1 ? "warning" : "warnings")" }
        if count(.unknown) > 0 { return "Polly is confused: \(count(.unknown)) unknown" }
        if let unreachable { return "Polly can't reach \(unreachable.server.name)" }
        if checked == 0 { return isPaused ? "Polly is not watching: all sources are paused" : "Polly is checking your sources" }
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

    /// "218 hosts and 930 services OK on 2 sources. Last checked 9 s ago." for the all-quiet screen, with
    /// ", 930 services and 16 items" when a feed answered too.
    public func quietDetail(now: Date) -> String {
        var counted: [String] = []
        if hosts > 0 || services > 0 || items == 0 { counted += ["\(hosts) hosts", "\(services) services"] }
        if items > 0 { counted.append("\(items) \(ItemNoun.items(items))") }
        let what = counted.count > 1 ? counted.dropLast().joined(separator: ", ") + " and " + counted.last! : counted[0]
        var text = "\(what) OK on \(answeredServers) \(answeredServers == 1 ? "source" : "sources")."
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
