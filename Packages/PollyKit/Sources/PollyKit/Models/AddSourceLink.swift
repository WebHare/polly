import Foundation

/// An "Add to Polly" link from a web page, such as
/// `polly-monitor://add?type=feed&url=https%3A%2F%2Fsla.example.com%2Fpolly.json&name=SLA&header=X-API-Key`.
///
/// A link only fills in the add form; the user still tests and adds the source. It never carries a password or
/// token, and only points at web addresses.
public struct AddSourceLink: Equatable, Sendable {
    public static let scheme = "polly-monitor"

    public var kind: BackendKind
    /// The URL as the link gives it; the form reads it like a typed or pasted URL.
    public var url: String
    public var name: String?
    public var username: String?
    /// Sign in with this header (`X-API-Key`, `Authorization`); the user enters its value.
    public var headerName: String?

    public init(kind: BackendKind, url: String, name: String?, username: String?, headerName: String?) {
        self.kind = kind
        self.url = url
        self.name = name
        self.username = username
        self.headerName = headerName
    }

    public struct Problem: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Parameters that would carry a secret. Refused rather than ignored, so whoever builds the link notices.
    private static let secretKeys: Set<String> = ["password", "value", "token", "secret", "key", "apikey", "api_key"]
    private static let maxLength = 2048

    public static func parse(_ link: URL) throws -> AddSourceLink {
        guard link.scheme?.lowercased() == scheme, link.host()?.lowercased() == "add" else {
            throw Problem(message: "Polly doesn't know what to do with this link.")
        }
        guard link.absoluteString.count <= maxLength else { throw Problem(message: "The link is too long.") }
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? {
            items.first { $0.name.lowercased() == key }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        }
        let secretMessage = "An \"Add to Polly\" link can't contain a password or token. Enter it in the form instead."
        if items.contains(where: { secretKeys.contains($0.name.lowercased()) }) { throw Problem(message: secretMessage) }

        var kind = BackendKind.nagios
        if let type = value("type") {
            guard let known = BackendKind(rawValue: type.lowercased()) else {
                throw Problem(message: "The link asks for a source of type \"\(type)\", which this version of Polly doesn't know.")
            }
            kind = known
        }
        guard let url = value("url") else { throw Problem(message: "The link has no url.") }
        guard let components = URLComponents(string: url), let urlScheme = components.scheme?.lowercased(),
              ["http", "https"].contains(urlScheme), components.host?.isEmpty == false else {
            throw Problem(message: "The link's url must be an http or https address.")
        }
        if components.password?.isEmpty == false { throw Problem(message: secretMessage) }
        let headerName = value("header")
        if let headerName, let problem = SourceCredentials.problem(withHeaderName: headerName) {
            throw Problem(message: problem)
        }
        return AddSourceLink(kind: kind, url: url, name: value("name"), username: value("username"), headerName: headerName)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
