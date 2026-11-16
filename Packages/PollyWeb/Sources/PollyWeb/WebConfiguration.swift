import Foundation
import PollyKit
import Vapor

public struct WebConfigurationError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(message: String) { self.message = message }
}

public struct WebConfiguration: Sendable {
    public let settings: PollySettings
    let viewer: ViewerCredentials?
    let redactions: [String]

    struct ViewerCredentials: Sendable {
        let username: String
        let hash: String
    }

    public init(environment: [String: String]) throws {
        guard let path = environment["POLLY_CONFIG"], path.hasPrefix("/") else {
            throw WebConfigurationError(message: "Set POLLY_CONFIG to an absolute configuration file path.")
        }
        let yaml: String
        do { yaml = try String(contentsOfFile: path, encoding: .utf8) }
        catch { throw WebConfigurationError(message: "Could not read POLLY_CONFIG.") }
        var settings: PollySettings
        do { settings = try SettingsFile.parse(yaml) }
        // YAML errors include source lines, which may contain passwords.
        catch { throw WebConfigurationError(message: "POLLY_CONFIG is not valid Polly YAML. Check its syntax and field values.") }
        guard settings.passwordStorage == .file else {
            throw WebConfigurationError(message: "The web service requires passwordStorage: file.")
        }
        var ids = Set<UUID>()
        for index in settings.servers.indices {
            let server = settings.servers[index].server
            guard server.kind == .nagios else {
                throw WebConfigurationError(message: "Server #\(index + 1) must have type: nagios, including paused servers.")
            }
            guard ids.insert(server.id).inserted else {
                throw WebConfigurationError(message: "POLLY_CONFIG contains duplicate server IDs.")
            }
            let url = server.baseURL
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, url.fragment == nil,
                  let parsed = ServerURLParser.parse(url.absoluteString) else {
                throw WebConfigurationError(message: "Server #\(index + 1) needs an HTTP(S) URL without embedded credentials or a fragment.")
            }
            settings.servers[index].server.baseURL = parsed.baseURL
            settings.servers[index].server.notifications = false
        }
        settings.debugLog = false
        self.settings = settings

        switch (environment["POLLY_VIEWER_USERNAME"], environment["POLLY_VIEWER_PASSWORD_HASH_FILE"]) {
        case (nil, nil): viewer = nil
        case (.some(let username), .some(let path)):
            guard !username.isEmpty, !username.contains(":"), !username.contains(where: { $0.isNewline }), path.hasPrefix("/"),
                  let hash = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  hash.range(of: #"^\$2[aby]\$(10|11|12|13|14)\$[./A-Za-z0-9]{53}$"#, options: .regularExpression) != nil,
                  (try? Bcrypt.verify("", created: hash)) != nil else {
                throw WebConfigurationError(message: "Invalid viewer credentials. Supply a username and a readable bcrypt hash file (cost 10 through 14).")
            }
            viewer = ViewerCredentials(username: username, hash: hash)
        default:
            throw WebConfigurationError(message: "Set both POLLY_VIEWER_USERNAME and POLLY_VIEWER_PASSWORD_HASH_FILE.")
        }
        redactions = settings.servers.flatMap { [$0.password ?? "", $0.server.username] }
            + [viewer?.hash ?? "", viewer?.username ?? ""]
    }

    /// Validate the final address received from Vapor's CLI, not just the pre-CLI default.
    func validate(address: BindAddress?) throws {
        let host: String
        switch address {
        case .none: host = "127.0.0.1"
        case .hostname(let value, _): host = value ?? "127.0.0.1"
        case .unixDomainSocket:
            throw WebConfigurationError(message: "Use a TCP listener; Unix sockets are not supported.")
        }
        if !["127.0.0.1", "::1"].contains(host), viewer == nil {
            throw WebConfigurationError(message: "A network listener requires viewer authentication. Configure HTTPS on the reverse proxy before network use.")
        }
    }
}
