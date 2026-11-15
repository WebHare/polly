import PollyKit
import SwiftUI

/// Form for a prepared command: in the macOS popover, and in a sheet on iOS. Nothing is sent until the user confirms.
struct CommandFormView: View {
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
    @FocusState private var endFocused: Bool

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
                        alsoAcknowledge
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

    /// Presets count from the start time. Polly can only calculate them when it can tell the server's date notation
    /// from the prefilled times; otherwise only typing the times works.
    private var window: some View {
        let selected = DowntimePreset.allCases.first { command.end(for: $0, from: input.start) == input.end }
        return group("For") {
            HStack(spacing: 6) {
                ForEach([DowntimePreset.thirtyMinutes, .oneHour, .twoHours]) { presetChip($0, selected: selected) }
            }
            HStack(spacing: 6) {
                presetChip(.untilTomorrowMorning, selected: selected)
                Button { endFocused = true } label: { chip("Custom…", selected: selected == nil) }
                    .buttonStyle(.plain)
                    .help("Type the start and end below")
            }
            HStack(spacing: 6) {
                TextField("Start", text: $input.start).pollyField(horizontal: 10, vertical: 6, radius: 7)
                Text("→").foregroundStyle(theme.muted)
                TextField("End", text: $input.end).pollyField(horizontal: 10, vertical: 6, radius: 7)
                    .focused($endFocused)
            }
            Text("Server time, in the notation the server filled in.").font(.system(size: 12)).foregroundStyle(theme.muted)
        }
    }

    private func presetChip(_ preset: DowntimePreset, selected: DowntimePreset?) -> some View {
        let end = command.end(for: preset, from: input.start)
        return Button { if let end { input.end = end } } label: { chip(preset.label, selected: preset == selected) }
            .buttonStyle(.plain)
            .disabled(end == nil)
            .opacity(end == nil ? 0.5 : 1)
            .help(end == nil ? "Polly can't tell this server's date notation from the start time. Type the end instead." : "")
    }

    private var appliesTo: some View {
        group("Applies to") {
            radio("This service only", selected: input.scope == .service) { input.scope = .service }
            radio("Host \(command.problem.host) and its services", selected: input.scope == .hostAndServices) {
                input.scope = .hostAndServices
            }
            .disabled(!command.options.contains(.hostScope))
            .opacity(command.options.contains(.hostScope) ? 1 : 0.5)
            .help(command.options.contains(.hostScope) ? "" : "The server does not allow you to schedule downtime for this host.")
        }
    }

    private func radio(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().strokeBorder(selected ? theme.chipSelected : theme.faint, lineWidth: selected ? 4 : 1.5)
                    .frame(width: 14, height: 14)
                Text(label)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .padding(.top, 2)
    }

    @ViewBuilder private var alsoAcknowledge: some View {
        if command.problem.acknowledged {
            Text("The problem is already acknowledged.").foregroundStyle(theme.muted)
        } else {
            Toggle("Also acknowledge the current problem", isOn: $input.alsoAcknowledge)
                .toggleStyle(PollyCheckboxStyle())
                .disabled(!command.options.contains(.alsoAcknowledge))
                .opacity(command.options.contains(.alsoAcknowledge) ? 1 : 0.5)
                .help(command.options.contains(.alsoAcknowledge) ? "" : "The server does not allow you to acknowledge this problem.")
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

    private func group(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(theme.faint)
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
            } catch let error as CommandSequenceError {
                // Part of it went through, so the server's status changes too.
                message = "\(error.localizedDescription) Check the server in your browser before trying again."
                onSent()
            } catch {
                // A lost response does not prove the command was not accepted, so it is never sent again automatically.
                message = "Not confirmed: \(error.localizedDescription) Check the server in your browser before trying again."
            }
        }
    }
}
