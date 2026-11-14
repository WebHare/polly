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

public struct ServiceProblem: Identifiable, Hashable, Sendable {
    public var host: String
    public var service: String
    public var severity: Severity
    /// When the service entered its current state (Nagios `last_state_change`).
    public var since: Date?
    public var id: String { "\(host)/\(service)" }

    public init(host: String, service: String, severity: Severity, since: Date? = nil) {
        self.host = host
        self.service = service
        self.severity = severity
        self.since = since
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
