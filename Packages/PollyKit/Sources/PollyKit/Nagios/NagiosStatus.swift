import Foundation

/// Common envelope of every statusjson.cgi response.
struct StatusJSONEnvelope<DataPayload: Decodable>: Decodable {
    struct Result: Decodable {
        var type_code: Int
        var type_text: String?
        var message: String?
        var query: String?
    }
    var result: Result
    var data: DataPayload?
}

public struct HostCounts: Equatable, Sendable, Decodable {
    public var up = 0, down = 0, unreachable = 0, pending = 0
    public init(up: Int = 0, down: Int = 0, unreachable: Int = 0, pending: Int = 0) {
        self.up = up; self.down = down; self.unreachable = unreachable; self.pending = pending
    }
}

public struct ServiceCounts: Equatable, Sendable, Decodable {
    public var ok = 0, warning = 0, critical = 0, unknown = 0, pending = 0
    public init(ok: Int = 0, warning: Int = 0, critical: Int = 0, unknown: Int = 0, pending: Int = 0) {
        self.ok = ok; self.warning = warning; self.critical = critical; self.unknown = unknown; self.pending = pending
    }
}

/// Overall severity, ordered so `max()` gives the worst.
public enum Severity: Int, Comparable, Sendable {
    case ok, unknown, warning, critical

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where a check is in its retries: a problem only counts as confirmed ("hard") after the last attempt.
public struct CheckAttempt: Hashable, Sendable {
    public var hard: Bool
    public var current: Int
    public var max: Int

    public init(hard: Bool, current: Int, max: Int) {
        self.hard = hard
        self.current = current
        self.max = max
    }

    public var label: String { "\(hard ? "HARD" : "SOFT") \(current)/\(max)" }
}

/// Why a host itself is a problem.
public enum HostState: String, Hashable, Sendable {
    case down, unreachable
}

/// A check that is not OK: a service, or the host itself when `hostState` is set.
public struct ServiceProblem: Identifiable, Hashable, Sendable {
    public var host: String
    /// Empty for a host problem.
    public var service: String
    /// Set when the problem is the host itself being down or unreachable.
    public var hostState: HostState?
    public var severity: Severity
    /// When the service entered its current state (Nagios `last_state_change`).
    public var since: Date?
    /// First line of the check's output.
    public var output: String
    /// Further output lines, separated by newlines.
    public var longOutput: String
    public var lastCheck: Date?
    public var acknowledged: Bool
    /// Number of scheduled downtimes the check is currently in; 0 means none.
    public var downtimeDepth: Int
    public var checkAttempt: CheckAttempt?
    public var nextCheck: Date?
    public var id: String { "\(host)/\(service)" }

    public var isHost: Bool { hostState != nil }

    /// "DOWN" / "UNREACHABLE" for the status pill of a host problem; nil for a service, which shows its severity.
    public var stateLabel: String? { hostState?.rawValue.uppercased() }

    /// What to show after the host name: the service, or "Host down" / "Host unreachable".
    public var title: String {
        switch hostState {
        case .down: "Host down"
        case .unreachable: "Host unreachable"
        case nil: service
        }
    }

    /// " · acknowledged · in downtime": the states to show after the service name, each with its separator.
    public var stateNote: String {
        [acknowledged ? "acknowledged" : nil, downtimeDepth > 0 ? "in downtime" : nil]
            .compactMap { $0 }.map { " · \($0)" }.joined()
    }

    public init(host: String, service: String, severity: Severity, since: Date? = nil, output: String = "",
                longOutput: String = "", lastCheck: Date? = nil, acknowledged: Bool = false, downtimeDepth: Int = 0,
                checkAttempt: CheckAttempt? = nil, nextCheck: Date? = nil, hostState: HostState? = nil) {
        self.host = host
        self.service = hostState == nil ? service : ""
        self.hostState = hostState
        self.severity = severity
        self.since = since
        self.output = output
        self.longOutput = longOutput
        self.lastCheck = lastCheck
        self.acknowledged = acknowledged
        self.downtimeDepth = downtimeDepth
        self.checkAttempt = checkAttempt
        self.nextCheck = nextCheck
    }
}

public extension ServiceProblem {
    /// The host itself is down or unreachable; that is always critical.
    static func host(_ host: String, _ state: HostState, since: Date? = nil, output: String = "", longOutput: String = "",
                     lastCheck: Date? = nil, acknowledged: Bool = false, downtimeDepth: Int = 0,
                     checkAttempt: CheckAttempt? = nil, nextCheck: Date? = nil) -> ServiceProblem {
        ServiceProblem(host: host, service: "", severity: .critical, since: since, output: output, longOutput: longOutput,
                       lastCheck: lastCheck, acknowledged: acknowledged, downtimeDepth: downtimeDepth,
                       checkAttempt: checkAttempt, nextCheck: nextCheck, hostState: state)
    }
}

public extension Array where Element == ServiceProblem {
    /// The hosts that are down or unreachable themselves.
    var downHosts: Set<String> { Set(filter(\.isHost).map(\.host)) }

    /// The problems to show: a host that is down stands for everything on it, so its services are left out.
    var hidingServicesOnDownHosts: [ServiceProblem] {
        let down = downHosts
        return filter { $0.isHost || !down.contains($0.host) }
    }
}

public struct ServerStatus: Equatable, Sendable {
    public var hosts: HostCounts
    public var services: ServiceCounts
    public var problems: [ServiceProblem]
    public var fetchedAt: Date

    public var severity: Severity {
        if hosts.down + hosts.unreachable > 0 || services.critical > 0 { return .critical }
        if services.warning > 0 { return .warning }
        if services.unknown > 0 { return .unknown }
        return .ok
    }
}

// statusjson.cgi bit values for service states (see cgi/statusjson.c / include/statusdata.h).
enum NagiosServiceState: Int {
    case pending = 1, ok = 2, warning = 4, unknown = 8, critical = 16

    var severity: Severity? {
        switch self {
        case .warning: .warning
        case .unknown: .unknown
        case .critical: .critical
        case .ok, .pending: nil
        }
    }
}

// statusjson.cgi bit values for host states.
enum NagiosHostState: Int {
    case pending = 1, up = 2, down = 4, unreachable = 8

    var problem: HostState? {
        switch self {
        case .down: .down
        case .unreachable: .unreachable
        case .up, .pending: nil
        }
    }
}
