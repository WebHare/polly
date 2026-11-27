import Foundation

/// Parses what the user typed or pasted into the "URL" field of the add-server form.
///
/// `https://alice:s3cret@monitor.example.com/nagios/` becomes
/// base URL `https://monitor.example.com`, username `alice`, password `s3cret`.
public struct ParsedServerURL: Equatable, Sendable {
    /// URL with credentials and fragment removed. For a monitoring system also its query and any
    /// `/nagios...` suffix.
    public var baseURL: URL
    public var username: String?
    public var password: String?
}

public enum ServerURLParser {
    /// `keepPath` keeps the path and query, for a URL that is itself the thing to check. `allowFile` also takes a
    /// `file://` URL, for a feed file.
    public static func parse(_ input: String, keepPath: Bool = false, allowFile: Bool = false) -> ParsedServerURL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if allowFile, text.lowercased().hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL, !url.path(percentEncoded: false).isEmpty,
                  url.path(percentEncoded: false) != "/" else { return nil }
            return ParsedServerURL(baseURL: url, username: nil, password: nil)
        }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty
        else { return nil }

        // `user` / `password` return percent-decoded values.
        let username = components.user.flatMap { $0.isEmpty ? nil : $0 }
        let password = components.password.flatMap { $0.isEmpty ? nil : $0 }

        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.fragment = nil
        if !keepPath {
            components.query = nil
            components.path = stripNagiosSuffix(components.path)
        }

        guard let baseURL = components.url else { return nil }
        return ParsedServerURL(baseURL: baseURL, username: username, password: password)
    }

    /// Users will often paste a link to the Nagios UI itself (`/nagios/`, `/nagios/cgi-bin/status.cgi`, ...).
    /// We append `/nagios/cgi-bin/statusjson.cgi` ourselves, so cut the path at `/nagios`.
    static func stripNagiosSuffix(_ path: String) -> String {
        var segments = path.split(separator: "/", omittingEmptySubsequences: true)
        if let idx = segments.firstIndex(of: "nagios") {
            segments = Array(segments[..<idx])
        }
        return segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
    }
}
