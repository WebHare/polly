import PollyKit
import SwiftUI

/// Status remains reachable from Sources even when macOS hides the menu bar item.
struct SourceStatusView: View {
    let server: NagiosServer
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.pollyTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var selectedCapabilities: Result<BackendCapabilities, any Error> = .success([])
    @State private var refreshing = false

    var body: some View {
        let summary = monitor.summary(for: server.id)
        let entries = summary.entries
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.name).font(.system(size: 18, weight: .bold))
                    Text(server.kind.displayName).foregroundStyle(theme.muted)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PollyButtonStyle())
            }
            .padding(18)
            theme.divider.frame(height: 1)
            ScrollView {
                if let index = entries.firstIndex(where: { $0.id == selectedID }) {
                    ProblemDetailView(entry: entries[index], position: index + 1, total: entries.count,
                                      capabilities: selectedCapabilities) {
                        select(nil)
                    } step: { offset in
                        select(entries[(index + offset + entries.count) % entries.count])
                    }
                    .id(entries[index].id)
                } else {
                    overview(summary)
                }
            }
            theme.divider.frame(height: 1)
            HStack {
                Button("Refresh") {
                    refreshing = true
                    Task {
                        defer { refreshing = false }
                        await monitor.refresh(server)
                    }
                }
                .buttonStyle(PollyButtonStyle())
                .disabled(!server.enabled || refreshing)
                if refreshing { ProgressView().controlSize(.small) }
                Spacer()
                if let fetched = monitor.lastSuccesses[server.id] {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Last successful check").foregroundStyle(theme.faint)
                        Text(fetched, style: .relative).monospacedDigit()
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(14)
            .background(theme.footer)
        }
        .frame(width: 600, height: 600)
        .background(theme.panel)
        .pollyThemed()
    }

    private func overview(_ summary: MonitorSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                PollyMascot(mood: summary.mood, size: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Text(summary.headline).font(.system(size: 16, weight: .bold))
                    ServerLineText(server: server, state: monitor.states[server.id])
                }
            }
            switch summary.screen {
            case .problems:
                ForEach(summary.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(group.severity.label) · \(group.entries.count)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.severityText(group.severity))
                        ForEach(group.entries) { entry in
                            ProblemRow(entry: entry) { select(entry) }
                        }
                    }
                }
            case .ok:
                Text("No current problems reported by this source.")
                    .foregroundStyle(theme.muted)
            case .unreachable:
                Text("Polly could not read this source. Check its settings or try Refresh.")
                    .foregroundStyle(theme.muted)
            case .waiting:
                Text(summary.isPaused ? "Paused. Switch on Check in Polly in its detail in the menu bar panel to check it again."
                                      : "Waiting for the first answer.")
                    .foregroundStyle(theme.muted)
            case .empty:
                Text(summary.allDisabled ? "This source is disabled. Turn it on in Sources to check it."
                                         : "This source is no longer configured.").foregroundStyle(theme.muted)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func select(_ entry: ProblemEntry?) {
        // Reading credentials is only needed when opening a problem's actions.
        if let entry {
            selectedCapabilities = Result { try monitor.backend(for: entry.server).capabilities }
        }
        selectedID = entry?.id
    }
}
