import PollyKit
import SwiftUI

/// One problem on the iPhone: status, check output, timing and the actions its server supports.
struct PhoneProblemDetail: View {
    let entryID: ProblemEntry.ID

    @Environment(MonitorModel.self) private var monitor
    @Environment(\.pollyTheme) private var theme

    var body: some View {
        let entries = MonitorSummary(servers: monitor.servers, states: monitor.states).entries
        Group {
            if let index = entries.firstIndex(where: { $0.id == entryID }) {
                ProblemDetailContent(entry: entries[index])
                    // A new identity per problem, so the fetched capabilities and the form start over.
                    .id(entries[index].id)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Text("\(index + 1) of \(entries.count)")
                                .font(.system(size: 15))
                                .monospacedDigit()
                                .foregroundStyle(theme.faint)
                        }
                    }
            } else {
                ContentUnavailableView("Problem resolved", systemImage: "checkmark.circle",
                                       description: Text("The server no longer reports this problem."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.screen)
        .navigationBarTitleDisplayMode(.inline)
        .tint(theme.link)
    }
}

private struct ProblemDetailContent: View {
    let entry: ProblemEntry

    @Environment(MonitorModel.self) private var monitor
    @Environment(\.openURL) private var openURL
    @Environment(\.pollyTheme) private var theme
    @State private var capabilities: BackendCapabilities = []
    @State private var command: (any PreparedCommand)?
    @State private var working = false
    @State private var message: String?

    private var problem: ServiceProblem { entry.problem }
    private var server: NagiosServer { entry.server }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                tags
                VStack(alignment: .leading, spacing: 4) {
                    Text(problem.service)
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.28)
                    (Text(problem.host).fontWeight(.bold).foregroundStyle(theme.text) + Text(" · \(server.name)"))
                        .font(.system(size: 15))
                        .foregroundStyle(theme.muted)
                }
                output
                facts
                actions
            }
            .padding(EdgeInsets(top: 8, leading: 20, bottom: 24, trailing: 20))
        }
        .refreshable { await monitor.refresh(server) }
        // Creating a backend reads the password, so only do that for a problem that is actually opened.
        .onAppear {
            do {
                capabilities = try monitor.backend(for: server).capabilities
            } catch {
                // Without this a password that can't be read looks like a server without any actions.
                capabilities = []
                message = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding { command != nil } set: { if !$0 { command = nil } }) {
            if let command {
                ScrollView {
                    CommandFormView(command: command) {
                        self.command = nil
                    } onSent: {
                        Task { await monitor.refresh(server) }
                    }
                }
                .font(.system(size: 15))
                .background(theme.panel)
                .presentationDetents([.medium, .large])
                .phoneThemed()
            }
        }
    }

    private var tags: some View {
        HStack(spacing: 6) {
            StatusPill(severity: problem.severity)
            if let attempt = problem.checkAttempt { StateTag(text: attempt.label) }
            if problem.acknowledged { StateTag(text: "ACK") }
            if problem.downtimeDepth > 0 { StateTag(text: "DOWNTIME") }
        }
    }

    @ViewBuilder private var output: some View {
        if !problem.output.isEmpty || !problem.longOutput.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if !problem.output.isEmpty { Text(problem.output) }
                if !problem.longOutput.isEmpty { Text(problem.longOutput).foregroundStyle(Color(hex: 0x7683A3)) }
            }
            .font(.system(size: 12.5, design: .monospaced))
            .lineSpacing(6)
            .textSelection(.enabled)
            .foregroundStyle(Color(hex: 0xE4EAF6))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pollyNavy, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var facts: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                fact("Duration", problem.since.map { since in
                    "\(DurationFormatting.short(context.date.timeIntervalSince(since))) · since \(since.pollyClock)"
                })
                theme.surfaceDivider.frame(height: 1)
                fact("Last check", problem.lastCheck.map { DurationFormatting.ago(context.date.timeIntervalSince($0)) })
                theme.surfaceDivider.frame(height: 1)
                fact("Next check", problem.nextCheck.map { DurationFormatting.until($0.timeIntervalSince(context.date)) })
                theme.surfaceDivider.frame(height: 1)
                fact("Server", server.kind.displayName)
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func fact(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(theme.muted)
            Spacer()
            Text(value ?? "Unknown").fontWeight(.medium).monospacedDigit()
        }
        .font(.system(size: 16))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if capabilities.contains(.commands) {
                Button("Acknowledge") { prepare(.acknowledge) }
                    .font(.system(size: 17, weight: .semibold))
                    .buttonStyle(PollyButtonStyle(kind: .primary, vertical: 15, radius: 14, expands: true))
                    .disabled(problem.acknowledged)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                if capabilities.contains(.commands) {
                    tile("clock", "Downtime") { prepare(.downtime) }
                }
                tile("arrow.clockwise", "Recheck", placeholder: true) {}
                if capabilities.contains(.links) {
                    tile("arrow.up.right", "Open in \(server.kind.displayName)") {
                        run { openURL(try monitor.backend(for: server).checkURL(for: problem)) }
                    }
                }
            }
            if capabilities.contains(.links) {
                Button("Related link ↗") {
                    run { openURL(try await monitor.backend(for: server).relatedURL(for: problem)) }
                }
                .font(.system(size: 15))
                .buttonStyle(PollyLinkStyle())
                .padding(.top, 6)
            }
            if working { ProgressView() }
            if let message {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.severityText(.critical))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(working)
    }

    /// A 66 pt action tile: glyph above its label. A placeholder is drawn, tagged and does nothing.
    private func tile(_ symbol: String, _ label: String, placeholder: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(theme.tileGlyph).frame(height: 24)
                Text(label).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                if placeholder { PlaceholderTag().padding(5) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(placeholder)
        .opacity(placeholder ? 0.5 : 1)
    }

    private func prepare(_ kind: CommandKind) {
        run { command = try await monitor.backend(for: server).prepareCommand(kind, for: problem) }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        working = true
        message = nil
        Task {
            defer { working = false }
            do { try await action() } catch { message = error.localizedDescription }
        }
    }
}
