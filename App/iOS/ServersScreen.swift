import PollyKit
import SwiftUI

/// The configured servers with their state: add, pause, delete, and turn notifications on or off.
struct ServersScreen: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.pollyTheme) private var theme
    /// What the add form is open for; nil while it is closed.
    @State private var adding: BackendKind?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if monitor.servers.isEmpty {
                VStack(spacing: 10) {
                    PollyMascot(mood: .ok, size: 96)
                    Text("Polly has nothing to watch yet").font(.system(size: 17, weight: .bold)).padding(.top, 6)
                    Text("Add a Nagios server or a URL and Polly starts polling right away.")
                        .font(.system(size: 14)).foregroundStyle(theme.muted)
                    Menu("Add server…") {
                        Button("Nagios Server…", systemImage: "server.rack") { adding = .nagios }
                        Button("URL…", systemImage: "globe") { adding = .url }
                    }
                    .menuStyle(.button)
                    .font(.system(size: 14, weight: .semibold))
                    .buttonStyle(PollyButtonStyle(kind: .primary, horizontal: 16, vertical: 9, radius: 10))
                    .padding(.top, 6)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(monitor.servers) { server in
                    row(server)
                        .listRowBackground(theme.surface)
                        .listRowSeparatorTint(theme.surfaceDivider)
                        .contextMenu {
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await monitor.refresh(server) } }
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(server) }
                        }
                }
                .onDelete { offsets in
                    offsets.map { monitor.servers[$0] }.forEach(delete)
                }
            }
        }
        .listStyle(.insetGrouped)
        .phoneListBackground(theme)
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Button("Nagios Server…", systemImage: "server.rack") { adding = .nagios }
                    Button("URL…", systemImage: "globe") { adding = .url }
                }
                .help("Add a Nagios server or a URL to check")
            }
        }
        .refreshable { await monitor.refreshAll() }
        .sheet(item: $adding) { kind in AddServerView(kind: kind) }
        .alert("Error", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { Text($0) }
    }

    private func row(_ server: NagiosServer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ServerStateIcon(server: server, state: monitor.states[server.id], size: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                (Text(server.name).font(.system(size: 16, weight: .semibold))
                    + Text("  \(server.kind.displayName)").font(.system(size: 14)).foregroundStyle(theme.faint))
                    .lineLimit(1)
                Text(ServerStateIcon.line(for: server, state: monitor.states[server.id]))
                    .font(.system(size: 14))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(server.notifications ? "Turn off notifications" : "Turn on notifications",
                   systemImage: server.notifications ? "bell.fill" : "bell.slash") {
                setNotifications(!server.notifications, for: server)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .tint(server.notifications ? theme.tileGlyph : theme.faint)
            .padding(.top, 4)
            Toggle("Monitor \(server.name)", isOn: enabledBinding(for: server))
                .labelsHidden()
                .tint(.pollyAccent)
        }
        .padding(.vertical, 3)
    }

    private func setNotifications(_ enabled: Bool, for server: NagiosServer) {
        Task {
            if enabled, await !Notifier.shared.requestAuthorization() {
                errorMessage = "Notifications are not allowed for Polly. Allow them in the system settings first."
                return
            }
            do { try monitor.setNotifications(enabled, for: server) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func enabledBinding(for server: NagiosServer) -> Binding<Bool> {
        Binding {
            server.enabled
        } set: { enabled in
            do { try monitor.setEnabled(enabled, for: server) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func delete(_ server: NagiosServer) {
        do { try monitor.delete(server) } catch { errorMessage = error.localizedDescription }
    }
}

/// Where passwords are kept and the debug log.
struct PhoneSettingsScreen: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.pollyTheme) private var theme
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Toggle("Store passwords in Keychain", isOn: keychainBinding)
                    .listRowBackground(theme.surface)
            } footer: {
                Text(monitor.passwordStorage == .keychain
                     ? "Passwords are stored in the system keychain."
                     : "Passwords are stored unencrypted in polly.yaml; the keychain is not used.")
                    .foregroundStyle(theme.muted)
            }
            Section {
                Toggle("Log server traffic", isOn: debugLogBinding)
                    .listRowBackground(theme.surface)
            } footer: {
                Text("For debugging: writes every request and response, without credentials, to polly-debug.log next to polly.yaml.")
                    .foregroundStyle(theme.muted)
            }
            Section("About Polly") {
                Text(AppRelease.versionLabel(info: Bundle.main.infoDictionary ?? [:]))
                    .listRowBackground(theme.surface)
                NavigationLink("What's New") { WhatsNewView() }
                    .listRowBackground(theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .tint(.pollyAccent)
        .phoneListBackground(theme)
        .navigationTitle("Settings")
        .alert("Error", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { Text($0) }
    }

    private var keychainBinding: Binding<Bool> {
        Binding {
            monitor.passwordStorage == .keychain
        } set: { useKeychain in
            do {
                try monitor.setPasswordStorage(useKeychain ? .keychain : .file)
            } catch {
                errorMessage = "Could not move passwords: \(error.localizedDescription)"
            }
        }
    }

    private var debugLogBinding: Binding<Bool> {
        Binding {
            monitor.debugLog
        } set: { enabled in
            do { try monitor.setDebugLog(enabled) } catch { errorMessage = "Could not save setting: \(error.localizedDescription)" }
        }
    }
}
