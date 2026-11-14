import Foundation

// Everything the app needs from a monitoring system. Nagios is the first implementation; Icinga and a
// plain "check this URL" backend are planned, so nothing in here may mention CGI names, HTML or Nagios
// status bits.

/// The type of monitoring system a server runs. Stored as `type` in polly.yaml.
public enum BackendKind: String, Sendable, CaseIterable {
    case nagios

    /// The name of the monitoring system as shown to the user.
    public var displayName: String {
        switch self {
        case .nagios: "Nagios"
        }
    }
}

public struct BackendCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `checkURL(for:)` and `relatedURL(for:)` work.
    public static let links = BackendCapabilities(rawValue: 1 << 0)
    /// `prepareCommand(_:for:)` works.
    public static let commands = BackendCapabilities(rawValue: 1 << 1)
}

public enum CommandKind: String, Sendable {
    case acknowledge, downtime
}

/// What the user fills in for a command. `start`/`end` are only used for a downtime.
public struct CommandInput: Equatable, Sendable {
    public var author: String
    public var comment: String
    public var start: String
    public var end: String
    public var notify: Bool

    public init(author: String = "", comment: String = "", start: String = "", end: String = "", notify: Bool = false) {
        self.author = author
        self.comment = comment
        self.start = start
        self.end = end
        self.notify = notify
    }
}

/// A command form fetched from the server, ready to be filled in. Nothing is sent until `submit`.
public protocol PreparedCommand: Sendable {
    var kind: CommandKind { get }
    var problem: ServiceProblem { get }
    /// Proposed values. `start`/`end` are in the notation and time zone the server itself uses.
    var defaults: CommandInput { get }
    /// Runs the same checks as `submit` without sending anything.
    func validate(_ input: CommandInput) throws
    /// Sends the command once. It is never retried: a second attempt could acknowledge or schedule twice.
    func submit(_ input: CommandInput) async throws
}

public struct BackendError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public protocol MonitorBackend: Sendable {
    var capabilities: BackendCapabilities { get }
    func testConnection() async throws
    func fetchStatus() async throws -> ServerStatus
    /// The page for this check in the monitoring system's web UI, to open in the browser.
    func checkURL(for problem: ServiceProblem) throws -> URL
    /// A link configured for the check (action or notes URL), resolved by the monitoring system.
    func relatedURL(for problem: ServiceProblem) async throws -> URL
    /// Fetches what is needed to send a command, without sending it.
    func prepareCommand(_ kind: CommandKind, for problem: ServiceProblem) async throws -> any PreparedCommand
}

public extension MonitorBackend {
    var capabilities: BackendCapabilities { [] }

    func checkURL(for problem: ServiceProblem) throws -> URL {
        throw BackendError("Opening checks is not supported for this server type.")
    }

    func relatedURL(for problem: ServiceProblem) async throws -> URL {
        throw BackendError("Check links are not supported for this server type.")
    }

    func prepareCommand(_ kind: CommandKind, for problem: ServiceProblem) async throws -> any PreparedCommand {
        throw BackendError("Commands are not supported for this server type.")
    }
}
