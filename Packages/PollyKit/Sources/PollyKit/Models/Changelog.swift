import Foundation

/// CHANGELOG.md in the repo root, in the Keep a Changelog shape Application_42 uses: "## [Unreleased]" on top,
/// then "## [x.y.z] - YYYY-MM-DD" newest first, each with "### Title" sections of "- item" bullets.
/// The app bundles it for offline release notes.
public enum Changelog {
    public struct Section: Hashable, Sendable {
        public var title: String
        public var items: [String]
    }

    public struct Release: Hashable, Sendable {
        /// nil for [Unreleased].
        public var version: String?
        public var date: String?
        public var sections: [Section]
    }

    public static func parse(_ markdown: String) -> [Release] {
        var releases: [Release] = []
        var sections: [Section] = []
        func closeRelease() { if !releases.isEmpty { releases[releases.count - 1].sections = sections } }
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let heading = rawLine.wholeMatch(of: /## \[([^\]]+)\](?: - (\d{4}-\d{2}-\d{2}))?\s*/) {
                closeRelease()
                sections = []
                releases.append(Release(version: heading.1 == "Unreleased" ? nil : String(heading.1),
                                        date: heading.2.map(String.init), sections: []))
            } else if releases.isEmpty || line.isEmpty {
                continue
            } else if rawLine.hasPrefix("### ") {
                sections.append(Section(title: String(line.dropFirst(4)), items: []))
            } else if rawLine.hasPrefix("- "), !sections.isEmpty {
                sections[sections.count - 1].items.append(String(line.dropFirst(2)))
            } else if rawLine.first?.isWhitespace == true, !(sections.last?.items.isEmpty ?? true) {
                // An indented line continues the previous bullet.
                let last = sections.count - 1
                sections[last].items[sections[last].items.count - 1] += " " + line
            }
        }
        closeRelease()
        return releases
    }

    /// Releases with at least one item; the unreleased entries only in a Debug build.
    public static func shown(_ releases: [Release], includeUnreleased: Bool) -> [Release] {
        releases.filter { ($0.version != nil || includeUnreleased) && $0.sections.contains { !$0.items.isEmpty } }
    }
}
