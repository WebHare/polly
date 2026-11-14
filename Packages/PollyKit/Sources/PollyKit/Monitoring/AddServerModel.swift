import Foundation
import Observation

/// Backs the "Add server" form: parses pasted URLs and runs the connectivity check.
@MainActor
@Observable
public final class AddServerModel {
    public enum CheckState: Equatable {
        case idle
        case checking
        case succeeded
        case failed(String)
    }

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

    public init(kind: BackendKind = .nagios, session: URLSession = .shared) {
        self.kind = kind
        self.session = session
    }

    public var parsedURL: URL? { parse(urlText)?.baseURL }
    public var canSubmit: Bool { parsedURL != nil && checkState != .checking }

    public func makeServer() -> NagiosServer? {
        guard let url = parsedURL else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        return NagiosServer(name: trimmedName.isEmpty ? (url.host() ?? url.absoluteString) : trimmedName,
                            baseURL: url,
                            username: username,
                            kind: kind)
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
