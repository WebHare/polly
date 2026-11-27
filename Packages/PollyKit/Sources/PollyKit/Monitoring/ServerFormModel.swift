import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

    /// How the source authenticates.
    public enum Authentication: String, CaseIterable, Identifiable, Sendable {
        /// HTTP Basic with the username and password (or none when both are empty).
        case basic
        /// The password is sent as the value of the header named `headerName`.
        case header

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .basic: "Username & password"
            case .header: "Custom header"
            }
        }
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
    /// The password, or the header value with `.header` authentication.
    public var password = ""
    public var authentication: Authentication = .basic {
        didSet { if authentication != oldValue { checkState = .idle } }
    }
    /// The header to send the password in, with `.header` authentication.
    public var headerName = "" {
        didSet { if headerName != oldValue { checkState = .idle } }
    }
    public private(set) var checkState: CheckState = .idle

    /// The URL field. Setting a URL containing `user:pass@` moves those into the
    /// username/password fields and strips them from the URL.
    public var urlText = "" {
        didSet {
            guard urlText != oldValue else { return }
            checkState = .idle
            if !deferringExtraction { extractCredentials() }
        }
    }

    /// `urlText` for the URL text field to bind to. A text field ignores a value that is rewritten while it
    /// sets it, which left pasted credentials visible in the field. So this keeps the text as entered for
    /// now and moves the credentials out on the next turn of the main actor, when the field does update.
    public var urlFieldText: String {
        get { urlText }
        set {
            deferringExtraction = true
            urlText = newValue
            deferringExtraction = false
            guard newValue.contains("@") else { return }
            Task { @MainActor [weak self] in
                guard let self, self.urlText == newValue else { return }
                self.extractCredentials()
            }
        }
    }

    /// Receives the connection test's traffic when set.
    @ObservationIgnored public var wireLog: WireLog?
    @ObservationIgnored private let session: URLSession
    /// The password the edited server had, to tell whether the connection changed.
    @ObservationIgnored private let originalPassword: String
    @ObservationIgnored private var deferringExtraction = false

    public init(kind: BackendKind = .nagios, session: URLSession = .shared) {
        purpose = .add
        self.kind = kind
        self.session = session
        originalPassword = ""
    }

    /// The add form filled in from an "Add to Polly" link. The password or header value is left to the user.
    public convenience init(link: AddSourceLink, session: URLSession = .shared) {
        self.init(kind: link.kind, session: session)
        urlText = link.url
        name = link.name ?? ""
        if let header = link.headerName {
            authentication = .header
            headerName = header
        } else {
            username = link.username ?? ""
        }
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
        if let header = server.authHeader {
            authentication = .header
            headerName = header
        }
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
    public var canSubmit: Bool { parsedURL != nil && headerNameProblem == nil && checkState != .checking }

    private var trimmedHeaderName: String { headerName.trimmingCharacters(in: .whitespaces) }

    /// Why the header name can't be used; nil when it can or isn't used.
    public var headerNameProblem: String? {
        authentication == .header ? SourceCredentials.problem(withHeaderName: trimmedHeaderName) : nil
    }

    /// False when an edit only changed the name, so saving doesn't wait for (or fail on) the server.
    public var needsConnectionTest: Bool {
        guard case .edit(let original) = purpose else { return true }
        guard let server = makeServer() else { return true }
        return server.baseURL != original.baseURL || kind != original.kind || server.username != original.username
            || server.authHeader != original.authHeader || password != originalPassword
    }

    public func makeServer() -> NagiosServer? {
        guard let url = parsedURL, headerNameProblem == nil else { return nil }
        let header = authentication == .header ? trimmedHeaderName : nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var server = NagiosServer(name: trimmedName.isEmpty ? (url.host() ?? url.absoluteString) : trimmedName,
                                  baseURL: url,
                                  username: header == nil ? username : "",
                                  kind: kind,
                                  authHeader: header)
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
            checkState = .failed(headerNameProblem ?? "Please enter a valid http(s) URL.")
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
        authentication = .basic
        // Rewrite the field without the credentials (this re-enters didSet, which is then a no-op).
        urlText = parsed.baseURL.absoluteString
    }

    private func parse(_ text: String) -> ParsedServerURL? {
        ServerURLParser.parse(text, keepPath: !kind.urlIsMonitoringSystem)
    }
}

/// Lets a sheet be presented for an open form.
extension ServerFormModel: Identifiable {}
