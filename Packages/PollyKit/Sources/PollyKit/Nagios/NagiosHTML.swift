import Foundation

/// Minimal readers for the HTML that Nagios' CGIs produce. Nagios has no JSON for these pages, and its
/// markup is regular enough (and sometimes broken enough) that a few regular expressions beat a parser.
enum NagiosHTML {
    /// The action URL of a service or host, or else its notes URL, from its `extinfo.cgi` page.
    static func relatedURL(html: String, pageURL: URL) throws -> URL {
        // extinfo expands custom Nagios macros; objectjson returns their unresolved templates.
        let anchors = matches(#"<a\b([^>]*)>(.*?)</a\s*>"#, in: html)
        for label in ["Perform Additional Actions On This Service", "Perform Additional Actions On This Host",
                      "View Additional Notes For This Service", "View Additional Notes For This Host"] {
            for anchor in anchors where anchor[2].localizedCaseInsensitiveContains(label) {
                guard let href = attributes(anchor[1])["href"], !href.contains("$"),
                      let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                      ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                      url.host != nil, url.user == nil, url.password == nil else {
                    throw BackendError("Nagios supplied an unsupported or unresolved URL. Open the check in your browser instead.")
                }
                return url
            }
        }
        throw BackendError("This check has no Action URL or Notes URL in Nagios.")
    }

    // MARK: - Helpers

    /// All matches of `pattern` (case-insensitive, `.` matches newlines), each as its capture groups.
    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
        }
    }

    /// Attributes of a tag, names lowercased, values entity-decoded. Accepts double, single and no quotes.
    static func attributes(_ text: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for match in matches(#"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, in: text) {
            attributes[match[1].lowercased()] = decode(match[2...4].first { !$0.isEmpty } ?? "")
        }
        return attributes
    }

    static func decode(_ text: String) -> String {
        var result = text
        for match in matches(#"&#(x[0-9a-f]+|[0-9]+);"#, in: text) {
            let hex = match[1].lowercased().hasPrefix("x")
            if let value = UInt32(hex ? String(match[1].dropFirst()) : match[1], radix: hex ? 16 : 10), let scalar = UnicodeScalar(value) {
                result = result.replacingOccurrences(of: match[0], with: String(scalar))
            }
        }
        // `&amp;` last, so "&amp;lt;" becomes "&lt;" and not "<".
        for (entity, value) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }
}
