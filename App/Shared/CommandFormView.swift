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
