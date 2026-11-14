import AppKit
import NaggieKit
import SwiftUI

/// Icon shown in the macOS menu bar. Menu bar icons are rendered as templates (monochrome),
/// so severity is conveyed by the symbol shape plus a problem count.
struct MenuBarLabel: View {
    let monitor: MonitorModel
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            let severity = monitor.overallSeverity
            if monitor.problemCount > 0 {
                Label("\(monitor.problemCount)", systemImage: severity.symbolName)
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: monitor.servers.isEmpty ? "binoculars" : "checkmark.circle")
            }
        }
        .onAppear {
            // Apply the saved Dock icon setting at launch (the label appears once, when the app starts).
            DockIcon.apply(monitor.showDockIcon, activate: false)
            // The label lives as long as the app, so it's a convenient place to hand `openWindow` to the delegate.
            appDelegate.openServersWindow = { [openWindow] in
                openWindow(id: WindowID.servers)
                NSApplication.shared.activate()
            }
        }
    }
}

/// The popover that opens from the menu bar icon.
struct MenuBarContentView: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    /// Panel size chosen by the user by dragging the panel edges. A height of 0 means "fit the content".
    @AppStorage("menuPanelWidth") private var panelWidth: Double = 360
    @AppStorage("menuPanelHeight") private var panelHeight: Double = 0
    @State private var listContentHeight: CGFloat = 0

    private var userSized: Bool { panelHeight > 0 }

    /// Auto-sized list grows with its content up to about a quarter of the screen.
    private var autoListHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return min(listContentHeight, max(200, screenHeight / 4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if monitor.servers.isEmpty {
                Text("No servers configured.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxHeight: userSized ? .infinity : nil, alignment: .top)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(monitor.servers) { server in
                            ServerStatusRow(server: server, state: monitor.states[server.id])
                            if case .ok(let status)? = monitor.states[server.id] {
                                ProblemList(problems: status.problems)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listContentHeight = $0 }
                }
                .frame(height: userSized ? nil : autoListHeight)
                .frame(maxHeight: userSized ? .infinity : nil)
            }

            Divider()

            HStack {
                Button("Servers…") { showServersWindow() }
                Button("Refresh") { Task { await monitor.refreshAll() } }
                if userSized {
                    Button("Fit", systemImage: "arrow.up.and.down.text.horizontal") { panelHeight = 0 }
                        .labelStyle(.iconOnly)
                        .help("Size the panel to fit its content again")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(10)
        }
        .frame(width: panelWidth, height: userSized ? panelHeight : nil)
        .background(PanelResizeSupport { size in
            panelWidth = size.width
            panelHeight = size.height
        })
    }

    private func showServersWindow() {
        openWindow(id: WindowID.servers)
        // We're an LSUIElement (agent) app, so explicitly bring the window to the front.
        NSApplication.shared.activate()
    }
}

private struct ProblemList: View {
    let problems: [ServiceProblem]

    var body: some View {
        ForEach(problems) { problem in
            HStack(spacing: 6) {
                Image(systemName: problem.severity.symbolName).foregroundStyle(problem.severity.color)
                Text(problem.host).bold()
                Text(problem.service)
                Spacer(minLength: 4)
                if let since = problem.since {
                    ProblemAge(since: since)
                }
            }
            .font(.caption)
            .padding(.leading, 24)
        }
    }
}

/// "3m" / "2h" / "3d" since the issue started; hover for the exact duration and local start time.
private struct ProblemAge: View {
    let since: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            let age = context.date.timeIntervalSince(since)
            Text(DurationFormatting.short(age))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("\(DurationFormatting.long(age))\nSince \(since.formatted(date: .abbreviated, time: .standard))")
        }
    }
}

/// Makes the MenuBarExtra panel user-resizable and reports sizes chosen by dragging its edges.
private struct PanelResizeSupport: NSViewRepresentable {
    var onUserResize: (CGSize) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onUserResize = onUserResize
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onUserResize = onUserResize
    }

    final class TrackingView: NSView {
        var onUserResize: ((CGSize) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            window.styleMask.insert(.resizable)
            window.contentMinSize = NSSize(width: 280, height: 120)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Only react to the user dragging, not to SwiftUI resizing the panel to fit.
                    guard let self, let window = self.window, window.inLiveResize,
                          let size = window.contentView?.frame.size else { return }
                    self.onUserResize?(size)
                }
            }
        }
        // The observer is removed in viewDidMoveToWindow when the view leaves its window.
    }
}
