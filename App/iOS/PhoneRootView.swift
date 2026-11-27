import PollyKit
import SwiftUI

/// The iPhone and iPad app: problems, servers and settings in a tab bar.
struct PhoneRootView: View {
    enum Tab: Hashable { case problems, servers, settings }

    @Environment(MonitorModel.self) private var monitor
    @State private var tab = Tab.problems

    init() {
        // Navigation titles in the ink of the design instead of pure black and white.
        let ink = UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: 0xEEF2FA)) : UIColor(Color.pollyNavy) }
        let appearance = UINavigationBar.appearance()
        appearance.largeTitleTextAttributes = [.foregroundColor: ink]
        appearance.titleTextAttributes = [.foregroundColor: ink]
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { ProblemsScreen { tab = .servers } }
                .tabItem { Label("Problems", systemImage: "triangle.fill") }
                .tag(Tab.problems)
            NavigationStack { ServersScreen() }
                .tabItem { Label("Sources", systemImage: "rectangle.split.1x2.fill") }
                .tag(Tab.servers)
            NavigationStack { PhoneSettingsScreen() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(.pollyBlue)
        .phoneThemed()
        // "Add to Polly" links are shown on the Sources tab.
        .onChange(of: monitor.linkRequest, initial: true) {
            if monitor.linkRequest != nil { tab = .servers }
        }
    }
}
