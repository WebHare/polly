import Foundation

public enum FeedError: LocalizedError, Equatable, Sendable {
    case notJSON
    case noVersion
    case unsupportedVersion(Int)
    case noItems
    /// Something wrong in the feed itself; the message says what.
    case invalid(String)
    /// The feed answered, but with an `error` instead of items.
    case reported(String)
    /// An HTTP error status, with the feed's `error` message when it sent one.
    case http(Int, String?)
    case redirect
    case invalidResponse
    case transport(String)
    /// A feed file that hasn't changed for longer than its limit (seconds).
    case stale(age: TimeInterval, limit: TimeInterval)
    /// A feed file that can't be read; the message says why.
    case file(String)

    public var errorDescription: String? {
        switch self {
        case .notJSON: "The response is not JSON, so it is not a Polly feed."
        case .noVersion: "The response is not a Polly feed: it has no \"polly\" version."
        case .unsupportedVersion(let version):
            "This feed uses format version \(version), which this version of Polly can't read. Update Polly."
        case .noItems: "The feed has no \"items\" list."
        case .invalid(let message): message
        case .reported(let message): "The feed reported an error: \(message)"
        case .http(let code, let message) where code == 401 || code == 403:
            message.map { "Authentication failed (HTTP \(code)): \($0)" }
                ?? "Authentication failed (HTTP \(code)). Check the credentials."
        case .http(let code, let message): message.map { "The feed returned HTTP \(code): \($0)" } ?? "The feed returned HTTP \(code)."
        case .redirect:
            "The feed redirected the request, which Polly does not follow so your credentials stay with this server. Enter the final URL instead."
        case .invalidResponse: "The server returned an invalid response."
        case .stale(let age, let limit):
            "The file hasn't changed for \(DurationFormatting.coarseDuration(age)) (the limit is "
                + "\(DurationFormatting.coarseDuration(limit))). Is whatever writes it still running?"
        case .file(let message): message
        case .transport(let message): message
        }
    }
}

/// Reads a Polly feed: a JSON document listing what needs attention. The format is described in
/// doc/feed-format.md. Every listed item is a problem; what is fine is only counted (`okCount`).
public enum FeedDocument {
    /// The format versions this Polly reads.
    public static let version = 1

    public static func status(from data: Data, statusCode: Int, fetchedAt: Date) throws -> ServerStatus {
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(statusCode) else {
            throw FeedError.http(statusCode, json?["error"]?.string.flatMap { $0.isEmpty ? nil : $0 })
        }
        guard let json else { throw FeedError.notJSON }
        if let message = json["error"]?.string { throw FeedError.reported(message) }
        guard let version = json["polly"]?.integer else { throw FeedError.noVersion }
        guard version == Self.version else { throw FeedError.unsupportedVersion(version) }
        guard case .array(let rawItems)? = json["items"] else { throw FeedError.noItems }

        let feedLink = json["url"]?.string.flatMap(webLink)
        var okCount = 0
        if let value = json["okCount"] {
            guard let count = value.integer, count >= 0 else {
                throw FeedError.invalid("The feed's \"okCount\" must be a whole number of 0 or more.")
            }
            okCount = count
        }
        var noun = ItemNoun.items
        if let value = json["noun"] {
            guard let one = value["one"]?.string, let other = value["other"]?.string, !one.isEmpty, !other.isEmpty else {
                throw FeedError.invalid("The feed's \"noun\" needs \"one\" and \"other\" texts.")
            }
            noun = ItemNoun(one: one, other: other)
        }

        var services = ServiceCounts(ok: okCount)
        var problems: [ServiceProblem] = []
        var ids = Set<String>()
        for (index, raw) in rawItems.enumerated() {
            let problem = try item(raw, number: index + 1, feedLink: feedLink, fetchedAt: fetchedAt)
            guard ids.insert(problem.id).inserted else {
                throw FeedError.invalid("Feed item #\(index + 1) has the same id as an earlier item: \"\(problem.id)\".")
            }
            switch problem.severity {
            case .critical: services.critical += 1
            case .warning: services.warning += 1
            case .unknown: services.unknown += 1
            case .ok: break
            }
            problems.append(problem)
        }
        // Worst first; the feed's own order within a severity.
        let sorted = problems.enumerated().sorted { ($0.element.severity, $1.offset) > ($1.element.severity, $0.offset) }
            .map(\.element)
        return ServerStatus(hosts: HostCounts(), services: services, problems: sorted, fetchedAt: fetchedAt, itemNoun: noun)
    }

    private static func item(_ raw: JSONValue, number: Int, feedLink: URL?, fetchedAt: Date) throws -> ServiceProblem {
        func fail(_ message: String) -> FeedError { .invalid("Feed item #\(number) \(message)") }
        func text(_ key: String) throws -> String {
            guard let value = raw[key]?.string else { throw fail("has no \"\(key)\".") }
            return value
        }
        func date(_ key: String) throws -> Date? {
            guard let value = raw[key], value != .null else { return nil }
            guard let text = value.string, let date = parseDate(text) else {
                throw fail("has an invalid \"\(key)\" date: use ISO 8601 with a time zone, like 2026-11-27T10:15:00+01:00.")
            }
            return date
        }
        func optionalText(_ key: String) throws -> String {
            guard let value = raw[key], value != .null else { return "" }
            guard let text = value.string else { throw fail("has a \"\(key)\" that is not a text.") }
            return text
        }

        guard let id = raw["id"]?.identifier, !id.isEmpty else { throw fail("has no \"id\".") }
        let group = try text("group")
        let title = try text("title")
        guard !title.isEmpty else { throw fail("has no \"title\".") }
        let severityText = try text("severity")
        let severity: Severity
        switch severityText.lowercased() {
        case "critical": severity = .critical
        case "warning": severity = .warning
        case "unknown": severity = .unknown
        default: throw fail("has severity \"\(severityText)\"; it must be critical, warning or unknown.")
        }
        var acknowledged = false
        if let value = raw["acknowledged"], value != .null {
            guard case .bool(let flag) = value else { throw fail("has an \"acknowledged\" that is not true or false.") }
            acknowledged = flag
        }
        var fields: [ProblemField] = []
        if let value = raw["fields"], value != .null {
            guard case .array(let entries) = value else { throw fail("has a \"fields\" that is not a list.") }
            fields = try entries.map { entry in
                guard let label = entry["label"]?.string, let value = entry["value"]?.string else {
                    throw fail("has an invalid \"fields\" list: each needs a \"label\" and a \"value\" text.")
                }
                return ProblemField(label: label, value: value)
            }
        }
        return ServiceProblem(host: group, service: title, severity: severity, since: try date("since"),
                              output: try optionalText("summary"), longOutput: try optionalText("details"),
                              lastCheck: fetchedAt, acknowledged: acknowledged, itemID: id, due: try date("due"),
                              link: raw["url"]?.string.flatMap(webLink) ?? feedLink, fields: fields)
    }

    /// Only web pages are opened; a feed must not make Polly open files or other apps.
    private static func webLink(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else { return nil }
        return url
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

/// Any JSON value, so the feed can be checked field by field with messages that say what is wrong.
enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var integer: Int? {
        if case .number(let value) = self, value == value.rounded(), abs(value) < 1e15 { return Int(value) }
        return nil
    }

    /// A text, or a whole number written as text.
    var identifier: String? {
        string ?? integer.map(String.init)
    }
}
