import PollyKit
import SwiftUI

/// Form for adding, editing or duplicating a Nagios server or a URL to check. Pasting `https://user:pass@host/`
/// fills username and password. The connection is tested before saving (for an edit only when the connection
/// changed); if the test fails the user can still choose "Add Anyway" / "Save Anyway".
struct ServerFormView: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pollyTheme) private var theme
    @State private var model: ServerFormModel
    @State private var saveError: String?

    init(model: ServerFormModel) {
        _model = State(initialValue: model)
    }

    private var isURLMonitor: Bool { model.kind == .url }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("URL", text: $model.urlFieldText,
                              prompt: Text(verbatim: isURLMonitor ? "https://www.example.com/" : "https://nagios.example.com"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    TextField("Name", text: $model.name, prompt: Text(model.parsedURL?.host() ?? "Optional"))
                } footer: {
                    if let url = model.parsedURL {
                        if isURLMonitor {
                            Text("Polly checks that \(url.host() ?? "the host") resolves, that \(url.absoluteString) answers"
                                 + (url.scheme == "https" ? ", and that its certificate is valid for at least two more weeks." : "."))
                        } else {
                            Text("Status is read from \(url.appending(path: "nagios/cgi-bin/statusjson.cgi").absoluteString)")
                        }
                    }
                }
                .listRowBackground(theme.surface)

                Section {
                    TextField("Username", text: $model.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                } header: {
                    Text(isURLMonitor ? "Credentials (optional)" : "Credentials")
                } footer: {
                    if isURLMonitor {
                        Text("Only needed for a page behind HTTP Basic authentication.")
                    }
                }
                .listRowBackground(theme.surface)

                Section {
                    checkStatus
                }
                .listRowBackground(theme.surface)
            }
            .formStyle(.grouped)
            .phoneListBackground(theme)
            .navigationTitle(model.isEditing ? (isURLMonitor ? "Edit URL" : "Edit Nagios Server")
                             : (isURLMonitor ? "Add URL" : "Add Nagios Server"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isEditing ? "Save" : "Add") { Task { await testAndSave() } }
                        .disabled(!model.canSubmit)
                }
            }
        }
        .interactiveDismissDisabled(model.checkState == .checking)
        .onAppear { model.wireLog = monitor.debugLog ? monitor.wireLog : nil }
    }

    @ViewBuilder private var checkStatus: some View {
        switch model.checkState {
        case .idle:
            Button("Test Connection") { Task { await model.testConnection() } }
                .disabled(!model.canSubmit)
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Testing connection…") }
        case .succeeded:
            Label { Text("Connection OK") } icon: { StatusIcon(severity: .ok, size: 18) }
                .foregroundStyle(theme.severityText(.ok))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label { Text(message) } icon: { StatusIcon(severity: .critical, size: 18) }
                    .foregroundStyle(theme.severityText(.critical))
                HStack {
                    Button("Retry") { Task { await model.testConnection() } }
                    Button(model.isEditing ? "Save Anyway" : "Add Anyway") { save() }
                }
            }
        }
        if let saveError {
            Text(saveError).foregroundStyle(theme.severityText(.critical))
        }
    }

    private func testAndSave() async {
        if model.checkState == .succeeded || !model.needsConnectionTest {
            save()
        } else if await model.testConnection() {
            save()
        }
        // On failure the form shows the error with an "Add Anyway" / "Save Anyway" override.
    }

    private func save() {
        guard let server = model.makeServer() else { return }
        let password = model.password.isEmpty ? nil : model.password
        do {
            if model.isEditing {
                try monitor.update(server, password: password)
            } else {
                try monitor.add(server, password: password)
            }
            dismiss()
        } catch {
            saveError = "Could not save source: \(error.localizedDescription)"
        }
    }
}
