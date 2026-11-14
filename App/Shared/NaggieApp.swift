import NaggieKit
import SwiftUI

@main
struct NaggieApp: App {
    @State private var monitor: MonitorModel
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        let store: ServerStore
        do {
            store = try ServerStore.makeDefault()
        } catch {
            // Keep the app usable (but non-persistent) if naggie.yaml can't be read, and don't overwrite it.
            print("Naggie: failed to load settings, falling back to an in-memory store: \(error)")
            store = try! ServerStore(fileURL: nil, credentials: KeychainCredentialStore())
        }
        let monitor = MonitorModel(store: store)
        monitor.startPolling()
        _monitor = State(initialValue: monitor)
    }

    var body: some Scene {
        #if os(macOS)
        MenuBarExtra {
            MenuBarContentView()
                .environment(monitor)
        } label: {
            MenuBarLabel(monitor: monitor, appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.window)

        Window("Naggie Servers", id: WindowID.servers) {
            ServerListView()
                .environment(monitor)
                .frame(minWidth: 480, minHeight: 320)
        }
        .windowResizability(.contentMinSize)
        #else
        WindowGroup {
            NavigationStack {
                ServerListView()
            }
            .environment(monitor)
        }
        #endif
    }
}

enum WindowID {
    static let servers = "servers"
}
