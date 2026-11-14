import NaggieKit
import SwiftUI

/// Form for adding a server. Pasting `https://user:pass@host/` fills username and password.
/// The connection is tested before saving; if the test fails the user can still choose "Add Anyway".
struct AddServerView: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @State private var model = AddServerModel()
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("URL", text: $model.urlText, prompt: Text("https://nagios.example.com"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("Name", text: $model.name, prompt: Text(model.parsedURL?.host() ?? "Optional"))
                } footer: {
                    if let url = model.parsedURL {
                        Text("Status is read from \(url.appending(path: "nagios/cgi-bin/statusjson.cgi").absoluteString)")
                    }
                }

                Section("Credentials") {
                    TextField("Username", text: $model.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                }

                Section {
                    checkStatus
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Server")
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
