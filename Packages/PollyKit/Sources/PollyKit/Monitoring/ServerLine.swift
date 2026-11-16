import Foundation

/// How one server is shown in a server list: an icon that only says whether Polly can reach the monitor,
/// and one line with what it reports, each problem count a part of its own so it can carry a status icon.
public struct ServerLine: Equatable, Sendable {
    public enum Icon: Equatable, Sendable {
        case paused, loading, reachable, unreachable
    }

    public struct Part: Equatable, Sendable {
        public var text: String
        /// Set on a problem count ("1 crit", "2 down"); nil for the text around it.
        public var severity: Severity?

        public init(_ text: String, _ severity: Severity? = nil) {
            self.text = text
            self.severity = severity
        }
    }

    public var icon: Icon
    public var parts: [Part]
    /// Color of the whole line, for an unreachable monitor.
    public var tint: Severity?

    public var text: String { parts.map(\.text).joined() }

    public init(server: NagiosServer, state: MonitorModel.ServerState?) {
        tint = nil
        guard server.enabled else {
            icon = .paused
            parts = [Part("Monitoring paused")]
            return
        }
        switch state {
        case .ok(let status):
            icon = .reachable
            parts = status.summaryParts
        case .failed(let message):
            icon = .unreachable
            parts = [Part("Unreachable · \(message)")]
            tint = .critical
        case .loading, nil:
            icon = .loading
            parts = [Part(server.baseURL.absoluteString)]
        }
    }
}

public extension ServerStatus {
    /// "170 hosts, 1 down · 714 services, 1 crit, 3 warn", or "48 hosts up · 216 services OK" when all is well.
    var summaryLine: String { summaryParts.map(\.text).joined() }

    /// `summaryLine` with each problem count as a separate part, neighbouring plain text merged.
    var summaryParts: [ServerLine.Part] {
        var parts: [ServerLine.Part] = []
        func add(_ text: String, _ severity: Severity? = nil) {
            if severity == nil, let last = parts.last, last.severity == nil {
                parts[parts.count - 1].text += text
            } else {
                parts.append(.init(text, severity))
            }
        }
        let down = hosts.down + hosts.unreachable
        if down > 0 {
            add("\(hosts.total) hosts, ")
            add("\(down) down", .critical)
        } else {
            add("\(hosts.total) hosts up")
        }
        let bad = [(services.critical, "crit", Severity.critical), (services.warning, "warn", .warning),
                   (services.unknown, "unknown", .unknown)].filter { $0.0 > 0 }
        if bad.isEmpty {
            add(" · \(services.total) services OK")
        } else {
            add(" · \(services.total) services")
            for (count, label, severity) in bad {
                add(", ")
                add("\(count) \(label)", severity)
            }
        }
        return parts
    }
}
