import Foundation

/// A Nagios server to monitor. The password is not part of this record; `ServerStore` keeps it
/// in the keychain or the settings file depending on its `passwordStorage` setting.
public struct NagiosServer: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Base URL of the server, without credentials and without the `/nagios/...` path.
    public var baseURL: URL
    public var username: String
    /// When false the server is kept but not polled ("monitoring paused").
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, baseURL: URL, username: String, enabled: Bool = true) {
        self.id = id
        self.enabled = enabled
        self.name = name
        self.baseURL = baseURL
        self.username = username
    }

    /// The statusjson.cgi endpoint for this server.
    public var statusJSONURL: URL {
        baseURL.appending(path: "nagios/cgi-bin/statusjson.cgi")
    }
}
