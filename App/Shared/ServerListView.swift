import NaggieKit
import SwiftUI

/// Lists the configured servers with their status; add and delete servers.
/// On macOS this is the "Naggie Servers" window, on iOS/iPadOS the main screen.
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
                HStack {
                    ServerStatusRow(server: server, state: monitor.states[server.id])
                    Spacer()
                    Toggle("Monitor \(server.name)", isOn: enabledBinding(for: server))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help(server.enabled ? "Pause monitoring this server" : "Resume monitoring this server")
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
                     : "Passwords are stored unencrypted in naggie.yaml; the keychain is not used.")
            }
        }
        .navigationTitle("Naggie")
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
