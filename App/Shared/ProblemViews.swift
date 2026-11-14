import NaggieKit
import SwiftUI

/// The problems of one server. Click a problem for its check output and the actions its server supports.
struct ProblemList: View {
    let server: NagiosServer
    let problems: [ServiceProblem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(problems) { problem in
                ProblemRow(server: server, problem: problem)
            }
        }
        .font(.caption)
        .padding(.leading, 24)
    }
}

private struct ProblemRow: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.openURL) private var openURL
    let server: NagiosServer
    let problem: ServiceProblem

    @State private var expanded = false
    @State private var capabilities: BackendCapabilities = []
    @State private var command: (any PreparedCommand)?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) { summary }
                .buttonStyle(.plain)
            if expanded { details }
        }
    }

    private var summary: some View {
        HStack(spacing: 6) {
            Image(systemName: problem.severity.symbolName).foregroundStyle(problem.severity.color)
            Text(problem.host).bold()
            Text(problem.service)
            if problem.acknowledged {
                Image(systemName: "checkmark.bubble").help("Acknowledged").accessibilityLabel("Acknowledged")
            }
            if problem.downtimeDepth > 0 {
                Image(systemName: "moon.zzz").help("In scheduled downtime").accessibilityLabel("In scheduled downtime")
            }
            Spacer(minLength: 4)
            if let since = problem.since {
                ProblemAge(since: since)
            }
        }
        .contentShape(Rectangle())
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !problem.output.isEmpty {
                Text(problem.output).textSelection(.enabled)
            }
            if !problem.longOutput.isEmpty {
                Text(problem.longOutput).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let lastCheck = problem.lastCheck {
                Text("Last check \(lastCheck.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
            }
            if let command {
                CommandForm(command: command, serverName: server.name) {
                    self.command = nil
                } onSent: {
                    Task { await monitor.refresh(server) }
                }
            } else {
                actions
            }
            if let message {
                Text(message).foregroundStyle(.red)
            }
        }
        .padding(.leading, 20)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if capabilities.contains(.links) {
                Button("Open") { run { openURL(try monitor.backend(for: server).checkURL(for: problem)) } }
                    .help("Open this check on the server")
                Button("Related") { run { openURL(try await monitor.backend(for: server).relatedURL(for: problem)) } }
                    .help("Open the action or notes link of this check")
            }
            if capabilities.contains(.commands) {
                Button("Acknowledge…") { prepare(.acknowledge) }
                    .disabled(problem.acknowledged)
                Button("Downtime…") { prepare(.downtime) }
            }
            if working {
                ProgressView().controlSize(.small)
            }
        }
        .actionButtonStyle()
        .disabled(working)
    }

    private func toggle() {
        expanded.toggle()
        message = nil
        guard expanded else {
            command = nil
            return
        }
        // Creating a backend reads the password, so only do that for a row that is actually opened.
        capabilities = (try? monitor.backend(for: server).capabilities) ?? []
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

/// Inline form for a prepared command. Nothing is sent until the user confirms.
private struct CommandForm: View {
    let command: any PreparedCommand
    let serverName: String
    let onClose: () -> Void
    let onSent: () -> Void

    @State private var input: CommandInput
    @State private var sending = false
    @State private var accepted = false
    /// One attempt per form: after an unconfirmed submission the user has to open a new form on purpose.
    @State private var attempted = false
    @State private var message: String?

    init(command: any PreparedCommand, serverName: String, onClose: @escaping () -> Void, onSent: @escaping () -> Void) {
        self.command = command
        self.serverName = serverName
        self.onClose = onClose
        self.onSent = onSent
        _input = State(initialValue: command.defaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(command.kind == .acknowledge ? "Acknowledge on \(serverName)" : "Schedule downtime on \(serverName)").bold()
            Group {
                TextField("Author", text: $input.author)
                TextField("Comment (required)", text: $input.comment)
                if command.kind == .downtime {
                    TextField("Start", text: $input.start)
                    TextField("End", text: $input.end)
                    Text("Server time, in the notation the server filled in.").foregroundStyle(.secondary)
                } else {
                    Toggle("Ask the server to notify its contacts", isOn: $input.notify)
                }
            }
            .disabled(sending || attempted)
            if let message {
                Text(message).foregroundStyle(accepted ? Color.secondary : Color.red)
            }
            HStack(spacing: 12) {
                Button(attempted ? "Close" : "Cancel", action: onClose)
                if !attempted {
                    Button(command.kind == .acknowledge ? "Acknowledge" : "Schedule Downtime", action: send)
                }
                if sending {
                    ProgressView().controlSize(.small)
                }
            }
            .actionButtonStyle()
            .disabled(sending)
        }
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
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

private extension View {
    /// Borderless buttons are grey on macOS, which reads as disabled; links are tinted there.
    @ViewBuilder func actionButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
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
