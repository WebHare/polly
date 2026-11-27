import PollyKit
import SwiftUI

/// The main iPhone screen: Polly's summary, the problems of all servers grouped by severity, or one of the
/// empty states (no servers, all quiet, server unreachable).
struct ProblemsScreen: View {
    /// Switches to the Sources tab.
    let showServers: () -> Void

    @Environment(MonitorModel.self) private var monitor
    @Environment(\.pollyTheme) private var theme
    /// Only show this severity; nil shows all.
    @State private var filter: Severity?
    /// What the add form is open for; nil while it is closed.
    @State private var adding: BackendKind?

    var body: some View {
        let summary = monitor.summary
        ScrollView {
            if isWaitingForFirstAnswer {
                ProgressView().padding(.top, 160)
            } else {
                switch summary.screen {
                case .problems: problems(summary)
                case .ok, .empty, .unreachable, .waiting: emptyState(summary)
                }
            }
        }
        .background(theme.screen)
        .navigationTitle("Problems")
        .toolbar {
            if !monitor.servers.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(monitor.servers.count == 1 ? "1 source" : "\(monitor.servers.count) sources", action: showServers)
                        .font(.system(size: 15))
                        .foregroundStyle(theme.link)
                }
            }
        }
        .refreshable { await monitor.refreshAll() }
        .navigationDestination(for: ProblemEntry.ID.self) { id in
            PhoneProblemDetail(entryID: id)
        }
        .sheet(item: $adding) { kind in ServerFormView(model: ServerFormModel(kind: kind)) }
        .onChange(of: summary.groups.map(\.severity)) { _, severities in
            if let filter, !severities.contains(filter) { self.filter = nil }
        }
    }

    /// Every enabled server is still loading for the first time, so there is nothing to say yet.
    private var isWaitingForFirstAnswer: Bool {
        let enabled = monitor.servers.filter(\.isActive)
        return !enabled.isEmpty && enabled.allSatisfy { server in
            switch monitor.states[server.id] {
            case .loading, nil: true
            default: false
            }
        }
    }

    // MARK: Problems

    private func problems(_ summary: MonitorSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryCard(summary)
            chips(summary)
            ForEach(summary.groups.filter { filter == nil || $0.severity == filter }) { group in
                Text(group.severity.label)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.52)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.severityText(group.severity))
                    .padding(EdgeInsets(top: 16, leading: 32, bottom: 6, trailing: 32))
                card {
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { theme.surfaceDivider.frame(height: 1) }
                        NavigationLink(value: entry.id) { PhoneProblemRow(problem: entry.problem) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if filter == nil, let unreachable = summary.unreachable {
                Text("Unreachable")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.52)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.severityText(.unknown))
                    .padding(EdgeInsets(top: 16, leading: 32, bottom: 6, trailing: 32))
                card {
                    Button(action: showServers) {
                        PhoneRow(severity: .unknown, title: unreachable.server.name, trailing: "›",
                                 subtitle: "Can't reach \(unreachable.server.baseURL.host() ?? unreachable.server.name)",
                                 output: unreachable.message)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.bottom, 24)
    }

    private func summaryCard(_ summary: MonitorSummary) -> some View {
        // The design sets Polly's words ("Polly is squawking") above the count ("1 host down").
        HStack(spacing: 14) {
            PollyMascot(mood: summary.mood, size: 64)
            VStack(alignment: .leading, spacing: 2) {
                if let kicker = summary.headlineKicker {
                    Text(kicker).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.moodText(summary.mood))
                }
                Text(summary.headlineTitle).font(.system(size: 21, weight: .bold))
                Text(summary.countsLine).font(.system(size: 13)).foregroundStyle(theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 20))
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
        .accessibilityElement(children: .combine)
    }

    private func chips(_ summary: MonitorSummary) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(selected: filter == nil) { filter = nil } label: {
                    Text("All \(summary.entries.count)").fontWeight(.semibold)
                }
                ForEach(summary.groups) { group in
                    chip(selected: filter == group.severity) {
                        filter = filter == group.severity ? nil : group.severity
                    } label: {
                        HStack(spacing: 5) {
                            StatusIcon(severity: group.severity, size: 14)
                            Text("\(group.entries.count)")
                        }
                    }
                    .accessibilityLabel("\(group.entries.count) \(group.severity.label)")
                }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 4, trailing: 16))
        }
    }

    private func chip(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: 14))
                .foregroundStyle(selected ? theme.chipActiveText : theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? theme.chipActive : theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0, content: content)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
    }

    // MARK: Empty states

    private func emptyState(_ summary: MonitorSummary) -> some View {
        VStack(spacing: 10) {
            PollyMascot(mood: summary.screen == .empty ? .ok : summary.mood, size: 168)
            switch summary.screen {
            case .empty:
                Text(summary.headline).font(.system(size: 26, weight: .bold)).padding(.top, 14)
                Text(summary.allDisabled ? "Turn a source on in Sources, or add one, and Polly starts polling right away."
                                         : "Add a Nagios server, a URL or a feed and Polly starts polling right away.")
                    .font(.system(size: 14)).foregroundStyle(theme.faint).lineSpacing(6).padding(.top, 8)
                Menu("Add source…") {
                    Button("Nagios Server…", systemImage: "server.rack") { adding = .nagios }
                    Button("URL…", systemImage: "globe") { adding = .url }
                }
                .menuStyle(.button)
                .font(.system(size: 17, weight: .semibold))
                .buttonStyle(PollyButtonStyle(kind: .primary, horizontal: 22, vertical: 14, radius: 14))
                .padding(.top, 10)
            case .waiting:
                Text(summary.headline).font(.system(size: 26, weight: .bold)).padding(.top, 14)
                Text(summary.isPaused ? "Resume a source in Sources and Polly starts checking again." : "Waiting for the first answer.")
                    .font(.system(size: 14)).foregroundStyle(theme.faint).lineSpacing(6).padding(.top, 8)
            case .unreachable:
                Text(summary.headline).font(.system(size: 26, weight: .bold)).padding(.top, 14)
                Text("\(summary.unreachable?.message ?? "") Polly keeps trying every \(Int(monitor.pollInterval.components.seconds)) s.")
                    .font(.system(size: 14)).foregroundStyle(theme.faint).lineSpacing(6).padding(.top, 8)
                HStack(spacing: 8) {
                    Button("Retry now") { Task { await monitor.refreshAll() } }
                        .buttonStyle(PollyButtonStyle(kind: .primary, horizontal: 16, vertical: 9, radius: 10))
                    Button("Edit source…") {
                        monitor.editRequest = summary.unreachable?.server.id
                        showServers()
                    }
                        .buttonStyle(PollyButtonStyle(horizontal: 16, vertical: 9, radius: 10))
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 10)
            case .ok, .problems:
                Text("Polly is quiet.").font(.system(size: 26, weight: .bold)).padding(.top, 14)
                Text("Go back to sleep.").font(.system(size: 20)).foregroundStyle(theme.muted)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(summary.quietDetail(now: context.date))
                }
                .font(.system(size: 14))
                .foregroundStyle(theme.faint)
                .lineSpacing(6)
                .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .padding(EdgeInsets(top: 70, leading: 40, bottom: 24, trailing: 40))
        .frame(maxWidth: .infinity)
    }
}

/// One problem in the list: host, age, service and the first line of the check output.
struct PhoneProblemRow: View {
    let problem: ServiceProblem

    var body: some View {
        TimelineView(.everyMinute) { context in
            PhoneRow(severity: problem.severity, title: problem.host,
                     trailing: problem.since.map { "\(DurationFormatting.short(context.date.timeIntervalSince($0)))  ›" } ?? "›",
                     subtitle: problem.title + problem.stateNote, output: problem.output)
        }
        .opacity(problem.acknowledged ? 0.55 : 1)
    }
}

/// The row layout of the iPhone list: status icon, then title with a trailing note, a second line and
/// monospaced output.
struct PhoneRow: View {
    let severity: Severity
    let title: String
    let trailing: String
    let subtitle: String
    var output = ""
    @Environment(\.pollyTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(severity: severity, size: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(trailing).font(.system(size: 14)).foregroundStyle(theme.muted).lineLimit(1).fixedSize()
                }
                Text(subtitle).font(.system(size: 14)).foregroundStyle(theme.secondary)
                if !output.isEmpty {
                    Text(output)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
