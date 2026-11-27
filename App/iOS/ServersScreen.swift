import PollyKit
import SwiftUI

/// The configured servers with their state: add, edit, duplicate, pause, delete, and turn notifications on or off.
struct ServersScreen: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.pollyTheme) private var theme
    /// The open add/edit form; nil while it is closed.
    @State private var form: ServerFormModel?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if monitor.servers.isEmpty {
                VStack(spacing: 10) {
                    PollyMascot(mood: .ok, size: 96)
                    Text("Polly has nothing to watch yet").font(.system(size: 17, weight: .bold)).padding(.top, 6)
                    Text("Add a Nagios server or a URL and Polly starts polling right away.")
                        .font(.system(size: 14)).foregroundStyle(theme.muted)
                    Menu("Add source…") {
                        Button("Nagios Server…", systemImage: "server.rack") { form = ServerFormModel(kind: .nagios) }
                        Button("URL…", systemImage: "globe") { form = ServerFormModel(kind: .url) }
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
                            Button("Edit…", systemImage: "pencil") { edit(server) }
                            Button("Duplicate…", systemImage: "plus.square.on.square") { duplicate(server) }
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await monitor.refresh(server) } }
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(server) }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(server) }
                                .tint(.pollyAccent)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(server) }
                            Button("Edit", systemImage: "pencil") { edit(server) }
                        }
                }
            }
        }
        .listStyle(.insetGrouped)
        .phoneListBackground(theme)
        .navigationTitle("Sources")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Button("Nagios Server…", systemImage: "server.rack") { form = ServerFormModel(kind: .nagios) }
                    Button("URL…", systemImage: "globe") { form = ServerFormModel(kind: .url) }
                }
                .help("Add a Nagios server or a URL to check")
            }
        }
        .refreshable { await monitor.refreshAll() }
        .sheet(item: $form) { ServerFormView(model: $0) }
        .onChange(of: monitor.editRequest, initial: true) { openRequestedEdit() }
        .alert("Error", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { Text($0) }
    }

    private func row(_ server: NagiosServer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Tapping the server (not its bell or switch) opens the edit form.
            HStack(alignment: .top, spacing: 12) {
                ServerStateIcon(server: server, state: monitor.states[server.id], size: 20).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    (Text(server.name).font(.system(size: 16, weight: .semibold))
                        + Text("  \(server.kind.displayName)").font(.system(size: 14)).foregroundStyle(theme.faint))
                        .lineLimit(1)
                    ServerLineText(server: server, state: monitor.states[server.id], fontSize: 14,
                                   plainColor: theme.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { edit(server) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Edit this source")
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

    private func edit(_ server: NagiosServer) {
        do { form = try monitor.editForm(for: server) } catch { errorMessage = error.localizedDescription }
    }

    private func duplicate(_ server: NagiosServer) {
        do { form = try monitor.duplicateForm(for: server) } catch { errorMessage = error.localizedDescription }
    }

    private func openRequestedEdit() {
        guard let id = monitor.editRequest else { return }
        monitor.editRequest = nil
        guard form == nil, let server = monitor.servers.first(where: { $0.id == id }) else { return }
        edit(server)
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
                if let line = BuildInfo.current.localBuildLine() {
                    Text(line)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(theme.muted)
                        .listRowBackground(theme.surface)
                }
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
