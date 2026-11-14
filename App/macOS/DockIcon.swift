import AppKit
import SwiftUI

/// Optional Dock icon. The app is an LSUIElement (menu bar only) by default; when enabled we switch the
/// activation policy to `.regular` so it gets a Dock icon (and app menu) as well.
enum DockIcon {
    @MainActor
    static func apply(_ show: Bool, activate: Bool = true) {
        NSApplication.shared.setActivationPolicy(show ? .regular : .accessory)
        // Changing the policy can push our windows behind other apps; bring them back.
        if activate { NSApplication.shared.activate() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opens the Servers window; installed by a SwiftUI view that has access to `openWindow`.
    var openServersWindow: (() -> Void)?

    /// Clicking the Dock icon with no windows open shows the Servers window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openServersWindow?() }
        return true
    }
}
