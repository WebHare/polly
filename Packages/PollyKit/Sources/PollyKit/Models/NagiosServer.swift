import Foundation

/// A server to monitor: a Nagios server, or a URL that Polly checks itself (see `kind`). The password is not part of this record; `ServerStore` keeps it
/// in the keychain or the settings file depending on its `passwordStorage` setting.
public struct NagiosServer: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Nagios: base URL of the server, without credentials and without the `/nagios/...` path.
    /// URL monitor: the URL to check, without credentials.
    public var baseURL: URL
    public var username: String
    /// When false the server is kept but not polled ("monitoring paused").
    public var enabled: Bool
    public var kind: BackendKind
    /// Show local notifications when this server's problems change.
    public var notifications: Bool

    public init(id: UUID = UUID(), name: String, baseURL: URL, username: String, enabled: Bool = true,
                kind: BackendKind = .nagios, notifications: Bool = false) {
        self.id = id
        self.enabled = enabled
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.kind = kind
        self.notifications = notifications
    }

    /// The statusjson.cgi endpoint for this server.
    public var statusJSONURL: URL {
        baseURL.appending(path: "nagios/cgi-bin/statusjson.cgi")
    }

    /// The client for this server's monitoring system.
    public func makeBackend(password: String?, session: URLSession = .shared, wireLog: WireLog? = nil) -> any MonitorBackend {
        switch kind {
        case .nagios:
            var client = NagiosClient(server: self, password: password, session: session)
            client.wireLog = wireLog
            return client
        case .url:
            var monitor = URLMonitor(server: self, password: password, session: session)
            monitor.wireLog = wireLog
            return monitor
        }
    }
}
