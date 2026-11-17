import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

/// App-wide state: the configured servers and their latest status. Polls periodically.
@MainActor
@Observable
public final class MonitorModel {
    public enum ServerState: Equatable, Sendable {
        case loading
        case ok(ServerStatus)
        case failed(String)
    }

    public private(set) var servers: [NagiosServer] = []
    public private(set) var states: [UUID: ServerState] = [:]
    public private(set) var lastError: String?
    public private(set) var passwordStorage: PasswordStorage = .keychain
    public private(set) var showDockIcon = false
    public private(set) var debugLog = false
    public private(set) var hideServicesOnDownHosts = true
    public var pollInterval: Duration = .seconds(60)
    /// When the poll loop refreshes all servers again; nil while it isn't running.
    public private(set) var nextPollAt: Date?
    /// Completed attempts, including failures; a started or canceled request is not a measurement.
    public private(set) var lastAttempts: [UUID: Date] = [:]
    public private(set) var lastSuccesses: [UUID: Date] = [:]
    public private(set) var lastPollCompletedAt: Date?
    /// A server whose edit form the server list should open ("Edit server…" on the Unreachable screen).
    /// The server list clears it once the form is open.
    public var editRequest: UUID?

    @ObservationIgnored public let store: ServerStore
    /// `polly-debug.log` next to polly.yaml; nil for an in-memory store. Only passed to backends while
    /// `debugLog` is on.
    @ObservationIgnored public let wireLog: WireLog?
    /// Called after a successful refresh of a server with `notifications == true`, when something changed.
    @ObservationIgnored public var onProblemChanges: ((NagiosServer, ProblemChanges) -> Void)?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Problems of the last successful fetch per server. A failed fetch keeps it, so an outage of the
    /// monitoring server itself doesn't report every problem as new once it is back.
    @ObservationIgnored private var baselines: [UUID: [ServiceProblem]] = [:]
    /// Number of the refresh started last per server. The poll and a manual refresh can overlap, and the
    /// answer that arrives last is not necessarily the newest.
    @ObservationIgnored private var lastRefresh: [UUID: Int] = [:]

    public init(store: ServerStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
        wireLog = store.fileURL.map { WireLog(fileURL: $0.deletingLastPathComponent().appending(path: "polly-debug.log")) }
        reload()
    }

    /// Worst severity over all servers; a server that can't be reached counts as unknown.
    public var overallSeverity: Severity {
        states.values.map { state -> Severity in
            switch state {
            case .ok(let status): status.severity
            case .failed: .unknown
            case .loading: .ok
            }
        }.max() ?? .ok
    }

    public var problemCount: Int {
        states.values.reduce(0) { total, state in
            if case .ok(let status) = state { return total + status.problems.count }
            if case .failed = state { return total + 1 }
            return total
        }
    }

    // MARK: - Server management

    public func reload() {
        servers = store.allServers()
        passwordStorage = store.passwordStorage
        showDockIcon = store.showDockIcon
        debugLog = store.debugLog
        hideServicesOnDownHosts = store.hideServicesOnDownHosts
        // Drop status of removed and disabled servers so they don't count towards the overall state.
        let active = Set(servers.filter(\.enabled).map(\.id))
        states = states.filter { active.contains($0.key) }
        baselines = baselines.filter { active.contains($0.key) }
        lastAttempts = lastAttempts.filter { active.contains($0.key) }
        lastSuccesses = lastSuccesses.filter { active.contains($0.key) }
    }

    public func setShowDockIcon(_ show: Bool) throws {
        defer { reload() }
        try store.setShowDockIcon(show)
    }

    public func setDebugLog(_ enabled: Bool) throws {
        defer { reload() }
        try store.setDebugLog(enabled)
    }

    public func setHideServicesOnDownHosts(_ hide: Bool) throws {
        defer { reload() }
        try store.setHideServicesOnDownHosts(hide)
    }

    /// What the overview shows, with the user's filters applied.
    public var summary: MonitorSummary {
        MonitorSummary(servers: servers, states: states, hideServicesOnDownHosts: hideServicesOnDownHosts)
    }

    public func setNotifications(_ enabled: Bool, for server: NagiosServer) throws {
        defer { reload() }
        try store.setNotifications(enabled, for: server.id)
    }

    /// The backend for a server, with its password. Used by the UI for links and commands.
    public func backend(for server: NagiosServer) throws -> any MonitorBackend {
        try server.makeBackend(password: store.password(for: server.id), session: session,
                           wireLog: debugLog ? wireLog : nil)
    }

    public func add(_ server: NagiosServer, password: String?) throws {
        try store.add(server, password: password)
        reload()
        Task { await refresh(server) }
    }

    /// Saves an edited server in place. A changed URL or type is a different system: its old status and
    /// notification baseline are dropped. An answer still in flight for the old settings is discarded.
    public func update(_ server: NagiosServer, password: String?) throws {
        let old = servers.first { $0.id == server.id }
        try store.update(server, password: password)
        lastRefresh[server.id, default: 0] += 1
        if old?.baseURL != server.baseURL || old?.kind != server.kind {
            states[server.id] = nil
            baselines[server.id] = nil
            lastAttempts[server.id] = nil
            lastSuccesses[server.id] = nil
        }
        reload()
        if let updated = enabledServer(server.id) {
            Task { await refresh(updated) }
        }
    }

    /// The form for editing a server, prefilled with its settings and password.
    public func editForm(for server: NagiosServer) throws -> ServerFormModel {
        let form = ServerFormModel(editing: server, password: try store.password(for: server.id), session: session)
        form.wireLog = debugLog ? wireLog : nil
        return form
    }

    /// The add form, prefilled with a copy of a server's settings and password.
    public func duplicateForm(for server: NagiosServer) throws -> ServerFormModel {
        let form = ServerFormModel(duplicating: server, password: try store.password(for: server.id), session: session)
        form.wireLog = debugLog ? wireLog : nil
        return form
    }

    /// Temporarily turns monitoring of a server on or off.
    public func setEnabled(_ enabled: Bool, for server: NagiosServer) throws {
        try store.setEnabled(enabled, for: server.id)
        reload()
        if enabled, let updated = servers.first(where: { $0.id == server.id }) {
            Task { await refresh(updated) }
        }
    }

    public func delete(_ server: NagiosServer) throws {
        try store.delete(server.id)
        reload()
    }

    /// Moves all passwords to the chosen storage. See `ServerStore.setPasswordStorage(_:)`.
    public func setPasswordStorage(_ storage: PasswordStorage) throws {
        defer { reload() }
        try store.setPasswordStorage(storage)
    }

    // MARK: - Polling

    public func setPollingActive(_ active: Bool) {
        if active {
            startPolling()
        } else {
            stopPolling()
        }
    }

    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAll()
                // Stopping during a request must not restore the canceled loop's schedule.
                guard !Task.isCancelled else { return }
                self.nextPollAt = Date.now + TimeInterval(self.pollInterval.components.seconds)
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        nextPollAt = nil
    }

    public func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers where server.enabled {
                group.addTask { await self.refresh(server) }
            }
        }
        if !Task.isCancelled { lastPollCompletedAt = .now }
    }

    /// Server shutdown waits until the canceled poll has unwound its network requests.
    public func stopPollingAndWait() async {
        let task = pollTask
        stopPolling()
        await task?.value
    }

    public func webSnapshot(now: Date = .now, redactions: [String] = []) -> WebSnapshot {
        WebSnapshot(servers: servers, states: states, lastAttempts: lastAttempts, lastSuccesses: lastSuccesses,
                    nextPollAt: nextPollAt, now: now, redactions: redactions, hideServicesOnDownHosts: hideServicesOnDownHosts)
    }

    public func refresh(_ server: NagiosServer) async {
        guard isEnabled(server.id) else { return }
        if states[server.id] == nil { states[server.id] = .loading }
        let number = (lastRefresh[server.id] ?? 0) + 1
        lastRefresh[server.id] = number
        let result: ServerState
        do {
            result = .ok(try await backend(for: server).fetchStatus())
        } catch {
            result = .failed(error.localizedDescription)
        }
        // The server may have been disabled or deleted while the request was in flight, or a refresh
        // that started later has taken over: its answer is the newer one, whichever arrives first.
        guard !Task.isCancelled, let current = enabledServer(server.id), lastRefresh[server.id] == number else { return }
        states[server.id] = result
        lastAttempts[server.id] = .now
        guard case .ok(let status) = result else { return }
        lastSuccesses[server.id] = status.fetchedAt
        let changes = NotificationPolicy.changes(previous: baselines[server.id], current: status.problems,
                                                  hideServicesOnDownHosts: hideServicesOnDownHosts)
        baselines[server.id] = status.problems
        if current.notifications, !changes.isEmpty { onProblemChanges?(current, changes) }
    }

    private func isEnabled(_ id: UUID) -> Bool {
        enabledServer(id) != nil
    }

    private func enabledServer(_ id: UUID) -> NagiosServer? {
        servers.first { $0.id == id && $0.enabled }
    }
}
