import PollyKit
import SwiftUI

/// Form for adding, editing or duplicating a Nagios server, a URL to check or a feed. Pasting `https://user:pass@host/`
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

    /// "Nagios Server", "URL" or "Feed", for the title.
    private var kindTitle: String {
        switch model.kind {
        case .nagios: "Nagios Server"
        case .url: "URL"
        case .feed: "Feed"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("URL", text: $model.urlFieldText, prompt: Text(verbatim: model.kind.urlPlaceholder))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    TextField("Name", text: $model.name, prompt: Text(model.parsedURL?.host() ?? "Optional"))
                } footer: {
                    if let url = model.parsedURL {
                        switch model.kind {
                        case .url:
                            Text("Polly checks that \(url.host() ?? "the host") resolves, that \(url.absoluteString) answers"
                                 + (url.scheme == "https" ? ", and that its certificate is valid for at least two more weeks." : "."))
                        case .feed:
                            Text("Polly reads the feed from \(url.absoluteString)")
                        case .nagios:
                            Text("Status is read from \(url.appending(path: "nagios/cgi-bin/statusjson.cgi").absoluteString)")
                        }
                    }
                }
                .listRowBackground(theme.surface)

                Section {
                    Picker("Sign in with", selection: $model.authentication) {
                        ForEach(ServerFormModel.Authentication.allCases) { Text($0.label).tag($0) }
                    }
                    if model.authentication == .header {
                        TextField("Header", text: $model.headerName, prompt: Text(verbatim: "X-API-Key or Authorization"))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Value", text: $model.password, prompt: Text(verbatim: "Bearer … or the API key"))
                    } else {
                        TextField("Username", text: $model.username)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $model.password)
                            .textContentType(.password)
                    }
                } header: {
                    Text(model.kind == .nagios ? "Credentials" : "Credentials (optional)")
                } footer: {
                    if let problem = model.headerNameProblem, !model.headerName.isEmpty {
                        Text(problem).foregroundStyle(theme.severityText(.critical))
                    } else if model.authentication == .header {
                        Text("The value is sent as this header with every request, for example Authorization with \"Bearer <token>\".")
                    } else if isURLMonitor {
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
            .navigationTitle("\(model.isEditing ? "Edit" : "Add") \(kindTitle)")
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
