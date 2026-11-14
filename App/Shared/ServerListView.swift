import PollyKit
import SwiftUI

/// Lists the configured servers with their status; add and delete servers.
/// On macOS this is the "Polly Servers" window, on iOS/iPadOS the main screen.
struct ServerListView: View {
    @Environment(MonitorModel.self) private var monitor
    @State private var showingAdd = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if monitor.servers.isEmpty {
                ContentUnavailableView("No servers", systemImage: "server.rack",
                                       description: Text("Add a Nagios server to start monitoring."))
            }
            ForEach(monitor.servers) { server in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ServerStatusRow(server: server, state: monitor.states[server.id])
                        Spacer()
                        Button(server.notifications ? "Turn off notifications" : "Turn on notifications",
                               systemImage: server.notifications ? "bell.fill" : "bell.slash") {
                            setNotifications(!server.notifications, for: server)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(server.notifications ? "Notifications are on for this server" : "Notifications are off for this server")
                        Toggle("Monitor \(server.name)", isOn: enabledBinding(for: server))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .help(server.enabled ? "Pause monitoring this server" : "Resume monitoring this server")
                    }
                    if case .ok(let status)? = monitor.states[server.id], !status.problems.isEmpty {
                        ProblemList(server: server, problems: status.problems)
                    }
                }
                .contextMenu {
                    Button("Refresh") { Task { await monitor.refresh(server) } }
                    Button("Delete", role: .destructive) { delete(server) }
                }
            }
            .onDelete { offsets in
                offsets.map { monitor.servers[$0] }.forEach(delete)
            }

            Section {
                Toggle("Store passwords in Keychain", isOn: keychainBinding)
                #if os(macOS)
                Toggle("Show Dock icon", isOn: dockIconBinding)
                #endif
            } footer: {
                Text(monitor.passwordStorage == .keychain
                     ? "Passwords are stored in the system keychain."
                     : "Passwords are stored unencrypted in polly.yaml; the keychain is not used.")
            }

            Section {
                Toggle("Log server traffic", isOn: debugLogBinding)
                #if os(macOS)
                if let wireLog = monitor.wireLog, monitor.debugLog {
                    Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([wireLog.fileURL]) }
                }
                #endif
            } footer: {
                Text("For debugging: writes every request and response, without credentials, to polly-debug.log next to polly.yaml.")
            }
        }
        .navigationTitle("Polly")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Server", systemImage: "plus") { showingAdd = true }
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await monitor.refreshAll() } }
            }
        }
        .refreshable { await monitor.refreshAll() }
        .sheet(isPresented: $showingAdd) {
            AddServerView()
        }
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

    #if os(macOS)
    private var dockIconBinding: Binding<Bool> {
        Binding {
            monitor.showDockIcon
        } set: { show in
            do {
                try monitor.setShowDockIcon(show)
                DockIcon.apply(show)
            } catch {
                errorMessage = "Could not save setting: \(error.localizedDescription)"
            }
        }
    }
    #endif

    private var debugLogBinding: Binding<Bool> {
        Binding {
            monitor.debugLog
        } set: { enabled in
            do { try monitor.setDebugLog(enabled) } catch { errorMessage = "Could not save setting: \(error.localizedDescription)" }
        }
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
