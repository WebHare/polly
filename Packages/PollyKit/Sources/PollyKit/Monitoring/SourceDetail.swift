import Foundation

/// A change of the monitoring system's own notifications that Polly sent, and when.
public struct NotificationRequest: Equatable, Sendable {
    public var enabled: Bool
    public var at: Date

    public init(enabled: Bool, at: Date) {
        self.enabled = enabled
        self.at = at
    }
}

/// What the source detail shows about one source, apart from its name and state line.
public struct SourceDetail: Equatable, Sendable {
    /// The monitoring system's own notifications to all its contacts.
    public enum Notifications: Equatable, Sendable {
        case on, off
        /// Sent, but the monitoring system doesn't report the new value yet.
        case switching(to: Bool)

        /// The position of the switch: the requested value while switching.
        public var isOn: Bool {
            switch self {
            case .on: true
            case .off: false
            case .switching(let enabled): enabled
            }
        }
    }

    /// How long a sent change is shown as pending when the monitoring system keeps reporting the old value.
    /// Nagios only rewrites its status file every `status_update_interval` (60 s unless set), and Polly polls
    /// every 60 s, so the new value can take two minutes to arrive.
    public static let switchingTimeout: TimeInterval = 150

    /// When Polly last refreshed the source: "14 s ago", "Failed 1 min ago · last answer 10 min ago", "Not yet"
    /// or "Paused".
    public var lastRefresh: String
    /// nil when the source doesn't report its notification switch, or hasn't answered.
    public var notifications: Notifications?

    public init(server: NagiosServer, state: MonitorModel.ServerState?, lastSuccess: Date?, lastAttempt: Date?,
                notificationRequest: NotificationRequest?, now: Date) {
        func ago(_ date: Date) -> String { DurationFormatting.ago(now.timeIntervalSince(date)) }
        notifications = nil
        guard server.enabled else {
            lastRefresh = "Paused"
            return
        }
        switch state {
        case .ok(let status):
            lastRefresh = ago(lastSuccess ?? status.fetchedAt)
            guard let enabled = status.notificationsEnabled else { return }
            if let request = notificationRequest, request.enabled != enabled,
               now.timeIntervalSince(request.at) < Self.switchingTimeout {
                notifications = .switching(to: request.enabled)
            } else {
                notifications = enabled ? .on : .off
            }
        case .failed:
            lastRefresh = ["Failed \(lastAttempt.map(ago) ?? "")".trimmingCharacters(in: .whitespaces),
                       lastSuccess.map { "last answer \(ago($0))" }].compactMap { $0 }.joined(separator: " · ")
        case .loading, nil:
            lastRefresh = "Not yet"
        }
    }
}
