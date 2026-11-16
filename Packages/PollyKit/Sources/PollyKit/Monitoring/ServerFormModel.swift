import Foundation
import Observation

/// Backs the server form: adding a server, editing one, or adding a copy of one. Parses pasted URLs and runs
/// the connectivity check.
@MainActor
@Observable
public final class ServerFormModel {
    public enum CheckState: Equatable {
        case idle
        case checking
        case succeeded
        case failed(String)
    }

    /// What the form is for.
    public enum Purpose: Equatable, Sendable {
        case add
        /// Saves over this server, keeping its identity, switch and bell.
        case edit(NagiosServer)
        /// Adds a new server prefilled from this one.
        case duplicate(NagiosServer)
    }

    public let purpose: Purpose

    /// What is being added. Decides how the URL is read and which backend tests it.
    public var kind: BackendKind {
        didSet {
            guard kind != oldValue else { return }
            checkState = .idle
        }
    }
    public var name = ""
    public var username = ""
    public var password = ""
    public private(set) var checkState: CheckState = .idle

    /// The URL field. Setting a URL containing `user:pass@` moves those into the
    /// username/password fields and strips them from the URL.
    public var urlText = "" {
        didSet {
            guard urlText != oldValue else { return }
            checkState = .idle
            extractCredentials()
        }
    }

    /// Receives the connection test's traffic when set.
    @ObservationIgnored public var wireLog: WireLog?
    @ObservationIgnored private let session: URLSession
    /// The password the edited server had, to tell whether the connection changed.
    @ObservationIgnored private let originalPassword: String

    public init(kind: BackendKind = .nagios, session: URLSession = .shared) {
        purpose = .add
        self.kind = kind
        self.session = session
        originalPassword = ""
    }

    public convenience init(editing server: NagiosServer, password: String?, session: URLSession = .shared) {
        self.init(purpose: .edit(server), from: server, name: Self.formName(for: server), password: password,
                  session: session)
    }

    public convenience init(duplicating server: NagiosServer, password: String?, session: URLSession = .shared) {
        let name = Self.formName(for: server)
        self.init(purpose: .duplicate(server), from: server, name: name.isEmpty ? "" : "\(name) copy",
                  password: password, session: session)
    }

    private init(purpose: Purpose, from server: NagiosServer, name: String, password: String?, session: URLSession) {
        self.purpose = purpose
        self.session = session
        kind = server.kind
        urlText = server.baseURL.absoluteString
        self.name = name
        username = server.username
        self.password = password ?? ""
        originalPassword = password ?? ""
    }

    /// A name that is just the URL's host is the default, so it is left empty to keep following the URL.
    private static func formName(for server: NagiosServer) -> String {
        server.name == server.baseURL.host() ? "" : server.name
    }

    public var isEditing: Bool {
        if case .edit = purpose { return true }
        return false
    }

    public var parsedURL: URL? { parse(urlText)?.baseURL }
    public var canSubmit: Bool { parsedURL != nil && checkState != .checking }

    /// False when an edit only changed the name, so saving doesn't wait for (or fail on) the server.
    public var needsConnectionTest: Bool {
        guard case .edit(let original) = purpose else { return true }
        return parsedURL != original.baseURL || kind != original.kind || username != original.username
            || password != originalPassword
    }

    public func makeServer() -> NagiosServer? {
        guard let url = parsedURL else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var server = NagiosServer(name: trimmedName.isEmpty ? (url.host() ?? url.absoluteString) : trimmedName,
                                  baseURL: url,
                                  username: username,
                                  kind: kind)
        switch purpose {
        case .add:
            break
        case .edit(let original):
            server.id = original.id
            server.enabled = original.enabled
            server.notifications = original.notifications
        case .duplicate(let original):
            server.notifications = original.notifications
        }
        return server
    }

    /// Runs the connectivity check. Returns true when the server answered correctly.
    @discardableResult
    public func testConnection() async -> Bool {
        guard let server = makeServer() else {
            checkState = .failed("Please enter a valid http(s) URL.")
            return false
        }
        checkState = .checking
        do {
            try await server.makeBackend(password: password.isEmpty ? nil : password, session: session, wireLog: wireLog)
                .testConnection()
            checkState = .succeeded
            return true
        } catch {
            checkState = .failed(error.localizedDescription)
            return false
        }
    }

    private func extractCredentials() {
        guard urlText.contains("@"), let parsed = parse(urlText),
              parsed.username != nil || parsed.password != nil
        else { return }
        if let user = parsed.username { username = user }
        if let pass = parsed.password { password = pass }
        // Rewrite the field without the credentials (this re-enters didSet, which is then a no-op).
        urlText = parsed.baseURL.absoluteString
    }

    private func parse(_ text: String) -> ParsedServerURL? {
        ServerURLParser.parse(text, keepPath: !kind.urlIsMonitoringSystem)
    }
}

/// Lets a sheet be presented for an open form.
extension ServerFormModel: Identifiable {}
