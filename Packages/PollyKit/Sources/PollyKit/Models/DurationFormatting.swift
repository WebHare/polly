import Foundation

public enum DurationFormatting {
    /// Compact age of an issue: "<1m", "3m", "2h", "3d" (largest whole unit only).
    public static func short(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval) / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// How long ago something happened: "14 s ago", "4 min ago", "2 h ago".
    public static func ago(_ interval: TimeInterval) -> String {
        "\(coarse(interval)) ago"
    }

    /// How long until something happens: "in 46 s"; "due now" once the moment has passed.
    public static func until(_ interval: TimeInterval) -> String {
        interval <= 0 ? "due now" : "in \(coarse(interval))"
    }

    private static func coarse(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h"
    }

    /// Exact duration for tooltips, e.g. "2 days, 3 hours, 12 minutes".
    public static func long(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = interval < 60 ? [.second] : [.day, .hour, .minute]
        return formatter.string(from: max(0, interval)) ?? ""
    }
}
