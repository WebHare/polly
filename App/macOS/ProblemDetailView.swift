import PollyKit
import SwiftUI

/// One problem in the popover: status, check output, timing and the actions its server supports.
struct ProblemDetailView: View {
    let entry: ProblemEntry
    /// 1-based place in the problem list, for "2 of 6".
    let position: Int
    let total: Int
    let back: () -> Void
    /// Moves to the previous (-1) or next (+1) problem without going back to the list.
    let step: (Int) -> Void

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
        VStack(alignment: .leading, spacing: 0) {
            if let command {
                bar { Button("‹ \(problem.service)") { self.command = nil }.keyboardShortcut(.cancelAction) }
                CommandFormView(command: command) {
                    self.command = nil
                } onSent: {
                    Task { await monitor.refresh(server) }
                }
            } else {
                bar {
                    Button("‹ Problems", action: back).keyboardShortcut(.cancelAction)
                    Spacer()
                    stepper
                }
                summary
                actions
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
    }

    private func bar(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) { content() }
                .buttonStyle(PollyLinkStyle())
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            theme.divider.frame(height: 1)
        }
    }

    private var stepper: some View {
        HStack(spacing: 8) {
            Text("\(position) of \(total)").font(.system(size: 12)).monospacedDigit().foregroundStyle(theme.faint)
            HStack(spacing: 2) {
                Button("Previous problem", systemImage: "arrow.up") { step(-1) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("Next problem", systemImage: "arrow.down") { step(1) }.keyboardShortcut(.downArrow, modifiers: [])
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(PollyButtonStyle(horizontal: 6, vertical: 3, radius: 5))
            .disabled(total < 2)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    StatusIcon(severity: problem.severity, size: 13, dark: true)
                    Text(problem.severity.label.uppercased())
                }
                .font(.system(size: 11, weight: .bold))
                .tracking(0.55)
                .foregroundStyle(problem.severity == .warning ? Color.pollyNavy : .white)
                .padding(EdgeInsets(top: 3, leading: 5, bottom: 3, trailing: 9))
                .background(problem.severity.pillColor, in: Capsule())
                if let attempt = problem.checkAttempt {
                    outlinedTag(attempt.label)
                }
                if problem.acknowledged { outlinedTag("ACK") }
                if problem.downtimeDepth > 0 { outlinedTag("DOWNTIME") }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(problem.service).font(.system(size: 17, weight: .bold))
                (Text(problem.host).fontWeight(.semibold).foregroundStyle(theme.text)
                    + Text(" · \(server.name) (\(server.kind.displayName))"))
                    .foregroundStyle(theme.muted)
            }
            if !problem.output.isEmpty || !problem.longOutput.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if !problem.output.isEmpty { Text(problem.output) }
                    if !problem.longOutput.isEmpty { Text(problem.longOutput).foregroundStyle(Color(hex: 0x7683A3)) }
                }
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(4)
                .textSelection(.enabled)
                .foregroundStyle(Color(hex: 0xE4EAF6))
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.pollyNavy, in: RoundedRectangle(cornerRadius: 8))
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        fact("Duration", problem.since.map { since in
                            "\(DurationFormatting.short(context.date.timeIntervalSince(since))) · since \(Self.clock(since))"
                        })
                        fact("Last check", problem.lastCheck.map { DurationFormatting.ago(context.date.timeIntervalSince($0)) })
                    }
                    GridRow {
                        fact("Next check", problem.nextCheck.map { DurationFormatting.until($0.timeIntervalSince(context.date)) })
                        // Polly keeps no record of what it notified about.
                        fact("Notified", "You · 09:21 push", placeholder: true)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
    }

    private func fact(_ label: String, _ value: String?, placeholder: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(label).font(.system(size: 11.5)).foregroundStyle(theme.faint)
                if placeholder { PlaceholderTag() }
            }
            Text(value ?? "Unknown").fontWeight(.semibold).monospacedDigit().opacity(placeholder ? 0.5 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outlinedTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(theme.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.dark ? theme.border : Color.pollyNavy.opacity(0.18), lineWidth: 1))
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if capabilities.contains(.commands) {
                Button("Acknowledge…") { prepare(.acknowledge) }
                    .buttonStyle(PollyButtonStyle(kind: .primary, vertical: 7, expands: true))
                    .disabled(problem.acknowledged)
            }
            HStack(spacing: 8) {
                if capabilities.contains(.commands) {
                    Button("Schedule downtime…") { prepare(.downtime) }
                        .buttonStyle(PollyButtonStyle(vertical: 6, expands: true))
                }
                Button {} label: {
                    HStack(spacing: 6) { Text("Recheck now"); PlaceholderTag() }
                }
                .buttonStyle(PollyButtonStyle(vertical: 6, expands: true))
                .disabled(true)
            }
            if capabilities.contains(.links) {
                HStack(spacing: 14) {
                    Button("Open in \(server.kind.displayName) ↗") {
                        run { openURL(try monitor.backend(for: server).checkURL(for: problem)) }
                    }
                    .help("Open this check on the server")
                    Button("Related link ↗") {
                        run { openURL(try await monitor.backend(for: server).relatedURL(for: problem)) }
                    }
                    .help("Open the action or notes link of this check")
                }
                .buttonStyle(PollyLinkStyle())
                .padding(.top, 2)
            }
            if working { ProgressView().controlSize(.small) }
            if let message {
                Text(message).foregroundStyle(theme.severityText(.critical)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(working)
        .padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))
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

    /// "09:18" today, with the date in front for anything older.
    private static func clock(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}

private extension Severity {
    /// Background of the status pill; these are the light-scheme fills in both schemes.
    var pillColor: Color {
        switch self {
        case .critical: Color(hex: 0xDC3B42)
        case .warning: Color(hex: 0xF2B21B)
        case .unknown: Color(hex: 0x7C6CF0)
        case .ok: Color(hex: 0x1E9E63)
        }
    }
}

/// Form for a prepared command, in the popover. Nothing is sent until the user confirms.
private struct CommandFormView: View {
    let command: any PreparedCommand
    let onClose: () -> Void
    let onSent: () -> Void

    @Environment(\.pollyTheme) private var theme
    @State private var input: CommandInput
    @State private var sending = false
    @State private var accepted = false
    /// One attempt per form: after an unconfirmed submission the user has to open a new form on purpose.
    @State private var attempted = false
    @State private var message: String?

    init(command: any PreparedCommand, onClose: @escaping () -> Void, onSent: @escaping () -> Void) {
        self.command = command
        self.onClose = onClose
        self.onSent = onSent
        _input = State(initialValue: command.defaults)
    }

    private var isDowntime: Bool { command.kind == .downtime }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isDowntime ? "Schedule downtime" : "Acknowledge").font(.system(size: 17, weight: .bold))
                    Text(isDowntime ? "Polly stays quiet about it until the window ends." : "Polly will stop nagging.")
                        .foregroundStyle(theme.muted)
                }
                Group {
                    if isDowntime {
                        window
                        appliesTo
                    }
                    group("Author") { TextField("Author", text: $input.author).pollyField(horizontal: 10, vertical: 8, radius: 7) }
                    group("Comment") {
                        TextField("Required", text: $input.comment, axis: .vertical)
                            .lineLimit(2...4)
                            .pollyField(horizontal: 10, vertical: 8, radius: 7)
                    }
                    if isDowntime {
                        HStack(spacing: 8) {
                            Toggle("Also acknowledge the current problem", isOn: .constant(true))
                                .toggleStyle(PollyCheckboxStyle())
                                .placeholderControl()
                            PlaceholderTag()
                        }
                    } else {
                        Toggle("Ask the server to notify its contacts", isOn: $input.notify)
                            .toggleStyle(PollyCheckboxStyle())
                    }
                }
                .disabled(sending || attempted)
                if let message {
                    Text(message)
                        .foregroundStyle(accepted ? theme.muted : theme.severityText(.critical))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .autocorrectionDisabled()

            theme.divider.frame(height: 1)
            HStack(spacing: 8) {
                if sending { ProgressView().controlSize(.small) }
                Spacer()
                Button(attempted ? "Close" : "Cancel", action: onClose)
                    .buttonStyle(PollyButtonStyle())
                if !attempted {
                    Button(isDowntime ? "Schedule downtime" : "Acknowledge", action: send)
                        .buttonStyle(PollyButtonStyle(kind: .primary))
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .disabled(sending)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.footer)
        }
    }

    /// The design offers presets; Polly can't calculate in the server's time zone yet, so only "Custom" works.
    private var window: some View {
        group("For", placeholder: "PRESETS ARE PLACEHOLDERS") {
            HStack(spacing: 6) {
                ForEach(["30 min", "1 hour", "2 hours"], id: \.self) { chip($0).placeholderControl() }
            }
            HStack(spacing: 6) {
                chip("Until 09:00 tomorrow").placeholderControl()
                chip("Custom…", selected: true)
            }
            HStack(spacing: 6) {
                TextField("Start", text: $input.start).pollyField(horizontal: 10, vertical: 6, radius: 7)
                Text("→").foregroundStyle(theme.muted)
                TextField("End", text: $input.end).pollyField(horizontal: 10, vertical: 6, radius: 7)
            }
            Text("Server time, in the notation the server filled in.").font(.system(size: 12)).foregroundStyle(theme.muted)
        }
    }

    private var appliesTo: some View {
        group("Applies to") {
            HStack(spacing: 8) {
                Circle().strokeBorder(theme.chipSelected, lineWidth: 4).frame(width: 14, height: 14)
                Text("This service only")
            }
            .padding(.top, 2)
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Circle().strokeBorder(theme.faint, lineWidth: 1.5).frame(width: 14, height: 14)
                    Text("Host \(command.problem.host) and its services")
                }
                .placeholderControl()
                PlaceholderTag()
            }
            .padding(.top, 2)
        }
    }

    private func chip(_ text: String, selected: Bool = false) -> some View {
        Text(text)
            .fontWeight(selected ? .semibold : .regular)
            .foregroundStyle(selected ? theme.chipSelectedText : theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(selected ? theme.chipSelected : theme.button, in: Capsule())
    }

    private func group(_ label: String, placeholder: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 11.5)).foregroundStyle(theme.faint)
                if let placeholder { PlaceholderTag(text: placeholder) }
            }
            content()
        }
    }

    private func send() {
        do {
            try command.validate(input)
        } catch {
            message = error.localizedDescription
            return
        }
        sending = true
        message = nil
        Task {
            defer { sending = false }
            attempted = true
            do {
                try await command.submit(input)
                accepted = true
                message = "Accepted by the server. The status changes once it has processed the command."
                onSent()
            } catch {
                // A lost response does not prove the command was not accepted, so it is never sent again automatically.
                message = "Not confirmed: \(error.localizedDescription) Check the server in your browser before trying again."
            }
        }
    }
}
