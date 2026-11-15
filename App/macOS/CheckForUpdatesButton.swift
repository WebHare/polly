import Sparkle
import SwiftUI

struct CheckForUpdatesButton: View {
    // A single controller owns both scheduled checks and user-initiated checks.
    static let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    @State private var canCheck = false

    var body: some View {
        Button("Check for Updates…") { Self.controller.checkForUpdates(nil) }
            .disabled(!canCheck)
            .onReceive(Self.controller.updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}
