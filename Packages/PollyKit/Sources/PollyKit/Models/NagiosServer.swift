import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A server to monitor: a Nagios server, a URL that Polly checks itself or a Polly feed (see `kind`). The password is not part of this record; `ServerStore` keeps it
/// in the keychain or the settings file depending on its `passwordStorage` setting.
public struct NagiosServer: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Nagios: base URL of the server, without credentials and without the `/nagios/...` path.
    /// URL monitor: the URL to check, without credentials.
    /// Feed: the feed's URL, with its path and query.
    public var baseURL: URL
    public var username: String
    /// When set, the password is sent as the value of this header instead of HTTP Basic authentication, and
    /// `username` is not used.
    public var authHeader: String?
    /// When false the server is kept in the settings but left out everywhere else: not polled, not shown in the
    /// overview ("disabled", the switch in Settings).
    public var enabled: Bool
    /// When set, the server is shown in the overview but not polled or counted, since that moment ("paused", the
    /// switch in the source detail).
    public var pausedSince: Date?
    public var kind: BackendKind
    /// Show local notifications when this server's problems change.
    public var notifications: Bool

    public init(id: UUID = UUID(), name: String, baseURL: URL, username: String, enabled: Bool = true,
                pausedSince: Date? = nil, kind: BackendKind = .nagios, notifications: Bool = false,
                authHeader: String? = nil) {
        self.id = id
        self.enabled = enabled
        self.pausedSince = pausedSince
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.kind = kind
        self.notifications = notifications
        self.authHeader = authHeader
    }

    /// How requests to this server authenticate with `password`.
    public func credentials(password: String?) -> SourceCredentials {
        SourceCredentials(username: authHeader == nil ? username : "", password: password, headerName: authHeader)
    }

    public var isPaused: Bool { pausedSince != nil }

    /// Polled and counted: enabled and not paused.
    public var isActive: Bool { enabled && pausedSince == nil }

    /// The statusjson.cgi endpoint for this server.
    public var statusJSONURL: URL {
        baseURL.appending(path: "nagios/cgi-bin/statusjson.cgi")
    }

    /// The client for this server's monitoring system. Throws when its type is unavailable on this platform.
    public func makeBackend(password: String?, session: URLSession = .shared, wireLog: WireLog? = nil) throws -> any MonitorBackend {
        switch kind {
        case .nagios:
            var client = NagiosClient(server: self, password: password, session: session)
            client.wireLog = wireLog
            return client
        case .url:
            #if canImport(Security)
            var monitor = URLMonitor(server: self, password: password, session: session)
            monitor.wireLog = wireLog
            return monitor
            #else
            throw BackendError("URL monitoring is only supported on Apple platforms.")
            #endif
        case .feed:
            var client = FeedClient(server: self, password: password, session: session)
            client.wireLog = wireLog
            return client
        }
    }
}
