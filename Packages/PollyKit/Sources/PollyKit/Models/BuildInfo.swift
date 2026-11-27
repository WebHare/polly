import Foundation

/// Where a build of the app is for, as the `POLLY_BUILD_CHANNEL` build setting records it in the Info.plist.
public enum BuildChannel: String, Sendable {
    /// Built on a developer's machine.
    case local
    /// Built by the TestFlight/App Store lane.
    case appStore = "appstore"
}

/// The channel, version, build number and build date of the running app, so a developer can tell whether they
/// are running an up-to-date local build or the App Store version.
public struct BuildInfo: Equatable, Sendable {
    public static let channelKey = "PollyBuildChannel"

    public var channel: BuildChannel
    public var version: String?
    public var buildNumber: String?
    public var buildDate: Date?

    /// - Parameter executableDate: when the executable was built (its modification date).
    public init(info: [String: Any], executableDate: Date? = nil) {
        channel = (info[Self.channelKey] as? String).flatMap(BuildChannel.init(rawValue:)) ?? .local
        version = info["CFBundleShortVersionString"] as? String
        buildNumber = info["CFBundleVersion"] as? String
        buildDate = executableDate
    }

    public static var current: BuildInfo {
        let modified = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]) }?.contentModificationDate
        return BuildInfo(info: Bundle.main.infoDictionary ?? [:], executableDate: modified)
    }

    /// "Local build 7 · 27 Nov 2026 at 14:05 · 0.2.0" for local builds; nil for App Store builds, which keep the
    /// screen clean.
    public func localBuildLine(timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard channel == .local else { return nil }
        var parts = [["Local build", buildNumber].compactMap { $0 }.joined(separator: " ")]
        if let buildDate {
            var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
            style.timeZone = timeZone
            parts.append(buildDate.formatted(style))
        }
        if let version { parts.append(version) }
        return parts.joined(separator: " · ")
    }
}
