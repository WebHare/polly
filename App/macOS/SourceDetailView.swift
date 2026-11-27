import PollyKit
import SwiftUI

/// One source in the popover: its state, when Polly last heard from it, the switch that pauses it in Polly and the
/// monitoring system's own notification switch.
struct SourceDetailView: View {
    let server: NagiosServer
    let back: () -> Void
    /// Known before the view appears, so the switch slides in with the rest of the detail.
    private let capabilities: BackendCapabilities

    @Environment(MonitorModel.self) private var monitor
    @Environment(\.pollyTheme) private var theme
    @State private var confirmingOff = false
    @State private var working = false
    @State private var message: String?

    init(server: NagiosServer, capabilities: Result<BackendCapabilities, any Error>, back: @escaping () -> Void) {
        self.server = server
        self.back = back
        switch capabilities {
        case .success(let capabilities):
            self.capabilities = capabilities
        case .failure(let error):
            // Without this a password that can't be read looks like a source without a switch.
            self.capabilities = []
            _message = State(initialValue: error.localizedDescription)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                Button("‹ Back", action: back)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(PollyLinkStyle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                theme.divider.frame(height: 1)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let detail = monitor.sourceDetail(for: server, now: context.date)
                VStack(alignment: .leading, spacing: 12) {
                    summary(detail, now: context.date)
                    theme.divider.frame(height: 1)
                    pauseSwitch
                    if let notifications = detail.notifications {
                        theme.divider.frame(height: 1)
                        notificationSwitch(notifications)
                    } else if detail.paused, capabilities.contains(.monitorNotifications) {
                        theme.divider.frame(height: 1)
                        pausedNotificationSwitch
                    }
                    if let message {
                        Text(message).foregroundStyle(theme.severityText(.critical)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func summary(_ detail: SourceDetail, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ServerStateIcon(server: server, state: monitor.states[server.id], size: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    (Text(server.name).font(.system(size: 17, weight: .bold))
                        + Text("  \(server.kind.displayName)").font(.system(size: 12)).foregroundStyle(theme.faint))
                    Text(server.baseURL.absoluteString)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.muted)
                        .textSelection(.enabled)
                }
            }
            ServerLineText(server: server, state: monitor.states[server.id])
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    fact("Last refresh", detail.lastRefresh)
                    if server.isActive {
                        // The next poll is only planned once the running one has finished.
                        fact("Next refresh", monitor.nextPollAt.map { DurationFormatting.until($0.timeIntervalSince(now)) }
                            ?? "Checking now")
                    }
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(theme.faint)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Pausing only affects Polly on this device, unlike the monitoring system's notifications below it.
    private var pauseSwitch: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Check in Polly").fontWeight(.semibold)
                Group {
                    if server.isPaused {
                        Text("Paused: Polly doesn't check \(server.name), its problems aren't counted and you get no "
                             + "notifications for it. Only Polly on this Mac is affected.")
                    } else {
                        Text("Polly checks \(server.name) every \(Int(monitor.pollInterval.components.seconds)) s. Pause it "
                             + "to stop checking without changing anything in \(server.kind.displayName).")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(server.isPaused ? theme.severityText(.warning) : theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Check \(server.name) in Polly", isOn: Binding(
                get: { !server.isPaused },
                set: { checking in
                    message = nil
                    do { try monitor.setPaused(!checking, for: server) } catch { message = error.localizedDescription }
                }))
                .toggleStyle(PollyToggleStyle())
                .labelsHidden()
                .help(server.isPaused ? "Resume checking \(server.name)" : "Pause checking \(server.name)")
        }
    }

    /// While paused Polly doesn't read the monitoring system's status, so the switch's position is unknown.
    private var pausedNotificationSwitch: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(server.kind.displayName) notifications for everyone").fontWeight(.semibold)
                Text("Unknown while paused.").font(.system(size: 12)).foregroundStyle(theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("\(server.kind.displayName) notifications for everyone", isOn: .constant(false))
                .toggleStyle(PollyToggleStyle())
                .labelsHidden()
                .disabled(true)
        }
        .opacity(0.55)
    }

    private func notificationSwitch(_ notifications: SourceDetail.Notifications) -> some View {
        let kind = server.kind.displayName
        let switching = if case .switching = notifications { true } else { false }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(kind) notifications for everyone").fontWeight(.semibold)
                    Group {
                        switch notifications {
                        case .on: Text("\(kind) notifies all its contacts about problems. Switching this off silences "
                                       + "\(kind) for every user, not just you.")
                        case .off: Text("Off for everyone: \(kind) notifies no one about any problem.")
                        case .switching(let enabled):
                            Text("Turning \(enabled ? "on" : "off")… waiting for \(kind) to report the change.")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(notifications == .off ? theme.severityText(.warning) : theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if working || switching { ProgressView().controlSize(.small) }
                Toggle("\(kind) notifications for everyone", isOn: Binding(
                    get: { confirmingOff ? false : notifications.isOn },
                    set: { enabled in
                        message = nil
                        if enabled { confirmingOff = false; send(true) } else { confirmingOff = true }
                    }))
                    .toggleStyle(PollyToggleStyle())
                    .labelsHidden()
                    .disabled(working || switching || !capabilities.contains(.monitorNotifications))
            }
            if confirmingOff {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Turn off notifications on \(server.name)? \(kind) stops notifying all its contacts about every host "
                         + "and service, not just you, until they are turned on again.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Turn Off") { confirmingOff = false; send(false) }
                            .buttonStyle(PollyButtonStyle(kind: .primary, radius: 6))
                        Button("Cancel") { confirmingOff = false }
                            .buttonStyle(PollyButtonStyle(radius: 6))
                    }
                }
                .padding(10)
                .background(theme.selection, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// Sent once; a failure is shown, never retried.
    private func send(_ enabled: Bool) {
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                try await monitor.setMonitorNotifications(enabled, for: server)
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
