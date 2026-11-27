import AppKit
import PollyKit
import SwiftUI

/// Icon shown in the macOS menu bar; see `MenuBarIcon` for how each state looks.
struct MenuBarLabel: View {
    let monitor: MonitorModel
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    /// The menu bar's own appearance, which follows the wallpaper rather than the app.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let summary = monitor.summary
        Image(nsImage: MenuBarIcon.image(mood: summary.mood, badge: summary.badge, paused: summary.paused,
                                         darkMenuBar: colorScheme == .dark))
            .accessibilityLabel(summary.paused == 0 ? summary.headline
                                : "\(summary.headline), \(summary.paused) paused")
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

/// The popover that opens from the menu bar icon: the problem overview, sliding to one problem's detail.
struct MenuBarContentView: View {
    /// Panel size chosen by the user by dragging the panel edges. A height of 0 means "fit the content".
    @AppStorage("menuPanelWidth") private var panelWidth: Double = 360
    @AppStorage("menuPanelHeight") private var panelHeight: Double = 0

    var body: some View {
        PopoverContent(userSized: panelHeight > 0) { panelHeight = 0 }
            .frame(width: panelWidth, height: panelHeight > 0 ? panelHeight : nil)
            .pollyThemed()
            .background(PanelResizeSupport { size in
                panelWidth = size.width
                panelHeight = size.height
            })
    }
}

private struct PopoverContent: View {
    let userSized: Bool
    let fit: () -> Void

    @Environment(MonitorModel.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.pollyTheme) private var theme
    @State private var listContentHeight: CGFloat = 0
    @State private var selectedID: String?
    /// What the selected problem's server supports, resolved before the detail appears so its buttons are part
    /// of the slide-in instead of popping in after it.
    @State private var selectedCapabilities: Result<BackendCapabilities, any Error> = .success([])
    @State private var selectedSourceID: UUID?

    /// Auto-sized list grows with its content up to about a quarter of the screen.
    private var autoListHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return min(listContentHeight, max(200, screenHeight / 4))
    }

    var body: some View {
        let summary = monitor.summary
        let entries = summary.entries
        ZStack {
            if let index = entries.firstIndex(where: { $0.id == selectedID }) {
                ProblemDetailView(entry: entries[index], position: index + 1, total: entries.count,
                                  capabilities: selectedCapabilities) {
                    select(nil)
                } step: { offset in
                    select(entries[(index + offset + entries.count) % entries.count])
                }
                // A new identity per problem, so stepping resets the form and the fetched capabilities.
                .id(entries[index].id)
                .transition(.move(edge: .trailing))
            } else if let server = monitor.servers.first(where: { $0.id == selectedSourceID }) {
                SourceDetailView(server: server, capabilities: selectedCapabilities) { selectSource(nil) }
                    .id(server.id)
                    .transition(.move(edge: .trailing))
            } else {
                overview(summary)
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: selectedID == nil && selectedSourceID == nil)
        .background(theme.panel)
        .clipped()
    }

    /// Creating a backend reads the password, so only do that for a problem that is actually opened.
    private func select(_ entry: ProblemEntry?) {
        if let entry {
            selectedCapabilities = Result { try monitor.backend(for: entry.server).capabilities }
        }
        selectedID = entry?.id
    }

    private func selectSource(_ server: NagiosServer?) {
        if let server {
            selectedCapabilities = Result { try monitor.backend(for: server).capabilities }
        }
        selectedSourceID = server?.id
    }

    private func overview(_ summary: MonitorSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if summary.screen == .problems {
                header(summary)
                theme.divider.frame(height: 1)
                ScrollView {
                    problemGroups(summary)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listContentHeight = $0 }
                }
                .frame(height: userSized ? nil : autoListHeight)
                .frame(maxHeight: userSized ? .infinity : nil)
            } else {
                hero(summary)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: userSized ? .infinity : nil, alignment: .top)
            }
            if !monitor.enabledServers.isEmpty {
                theme.divider.frame(height: 1)
                servers
            }
            footer(summary)
        }
    }

    private func header(_ summary: MonitorSummary) -> some View {
        HStack(spacing: 10) {
            PollyMascot(mood: summary.mood, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.headline).font(.system(size: 14, weight: .bold))
                if !summary.countsLine.isEmpty {
                    Text(summary.countsLine).font(.system(size: 12)).foregroundStyle(theme.muted)
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
    }

    private func problemGroups(_ summary: MonitorSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(summary.groups) { group in
                HStack(spacing: 6) {
                    Text(group.severity.label).foregroundStyle(theme.severityText(group.severity))
                    Text("\(group.entries.count)").fontWeight(.semibold).foregroundStyle(theme.faint)
                }
                .font(.system(size: 11, weight: .bold))
                .tracking(0.66)
                .textCase(.uppercase)
                .padding(EdgeInsets(top: 8, leading: 8, bottom: 4, trailing: 8))
                ForEach(group.entries) { entry in
                    ProblemRow(entry: entry) { select(entry) }
                }
            }
        }
        .padding(EdgeInsets(top: 4, leading: 6, bottom: 6, trailing: 6))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hero(_ summary: MonitorSummary) -> some View {
        VStack(spacing: 8) {
            PollyMascot(mood: summary.mood, size: 96)
            Text(summary.headline)
                .font(.system(size: 15, weight: .bold))
                .padding(.top, 6)
            heroDetail(summary)
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            // Nothing to retry while every source is paused; resuming is in each source's detail.
            if summary.screen != .ok && !summary.isPaused {
                HStack(spacing: 8) {
                    if summary.allDisabled {
                        Button("Settings…") { showSettings() }
                            .buttonStyle(PollyButtonStyle(kind: .primary, radius: 6))
                    } else if summary.screen == .empty {
                        Button("Add source…") { showSettings() }
                            .buttonStyle(PollyButtonStyle(kind: .primary, radius: 6))
                    } else {
                        Button("Retry now") { Task { await monitor.refreshAll() } }
                            .buttonStyle(PollyButtonStyle(kind: .primary, radius: 6))
                        Button("Edit source…") {
                            monitor.editRequest = summary.unreachable?.server.id
                            showSettings()
                        }
                            .buttonStyle(PollyButtonStyle(radius: 6))
                    }
                }
                .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.center)
        .padding(EdgeInsets(top: 22, leading: 28, bottom: 18, trailing: 28))
    }

    @ViewBuilder private func heroDetail(_ summary: MonitorSummary) -> some View {
        switch summary.screen {
        case .empty:
            Text(summary.allDisabled ? "Turn a source on in Settings and Polly starts checking it."
                                     : "Add a Nagios server or a URL and Polly starts polling right away.")
        case .unreachable:
            Text("\(summary.unreachable?.message ?? "") Polly keeps trying every \(Int(monitor.pollInterval.components.seconds)) s.")
        case .waiting:
            Text(summary.isPaused ? "Open a source below and switch on Check in Polly to start checking again."
                                  : "Waiting for the first answer.")
        case .ok, .problems:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                // The next poll is only planned once the running one has finished.
                let wait = Int(monitor.nextPollAt?.timeIntervalSince(context.date) ?? 0)
                Text("\(summary.hosts) hosts and \(summary.services) services are fine. "
                     + (wait > 0 ? "Polly checks again in \(wait) seconds." : "Polly is checking now."))
            }
        }
    }

    private var servers: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sources")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.66)
                .textCase(.uppercase)
                .foregroundStyle(theme.faint)
                .padding(EdgeInsets(top: 6, leading: 8, bottom: 4, trailing: 8))
            // Disabled sources are left out; paused ones say so in their line.
            ForEach(monitor.enabledServers) { server in
                SourceRow(server: server, state: monitor.states[server.id]) { selectSource(server) }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(_ summary: MonitorSummary) -> some View {
        VStack(spacing: 0) {
            theme.divider.frame(height: 1)
            HStack(spacing: 6) {
                Group {
                    Button("Refresh") { Task { await monitor.refreshAll() } }
                    Button("Settings…") { showSettings() }
                    if userSized {
                        Button("Fit", systemImage: "arrow.up.and.down.text.horizontal", action: fit)
                            .labelStyle(.iconOnly)
                            .help("Size the panel to fit its content again")
                    }
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
                .buttonStyle(PollyButtonStyle(horizontal: 10, vertical: 3, radius: 6))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(footNote(summary, now: context.date))
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(theme.faint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            if let line = BuildInfo.current.localBuildLine() {
                Text(line)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
        .background(theme.footer)
    }

    private func footNote(_ summary: MonitorSummary, now: Date) -> String {
        switch summary.screen {
        case .empty:
            return summary.allDisabled ? "All sources disabled" : "No sources"
        case .waiting:
            return summary.isPaused ? "Paused" : "Checking…"
        case .unreachable:
            guard let next = monitor.nextPollAt else { return "" }
            return "Retrying \(DurationFormatting.until(next.timeIntervalSince(now)))"
        case .ok, .problems:
            // When each source was last refreshed is in its detail.
            return ""
        }
    }

    private func showSettings() {
        openWindow(id: WindowID.servers)
        // We're an LSUIElement (agent) app, so explicitly bring the window to the front.
        NSApplication.shared.activate()
    }
}

/// A source in the panel's list; clicking it opens its detail.
private struct SourceRow: View {
    let server: NagiosServer
    let state: MonitorModel.ServerState?
    let open: () -> Void
    @Environment(\.pollyTheme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                ServerStateIcon(server: server, state: state, size: 15)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name).fontWeight(.semibold) + Text("  \(server.kind.displayName)").foregroundStyle(theme.faint)
                    ServerLineText(server: server, state: state)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovered ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct ProblemRow: View {
    let entry: ProblemEntry
    let open: () -> Void
    @Environment(\.pollyTheme) private var theme
    @State private var hovered = false

    var body: some View {
        let problem = entry.problem
        Button(action: open) {
            HStack(spacing: 8) {
                StatusIcon(severity: problem.severity, size: 15)
                (Text(problem.host).fontWeight(.semibold) + Text("  \(problem.title)").foregroundStyle(theme.muted))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if problem.acknowledged {
                    tag("ACK")
                }
                if problem.downtimeDepth > 0 {
                    Image(systemName: "moon.zzz").font(.system(size: 11)).foregroundStyle(theme.muted)
                        .help("In scheduled downtime").accessibilityLabel("In scheduled downtime")
                }
                if let since = problem.since {
                    ProblemAge(since: since)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovered ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(problem.acknowledged ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("problem-\(entry.id)")
        .onHover { hovered = $0 }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(theme.muted)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.border, lineWidth: 1))
    }
}

/// "3m" / "2h" / "3d" since the issue started; hover for the exact duration and local start time.
private struct ProblemAge: View {
    let since: Date
    @Environment(\.pollyTheme) private var theme

    var body: some View {
        TimelineView(.everyMinute) { context in
            let age = context.date.timeIntervalSince(since)
            Text(DurationFormatting.short(age))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(theme.muted)
                .frame(minWidth: 26, alignment: .trailing)
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
