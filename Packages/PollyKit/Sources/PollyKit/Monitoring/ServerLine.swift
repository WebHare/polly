import Foundation

/// How one source is shown in a source list: an icon that only says whether Polly can reach it,
/// and one line with what it reports, each problem count a part of its own so it can carry a status icon.
public struct ServerLine: Equatable, Sendable {
    public enum Icon: Equatable, Sendable {
        case disabled, paused, loading, reachable, unreachable
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

    public init(server: NagiosServer, state: MonitorModel.ServerState?, now: Date = .now,
                timeZone: TimeZone = .current, locale: Locale = .current) {
        tint = nil
        guard server.enabled else {
            icon = .disabled
            parts = [Part("Disabled")]
            return
        }
        if let since = server.pausedSince {
            icon = .paused
            parts = [Part("Paused since \(DurationFormatting.moment(since, now: now, timeZone: timeZone, locale: locale)) · not checked")]
            return
        }
        switch state {
        case .ok(let status):
            icon = .reachable
            parts = status.summaryParts
            if let updatedAt = status.updatedAt {
                append(" · updated \(DurationFormatting.ago(now.timeIntervalSince(updatedAt)))", to: &parts)
            }
            // Easy to forget once switched off, and then nobody hears about problems.
            if status.notificationsEnabled == false {
                if parts.last?.severity == nil { parts[parts.count - 1].text += " · " } else { parts.append(Part(" · ")) }
                parts.append(Part("notifications off", .warning))
            }
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

/// Adds plain text to a line, merged with the plain text before it.
private func append(_ text: String, to parts: inout [ServerLine.Part]) {
    if let last = parts.last, last.severity == nil {
        parts[parts.count - 1].text += text
    } else {
        parts.append(ServerLine.Part(text))
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
        let bad = [(services.critical, "crit", Severity.critical), (services.warning, "warn", .warning),
                   (services.unknown, "unknown", .unknown)].filter { $0.0 > 0 }
        if let itemNoun {
            // "16 tickets OK" / "16 tickets, 1 crit, 1 warn"
            add("\(services.total) \(itemNoun(services.total))")
            if bad.isEmpty { add(" OK") }
            for (count, label, severity) in bad {
                add(", ")
                add("\(count) \(label)", severity)
            }
            return parts
        }
        let down = hosts.down + hosts.unreachable
        if down > 0 {
            add("\(hosts.total) hosts, ")
            add("\(down) down", .critical)
        } else {
            add("\(hosts.total) hosts up")
        }
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
