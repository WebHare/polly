import PollyKit
import SwiftUI

/// The settings window: a sidebar with panes, following "04 Settings" of the design export.
/// Servers is real; Alerts is a clickable prototype; Team and Account are placeholders.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case servers = "Sources"
        case alerts = "Alerts"
        case team = "Team"
        case account = "Account"
        case about = "About Polly"

        var id: Self { self }

        var color: Color {
            switch self {
            case .servers: Color(hex: 0x2B6FE6)
            case .alerts: Color(hex: 0xFF9F1C)
            case .team: Color(hex: 0x1E9E63)
            case .account: Color(hex: 0x7C6CF0)
            case .about: Color(hex: 0x7D869B)
            }
        }
    }

    @Environment(MonitorModel.self) private var monitor
    @State private var pane = Pane.servers

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $pane)
            ScrollView {
                Group {
                    switch pane {
                    case .servers: ServersPane()
                    case .alerts: AlertsPane()
                    case .team: TeamPane()
                    case .account: NotBuiltPane(title: pane.rawValue)
                    case .about: AboutPane()
                    }
                }
                .padding(.top, 22)
                .padding(.horizontal, 26)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 800, minHeight: 560)
        .modifier(WindowBackground())
        .pollyThemed()
        .onChange(of: monitor.editRequest, initial: true) {
            if monitor.editRequest != nil { pane = .servers }
        }
    }
}

private struct WindowBackground: ViewModifier {
    @Environment(\.pollyTheme) private var theme
    func body(content: Content) -> some View { content.background(theme.window) }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsView.Pane
    @Environment(\.pollyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsView.Pane.allCases) { item in
                let selected = item == selection
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 5).fill(item.color).frame(width: 18, height: 18)
                        Text(item.rawValue)
                    }
                    .fontWeight(selected ? .semibold : .regular)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? theme.sidebarSelection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        // The real traffic lights of the hidden title bar sit in the top 44 pt.
        .padding(.top, 44)
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.sidebar)
    }
}

// MARK: - Shared pieces

private struct PaneHeader: View {
    let title: String
    let subtitle: String
    @Environment(\.pollyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 20, weight: .bold))
            Text(subtitle).foregroundStyle(theme.muted)
        }
    }
}

private struct CardModifier: ViewModifier {
    var filled: Bool
    @Environment(\.pollyTheme) private var theme

    func body(content: Content) -> some View {
        content
            // The light design draws the server list on the window background, only bordered.
            .background(filled || theme.dark ? theme.card : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.cardBorder, lineWidth: 1))
    }
}

extension View {
    fileprivate func settingsCard(filled: Bool = true) -> some View { modifier(CardModifier(filled: filled)) }
}

private struct RowDivider: View {
    @Environment(\.pollyTheme) private var theme
    var body: some View { Rectangle().fill(theme.rowDivider).frame(height: 1) }
}

/// Title, 12 pt subtitle and a switch: the filter row of the design.
private struct SwitchRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    @ViewBuilder var accessory: Accessory
    @Environment(\.pollyTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(theme.faint)
                accessory
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(PollyToggleStyle())
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }
}

extension SwitchRow where Accessory == EmptyView {
    init(title: String, subtitle: String, isOn: Binding<Bool>) {
        self.init(title: title, subtitle: subtitle, isOn: isOn) { EmptyView() }
    }
}

// MARK: - Servers

private struct ServersPane: View {
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.pollyTheme) private var theme
    /// The open add/edit form, if any; it says what it is for.
    @State private var form: ServerFormModel?
    @State private var selectedSource: NagiosServer?
    /// The type last used in the add form, so the next one starts with it.
    @State private var lastKind = BackendKind.nagios
    @State private var errorMessage: String?

    private var pollSeconds: Int64 { monitor.pollInterval.components.seconds }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "Sources",
                       subtitle: "Polly polls these straight from this Mac. Nothing goes through our servers.")
            HStack {
                Spacer()
                Button("Add", systemImage: "plus") { openForm(ServerFormModel(kind: lastKind)) }
                    .buttonStyle(PollyButtonStyle(kind: .primary, horizontal: 12, vertical: 4, radius: 6))
            }
            serverList
            advanced
        }
        .sheet(item: $form) { form in
            ServerFormSheet(model: form) {
                if !form.isEditing { lastKind = form.kind }
                self.form = nil
            }
        }
        .sheet(item: $selectedSource) { server in
            SourceStatusView(server: server)
        }
        .onChange(of: monitor.editRequest, initial: true) { openRequestedEdit() }
        .alert("Error", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { Text($0) }
    }

    // MARK: Server list

    private var serverList: some View {
        VStack(spacing: 0) {
            if monitor.servers.isEmpty {
                Text("No sources yet. Click Add to get started.")
                    .foregroundStyle(theme.faint)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(monitor.servers.enumerated()), id: \.element.id) { index, server in
                if index > 0 { RowDivider() }
                serverRow(server)
            }
        }
        .settingsCard(filled: false)
    }

    private func serverRow(_ server: NagiosServer) -> some View {
        HStack(spacing: 10) {
            Button {
                selectedSource = server
            } label: {
                HStack(spacing: 10) {
                    ServerStateIcon(server: server, state: monitor.states[server.id], size: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.name).fontWeight(.semibold)
                            + Text(" · \(server.kind.displayName)").foregroundStyle(theme.faint)
                        ServerLineText(server: server, state: monitor.states[server.id])
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").foregroundStyle(theme.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Show status and problems for this source")
            .accessibilityIdentifier("source-status-\(server.id)")
            Text("every \(pollSeconds) s").font(.system(size: 12)).foregroundStyle(theme.faint)
            Button("Edit source", systemImage: "pencil") { edit(server) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(theme.faint)
                .help("Edit this source")
            Button(server.notifications ? "Turn off notifications" : "Turn on notifications",
                   systemImage: server.notifications ? "bell.fill" : "bell.slash") {
                setNotifications(!server.notifications, for: server)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(theme.faint)
            .help(server.notifications ? "Notifications are on for this source" : "Notifications are off for this source")
            Toggle("Enable \(server.name)", isOn: enabledBinding(for: server))
                .labelsHidden()
                .toggleStyle(PollyToggleStyle())
                .help(server.enabled ? "Disable this source: Polly leaves it out of the menu bar panel" : "Enable this source")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Show status…") { selectedSource = server }
            Button("Edit…") { edit(server) }
            Button("Duplicate…") { duplicate(server) }
            Divider()
            Button("Refresh") { Task { await monitor.refresh(server) } }
            if server.enabled {
                Button(server.isPaused ? "Resume" : "Pause") { setPaused(!server.isPaused, for: server) }
            }
            Button("Delete", role: .destructive) { delete(server) }
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Advanced").font(.system(size: 15, weight: .bold))
                .padding(.top, 16)
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
            SwitchRow(title: "Store passwords in Keychain",
                      subtitle: monitor.passwordStorage == .keychain
                          ? "Passwords are stored in the system keychain."
                          : "Passwords are stored unencrypted in polly.yaml; the keychain is not used.",
                      isOn: keychainBinding)
            RowDivider()
            SwitchRow(title: "Show Dock icon", subtitle: "Show Polly in the Dock and the app switcher.",
                      isOn: dockIconBinding)
            RowDivider()
            SwitchRow(title: "Log server traffic",
                      subtitle: "For debugging: writes every request and response, without credentials, to polly-debug.log next to polly.yaml.",
                      isOn: debugLogBinding) {
                if let wireLog = monitor.wireLog, monitor.debugLog {
                    Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([wireLog.fileURL]) }
                        .buttonStyle(PollyLinkStyle())
                        .font(.system(size: 12))
                        .padding(.top, 3)
                }
            }
        }
        .settingsCard()
    }

    // MARK: Actions

    private func openForm(_ form: ServerFormModel) {
        form.wireLog = monitor.debugLog ? monitor.wireLog : nil
        self.form = form
    }

    private func edit(_ server: NagiosServer) {
        do { openForm(try monitor.editForm(for: server)) } catch { errorMessage = error.localizedDescription }
    }

    private func duplicate(_ server: NagiosServer) {
        do { openForm(try monitor.duplicateForm(for: server)) } catch { errorMessage = error.localizedDescription }
    }

    private func openRequestedEdit() {
        guard let id = monitor.editRequest else { return }
        monitor.editRequest = nil
        guard form == nil, let server = monitor.servers.first(where: { $0.id == id }) else { return }
        edit(server)
    }

    private var keychainBinding: Binding<Bool> {
        Binding {
            monitor.passwordStorage == .keychain
        } set: { useKeychain in
            do {
                try monitor.setPasswordStorage(useKeychain ? .keychain : .file)
            } catch {
                errorMessage = "Could not move passwords: \(error.localizedDescription)"
            }
        }
    }

    private var dockIconBinding: Binding<Bool> {
        Binding {
            monitor.showDockIcon
        } set: { show in
            do {
                try monitor.setShowDockIcon(show)
                DockIcon.apply(show)
            } catch {
                errorMessage = "Could not save setting: \(error.localizedDescription)"
            }
        }
    }

    private var debugLogBinding: Binding<Bool> {
        Binding {
            monitor.debugLog
        } set: { enabled in
            do { try monitor.setDebugLog(enabled) } catch { errorMessage = "Could not save setting: \(error.localizedDescription)" }
        }
    }

    private func setNotifications(_ enabled: Bool, for server: NagiosServer) {
        Task {
            if enabled, await !Notifier.shared.requestAuthorization() {
                errorMessage = "Notifications are not allowed for Polly. Allow them in the system settings first."
                return
            }
            do { try monitor.setNotifications(enabled, for: server) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func setPaused(_ paused: Bool, for server: NagiosServer) {
        do { try monitor.setPaused(paused, for: server) } catch { errorMessage = error.localizedDescription }
    }

    private func enabledBinding(for server: NagiosServer) -> Binding<Bool> {
        Binding {
            server.enabled
        } set: { enabled in
            do { try monitor.setEnabled(enabled, for: server) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func delete(_ server: NagiosServer) {
        do { try monitor.delete(server) } catch { errorMessage = error.localizedDescription }
    }
}

/// The add/edit server form, shown as a sheet. It gets the form model directly, so the fields and the
/// buttons always work on the same model and this view updates as it changes.
private struct ServerFormSheet: View {
    @Bindable var model: ServerFormModel
    let close: () -> Void
    @Environment(MonitorModel.self) private var monitor
    @Environment(\.pollyTheme) private var theme
    @State private var errorMessage: String?

    private var pollSeconds: Int64 { monitor.pollInterval.components.seconds }

    var body: some View {
        serverFormCard
            .frame(width: 720)
            .interactiveDismissDisabled(model.checkState == .checking)
            .alert("Error", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
                Button("OK") { errorMessage = nil }
            } message: { Text($0) }
    }

    private var serverFormCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isEditing ? "Edit source" : "Add a source").font(.system(size: 15, weight: .bold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    label("Type")
                    HStack(spacing: 8) {
                        TypePicker(selection: $model.kind)
                        PlaceholderTag()
                    }
                }
                GridRow {
                    label("URL")
                    TextField("URL", text: $model.urlFieldText,
                              prompt: Text(verbatim: model.kind == .url ? "https://www.example.com/" : "https://nagios.example.com"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .pollyField()
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    (model.kind == .url
                        ? Text("Polly checks DNS, the HTTP answer and, for https, the certificate itself.")
                        : Text("Polly reads ")
                            + Text("cgi-bin/statusjson.cgi").font(.system(size: 12, design: .monospaced))
                            + Text(" (Nagios 4.4 or newer)."))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.faint)
                        .padding(.top, -4)
                }
                GridRow {
                    label("Name")
                    TextField("Name", text: $model.name, prompt: Text(model.parsedURL?.host() ?? "Optional"))
                        .pollyField()
                }
                GridRow {
                    label("Username")
                    TextField("Username", text: $model.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .pollyField()
                }
                GridRow {
                    label("Password")
                    HStack(spacing: 10) {
                        SecureField("Password", text: $model.password)
                            .textContentType(.password)
                            .pollyField()
                        Text(monitor.passwordStorage == .keychain ? "Stored in your Keychain" : "Stored in polly.yaml")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.faint)
                    }
                }
                GridRow {
                    label("Poll every")
                    HStack(spacing: 8) {
                        HStack(spacing: 14) {
                            Text("\(pollSeconds) seconds ⌄")
                                .padding(.vertical, 4)
                                .padding(.horizontal, 10)
                                .background(theme.field, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.fieldBorder, lineWidth: 1))
                            Toggle("Verify TLS certificate", isOn: .constant(true))
                                .toggleStyle(PollyCheckboxStyle())
                        }
                        .placeholderControl()
                        PlaceholderTag()
                    }
                }
            }
            .disabled(model.checkState == .checking)
            banner
            HStack(spacing: 8) {
                Button(model.checkState == .idle ? "Test connection" : "Test again") {
                    Task { await test() }
                }
                .disabled(!model.canSubmit)
                if case .failed = model.checkState {
                    Button(model.isEditing ? "Save anyway" : "Add anyway") { save() }
                }
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.checkState == .checking)
                Button(model.isEditing ? "Save" : "Add source") { Task { await testAndSave() } }
                    .buttonStyle(PollyButtonStyle(kind: .primary, horizontal: 12, vertical: 4, radius: 6))
                    .disabled(!model.canSubmit)
            }
            .buttonStyle(PollyButtonStyle(kind: .outlined, horizontal: 12, vertical: 4, radius: 6))
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .settingsCard()
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(theme.muted).frame(width: 110, alignment: .trailing)
    }

    @ViewBuilder private var banner: some View {
        switch model.checkState {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Testing connection…").foregroundStyle(theme.muted)
            }
        case .succeeded:
            bannerRow(severity: .ok, background: theme.successBackground,
                      text: Text("Connected.").bold() + Text(" Polly likes this one."))
        case .failed(let message):
            bannerRow(severity: .critical, background: theme.failureBackground, text: Text(message))
        }
    }

    private func bannerRow(severity: Severity, background: Color, text: Text) -> some View {
        HStack(spacing: 8) {
            StatusIcon(severity: severity, size: 16)
            text.frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(theme.severityText(severity))
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Actions

    private func test() async {
        await model.testConnection()
    }

    private func testAndSave() async {
        if model.checkState == .succeeded || !model.needsConnectionTest {
            save()
        } else if await model.testConnection() {
            save()
        }
        // On failure the banner shows the error and "Add anyway" / "Save anyway" appears.
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
            close()
        } catch {
            errorMessage = "Could not save source: \(error.localizedDescription)"
        }
    }
}


/// The type segmented control: Nagios and URL work, the other systems are drawn from the design.
private struct TypePicker: View {
    @Binding var selection: BackendKind
    @Environment(\.pollyTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BackendKind.allCases) { kind in
                Button { selection = kind } label: {
                    Text(kind.displayName)
                        .fontWeight(kind == selection ? .semibold : .regular)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 14)
                        .background {
                            if kind == selection {
                                RoundedRectangle(cornerRadius: 5).fill(theme.dark ? theme.card : Color.white)
                                    .shadow(color: Color.pollyNavy.opacity(0.18), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Type: \(kind.displayName)")
                .accessibilityAddTraits(kind == selection ? .isSelected : [])
            }
            HStack(spacing: 0) {
                ForEach(["Icinga 2", "Checkmk", "Zabbix"], id: \.self) { name in
                    Text(name).padding(.vertical, 3).padding(.horizontal, 14)
                }
            }
            .placeholderControl()
        }
        .padding(2)
        .background(theme.button, in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }
}

// MARK: - Alerts (prototype)

private struct AlertsPane: View {
    private struct Filter {
        let name: String
        let sub: String
        var on: Bool
    }

    private struct Rule {
        let severity: Severity
        let when: String
        let then: String
        let tone: Tone
        enum Tone { case alarm, normal, quiet }
    }

    @Environment(\.pollyTheme) private var theme
    @Environment(MonitorModel.self) private var monitor
    @State private var errorMessage: String?
    @State private var filters = [
        Filter(name: "Hide acknowledged problems", sub: "They stay in the list, collapsed under “Acknowledged”.", on: true),
        Filter(name: "Hide soft states", sub: "Wait until the last retry confirms a problem.", on: true),
        Filter(name: "Hide hosts and services in downtime", sub: "Scheduled maintenance is not news.", on: true),
    ]
    @State private var quietHours = true
    @State private var letCriticalsThrough = true
    @State private var days = Set(0..<7)

    private let rules = [
        Rule(severity: .critical, when: "Critical on hosts matching prod-*",
             then: "Push + critical alert (breaks silent mode)", tone: .alarm),
        Rule(severity: .critical, when: "Any other critical", then: "Push notification", tone: .normal),
        Rule(severity: .unknown, when: "Unknown for more than 10 min", then: "Push notification", tone: .normal),
        Rule(severity: .warning, when: "Warning", then: "Menu bar only", tone: .quiet),
    ]
    private let dayNames = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                PaneHeader(title: "Alerts", subtitle: "What Polly shows, and when it is allowed to wake you.")
                HStack(spacing: 8) {
                    PlaceholderTag(text: "PROTOTYPE")
                    Text("Only hiding services on hosts that are down works; the rest is not saved or applied yet.")
                        .foregroundStyle(theme.muted)
                }
            }
            section("Filters") {
                VStack(spacing: 0) {
                    SwitchRow(title: "Hide services on hosts that are down", subtitle: "One dead host, one line.",
                              isOn: hideServicesBinding)
                    ForEach(filters.indices, id: \.self) { index in
                        RowDivider()
                        SwitchRow(title: filters[index].name, subtitle: filters[index].sub, isOn: $filters[index].on)
                    }
                }
                .settingsCard()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom) {
                    Text("Notification rules").pollySectionLabel(theme.faint)
                    Spacer()
                    Button("+ Add rule") {}
                        .buttonStyle(PollyLinkStyle())
                        .disabled(true)
                }
                VStack(spacing: 0) {
                    ForEach(rules.indices, id: \.self) { index in
                        if index > 0 { RowDivider() }
                        ruleRow(rules[index])
                    }
                }
                .settingsCard()
                Text("First matching rule wins. Push and critical alerts need Pro.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.faint)
            }
            section("Quiet hours") { quietHoursCard }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { Text($0) }
    }

    private var hideServicesBinding: Binding<Bool> {
        Binding {
            monitor.hideServicesOnDownHosts
        } set: { hide in
            do { try monitor.setHideServicesOnDownHosts(hide) } catch { errorMessage = "Could not save setting: \(error.localizedDescription)" }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).pollySectionLabel(theme.faint)
            content()
        }
    }

    private func ruleRow(_ rule: Rule) -> some View {
        RuleColumns {
            StatusIcon(severity: rule.severity, size: 15)
            Text(rule.when)
            Text("→").foregroundStyle(theme.faint)
            Text(rule.then).foregroundStyle(color(for: rule.tone))
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
    }

    private func color(for tone: Rule.Tone) -> Color {
        switch tone {
        case .alarm: theme.dark ? Color(hex: 0xFF9DA1) : theme.severityText(.critical)
        case .normal: theme.text
        case .quiet: theme.muted
        }
    }

    private var quietHoursCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Quiet hours").frame(maxWidth: .infinity, alignment: .leading)
                timeChip("22:00")
                Text("to").foregroundStyle(theme.faint)
                timeChip("07:00")
                Toggle("Quiet hours", isOn: $quietHours).labelsHidden().toggleStyle(PollyToggleStyle())
            }
            HStack(spacing: 6) {
                ForEach(dayNames.indices, id: \.self) { index in
                    let on = days.contains(index)
                    Button {
                        if on { days.remove(index) } else { days.insert(index) }
                    } label: {
                        Text(dayNames[index])
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? (theme.dark ? Color(hex: 0xBFD7FF) : theme.link) : theme.faint)
                            .frame(width: 34)
                            .padding(.vertical, 4)
                            .background(on ? Color.pollyBlue.opacity(0.25) : theme.divider,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Let critical alerts through")
                    Text("Between 22:00 and 07:00 Polly only squawks for criticals. Warnings wait for breakfast.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Let critical alerts through", isOn: $letCriticalsThrough)
                    .labelsHidden()
                    .toggleStyle(PollyToggleStyle())
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { RowDivider() }
        }
        .padding(12)
        .settingsCard()
    }

    private func timeChip(_ time: String) -> some View {
        Text(time)
            .monospacedDigit()
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(theme.divider, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The rule row grid of the design: columns of 20 pt, 1fr, 18 pt and 1.15fr with 10 pt gaps.
private struct RuleColumns: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        let height = zip(subviews, widths(width))
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: nil))
            x += width + 10
        }
    }

    private func widths(_ total: CGFloat) -> [CGFloat] {
        let flexible = max(0, total - 20 - 18 - 3 * 10)
        return [20, flexible / 2.15, 18, flexible * 1.15 / 2.15]
    }
}

// MARK: - Team, Account, About

private struct TeamPane: View {
    @Environment(\.pollyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NotBuiltPane(title: "Team")
            Text("The idea: share on-call duties with your team, so everyone knows who is handling an alert.")
                .foregroundStyle(theme.muted)
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shared on-call schedule").font(.headline)
                    Text("Plan who is on call and who takes over next.").foregroundStyle(theme.muted)
                }
                RowDivider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Escalation").font(.headline)
                    Text("If nobody acknowledges an alert, notify the next person on duty.").foregroundStyle(theme.muted)
                }
                RowDivider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Central billing").font(.headline)
                    Text("All Pro features for each team member, with one invoice for the whole team.").foregroundStyle(theme.muted)
                }
            }
            .padding(16)
            .settingsCard()
            Text("These are ideas for a future version. Team schedules, escalation and billing are not available yet.")
                .font(.callout)
                .foregroundStyle(theme.muted)
        }
    }
}

private struct NotBuiltPane: View {
    let title: String
    @Environment(\.pollyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 20, weight: .bold))
                PlaceholderTag()
            }
            Text("Not built yet.").foregroundStyle(theme.muted)
        }
    }
}

private struct AboutPane: View {
    @Environment(\.pollyTheme) private var theme

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 10) {
            PollyMascot(mood: .ok, size: 96)
            Text("Polly").font(.system(size: 20, weight: .bold))
            Text(AppRelease.versionLabel(info: Bundle.main.infoDictionary ?? [:]))
                .foregroundStyle(theme.muted).textSelection(.enabled)
            Button("What's New") { openWindow(id: WindowID.whatsNew) }
                .buttonStyle(PollyButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}
