import PollyKit
import SwiftUI
import UserNotifications

/// Posts a local notification when the problems of a server change. Which changes count is decided by
/// `NotificationPolicy`; this only delivers them.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func install(on monitor: MonitorModel) {
        UNUserNotificationCenter.current().delegate = self
        monitor.onProblemChanges = { [weak self] server, changes in
            self?.post(server: server, changes: changes)
        }
    }

    /// Asks for permission the first time; afterwards returns the user's earlier answer.
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private func post(server: NagiosServer, changes: ProblemChanges) {
        var lines = changes.raised.map { "\($0.severity.label): \($0.host) / \($0.title)" }
            + changes.recovered.map { "Recovered: \($0.host) / \($0.title)" }
        if lines.count > 5 {
            lines = lines.prefix(4) + ["and \(lines.count - 4) more"]
        }
        let content = UNMutableNotificationContent()
        content.title = server.name
        content.body = lines.joined(separator: "\n")
        content.sound = .default
        // One notification per server: a newer one replaces the previous instead of stacking up.
        let request = UNNotificationRequest(identifier: server.id.uuidString, content: content, trigger: nil)
        // The bell asks for permission, but `notifications: true` can also come from a hand-edited settings
        // file. Without permission the system drops the notification silently, so ask here as well.
        Task {
            guard await requestAuthorization() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Without this a notification is dropped while the app is frontmost, which on iOS is the only time it polls.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
