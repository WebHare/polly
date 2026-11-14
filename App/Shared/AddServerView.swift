import PollyKit
import SwiftUI

/// Form for adding a Nagios server or a URL to check. Pasting `https://user:pass@host/` fills username and
/// password. The connection is tested before saving; if the test fails the user can still choose "Add Anyway".
struct AddServerView: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @State private var model: AddServerModel
    @State private var saveError: String?

    init(kind: BackendKind) {
        _model = State(initialValue: AddServerModel(kind: kind))
    }

    private var isURLMonitor: Bool { model.kind == .url }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("URL", text: $model.urlText,
                              prompt: Text(isURLMonitor ? "https://www.example.com/" : "https://nagios.example.com"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
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

                Section {
                    TextField("Username", text: $model.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                } header: {
                    Text(isURLMonitor ? "Credentials (optional)" : "Credentials")
                } footer: {
                    if isURLMonitor {
                        Text("Only needed for a page behind HTTP Basic authentication.")
                    }
                }

                Section {
                    checkStatus
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isURLMonitor ? "Add URL" : "Add Nagios Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await testAndAdd() } }
                        .disabled(!model.canSubmit)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
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
            Label("Connection OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                HStack {
                    Button("Retry") { Task { await model.testConnection() } }
                    Button("Add Anyway") { save() }
                }
            }
        }
        if let saveError {
            Text(saveError).foregroundStyle(.red)
        }
    }

    private func testAndAdd() async {
        if model.checkState == .succeeded {
            save()
        } else if await model.testConnection() {
            save()
        }
        // On failure the form shows the error with an "Add Anyway" override.
    }

    private func save() {
        guard let server = model.makeServer() else { return }
        do {
            try monitor.add(server, password: model.password.isEmpty ? nil : model.password)
            dismiss()
        } catch {
            saveError = "Could not save server: \(error.localizedDescription)"
        }
    }
}
