import Foundation

public enum AppRelease {
    public static func versionLabel(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    public static func releases(bundle: Bundle = .main) -> [Changelog.Release] {
        let markdown = bundle.url(forResource: "CHANGELOG", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        #if DEBUG
        return Changelog.shown(Changelog.parse(markdown), includeUnreleased: true)
        #else
        return Changelog.shown(Changelog.parse(markdown), includeUnreleased: false)
        #endif
    }
}
