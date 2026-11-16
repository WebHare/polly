import PollyKit
import SwiftUI

@main
struct PollyApp: App {
    @State private var monitor: MonitorModel
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @Environment(\.scenePhase) private var scenePhase
    #endif

    init() {
        let store: ServerStore
        do {
            store = try ServerStore.makeDefault()
        } catch {
            // Keep the app usable (but non-persistent) if polly.yaml can't be read, and don't overwrite it.
            print("Polly: failed to load settings, falling back to an in-memory store: \(error)")
            store = try! ServerStore(fileURL: nil, credentials: KeychainCredentialStore())
        }
        let monitor = MonitorModel(store: store)
        Notifier.shared.install(on: monitor)
        #if os(macOS)
        monitor.startPolling()
        #endif
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

        Window("Polly Settings", id: WindowID.servers) {
            SettingsView()
                .environment(monitor)
        }
        // The design draws the sidebar up to the top edge, under the window buttons.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        Window("What's New in Polly", id: WindowID.whatsNew) {
            WhatsNewView().pollyThemed()
                .frame(minWidth: 420, minHeight: 320)
        }
        .defaultSize(width: 580, height: 560)
        #else
        WindowGroup {
            PhoneRootView()
                .environment(monitor)
        }
        .onChange(of: scenePhase, initial: true) {
            monitor.setPollingActive(scenePhase == .active)
        }
        #endif
    }
}

enum WindowID {
    static let servers = "servers"
    static let whatsNew = "whats-new"
}
