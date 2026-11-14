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

    /// Exact duration for tooltips, e.g. "2 days, 3 hours, 12 minutes".
    public static func long(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = interval < 60 ? [.second] : [.day, .hour, .minute]
        return formatter.string(from: max(0, interval)) ?? ""
    }
}
