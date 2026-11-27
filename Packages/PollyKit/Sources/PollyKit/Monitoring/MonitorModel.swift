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
    public private(set) var syncWithICloud = true
    /// Why the last sync with iCloud failed; nil when it worked or isn't on.
    public private(set) var syncError: String?
    public var pollInterval: Duration = .seconds(60)
    /// When the poll loop refreshes all servers again; nil while it isn't running.
    public private(set) var nextPollAt: Date?
    /// Completed attempts, including failures; a started or canceled request is not a measurement.
    public private(set) var lastAttempts: [UUID: Date] = [:]
    public private(set) var lastSuccesses: [UUID: Date] = [:]
    public private(set) var lastPollCompletedAt: Date?
    /// Changes of a monitoring system's own notifications that were sent but may not show in its status yet.
    public private(set) var notificationRequests: [UUID: NotificationRequest] = [:]
    /// A server whose edit form the server list should open ("Edit server…" on the Unreachable screen).
    /// The server list clears it once the form is open.
    public var editRequest: UUID?

    /// What an opened "Add to Polly" link asks for; the settings (macOS) or the Sources tab (iOS) shows it and clears it.
    public enum LinkRequest: Equatable, Sendable {
        /// Open the add form, filled in from the link.
        case add(AddSourceLink)
        /// The link is for a source the user already has.
        case existing(UUID)
        /// The link can't be used; the message says why.
        case invalid(String)
    }

    public var linkRequest: LinkRequest?

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
    /// Where the source list is shared with the user's other devices; nil until the app connects it.
    @ObservationIgnored private var cloud: CloudKeyValueStore?
    @ObservationIgnored private var cloudKey = SourceSync.defaultKey
    /// Applying a merge reloads, which must not start another sync.
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var cloudObserver: NSObjectProtocol?

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

    // MARK: - Links

    /// Handles an "Add to Polly" link. Never adds anything itself: it asks for the add form, or points at the
    /// source the user already has (same type, URL and username).
    public func open(_ url: URL) {
        do {
            let link = try AddSourceLink.parse(url)
            let address = ServerURLParser.parse(link.url, keepPath: !link.kind.urlIsMonitoringSystem)?.baseURL
            let username = link.headerName == nil ? (link.username ?? "") : ""
            if let existing = servers.first(where: {
                $0.kind == link.kind && $0.baseURL == address && $0.username == username
            }) {
                linkRequest = .existing(existing.id)
            } else {
                linkRequest = .add(link)
            }
        } catch {
            linkRequest = .invalid(error.localizedDescription)
        }
    }

    // MARK: - Server management

    public func reload() {
        servers = store.allServers()
        passwordStorage = store.passwordStorage
        showDockIcon = store.showDockIcon
        debugLog = store.debugLog
        hideServicesOnDownHosts = store.hideServicesOnDownHosts
        syncWithICloud = store.syncWithICloud
        // Drop status of removed, disabled and paused servers so they don't count towards the overall state.
        // A paused server keeps the time of its last answer, which its detail still shows.
        let active = Set(servers.filter(\.isActive).map(\.id))
        let shown = Set(servers.filter(\.enabled).map(\.id))
        states = states.filter { active.contains($0.key) }
        baselines = baselines.filter { active.contains($0.key) }
        lastAttempts = lastAttempts.filter { shown.contains($0.key) }
        lastSuccesses = lastSuccesses.filter { shown.contains($0.key) }
        notificationRequests = notificationRequests.filter { active.contains($0.key) }
        // Every change to the sources goes through here; share it.
        syncWithCloud()
    }

    // MARK: - iCloud

    /// Shares the source list through `cloud` under `key`, and merges what is there now.
    public func connectCloud(_ cloud: CloudKeyValueStore, key: String = SourceSync.defaultKey) {
        self.cloud = cloud
        cloudKey = key
        syncWithCloud()
    }

    /// Another device changed the list in iCloud.
    public func cloudDidChange() {
        syncWithCloud()
    }

    public func setSyncWithICloud(_ sync: Bool) throws {
        defer { reload() }
        try store.setSyncWithICloud(sync)
        // Turning it on again later joins like a new device, matching sources by type, URL and username.
        if !sync { try store.setSyncBase(nil) }
        syncError = nil
    }

    private func syncWithCloud() {
        guard let cloud, store.syncWithICloud, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let remote = try cloud.string(forKey: cloudKey).map(SyncedSource.parse)
            let before = servers
            let merge = SourceSync.merge(local: before, base: store.syncBase(), remote: remote)
            if merge.servers != before {
                try store.applySync(merge)
                reload()
                checkChangedSources(before: before, merge: merge)
            }
            if let upload = merge.upload {
                cloud.set(SyncedSource.render(upload), forKey: cloudKey)
            }
            try store.setSyncBase(merge.base)
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Sources that arrived from iCloud, or that point at another system now, are checked from scratch.
    private func checkChangedSources(before: [NagiosServer], merge: SourceSync.Merge) {
        let oldByID = Dictionary(before.map { (merge.renamed[$0.id] ?? $0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for server in servers {
            let old = oldByID[server.id]
            guard old?.baseURL != server.baseURL || old?.kind != server.kind || merge.renamed.values.contains(server.id)
            else { continue }
            states[server.id] = nil
            baselines[server.id] = nil
            lastAttempts[server.id] = nil
            lastSuccesses[server.id] = nil
            notificationRequests[server.id] = nil
            lastRefresh[server.id, default: 0] += 1
            if server.isActive {
                Task { await refresh(server) }
            }
        }
    }

    #if canImport(Darwin)
    /// Shares the source list through iCloud key-value storage and follows changes from other devices.
    public func connectICloud(key: String = SourceSync.defaultKey) {
        let store = NSUbiquitousKeyValueStore.default
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cloudDidChange() }
        }
        store.synchronize()
        connectCloud(store, key: key)
    }
    #endif

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

    public func summary(for sourceID: UUID) -> MonitorSummary {
        MonitorSummary(servers: servers.filter { $0.id == sourceID }, states: states,
                       hideServicesOnDownHosts: hideServicesOnDownHosts)
    }

    public func setNotifications(_ enabled: Bool, for server: NagiosServer) throws {
        defer { reload() }
        try store.setNotifications(enabled, for: server.id)
    }

    /// What the source detail shows for a server.
    public func sourceDetail(for server: NagiosServer, now: Date = .now) -> SourceDetail {
        SourceDetail(server: servers.first { $0.id == server.id } ?? server, state: states[server.id],
                     lastSuccess: lastSuccesses[server.id], lastAttempt: lastAttempts[server.id],
                     notificationRequest: notificationRequests[server.id], now: now)
    }

    /// Turns the notifications of the monitoring system itself on or off, for all its contacts. Sent once; the
    /// source detail shows the change as pending until the server reports it.
    public func setMonitorNotifications(_ enabled: Bool, for server: NagiosServer) async throws {
        try await backend(for: server).setNotificationsEnabled(enabled)
        notificationRequests[server.id] = NotificationRequest(enabled: enabled, at: .now)
        await refresh(server)
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
            notificationRequests[server.id] = nil
        }
        reload()
        if let updated = activeServer(server.id) {
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

    /// The servers the overview lists: all but the disabled ones.
    public var enabledServers: [NagiosServer] { servers.filter(\.enabled) }

    /// Pauses a server from now, or resumes it and checks it right away. Saved, so it survives a restart.
    public func setPaused(_ paused: Bool, for server: NagiosServer) throws {
        try store.setPaused(since: paused ? .now : nil, for: server.id)
        reload()
        if !paused, let updated = activeServer(server.id) {
            Task { await refresh(updated) }
        }
    }

    /// Turns a server on or off in the settings; off leaves it out everywhere else.
    public func setEnabled(_ enabled: Bool, for server: NagiosServer) throws {
        try store.setEnabled(enabled, for: server.id)
        reload()
        if enabled, let updated = activeServer(server.id) {
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
            for server in servers where server.isActive {
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
        guard activeServer(server.id) != nil else { return }
        if states[server.id] == nil { states[server.id] = .loading }
        let number = (lastRefresh[server.id] ?? 0) + 1
        lastRefresh[server.id] = number
        let result: ServerState
        do {
            result = .ok(try await backend(for: server).fetchStatus())
        } catch {
            result = .failed(error.localizedDescription)
        }
        // The server may have been paused, disabled or deleted while the request was in flight, or a refresh
        // that started later has taken over: its answer is the newer one, whichever arrives first.
        guard !Task.isCancelled, let current = activeServer(server.id), lastRefresh[server.id] == number else { return }
        states[server.id] = result
        lastAttempts[server.id] = .now
        guard case .ok(let status) = result else { return }
        lastSuccesses[server.id] = status.fetchedAt
        if let request = notificationRequests[server.id], request.enabled == status.notificationsEnabled {
            notificationRequests[server.id] = nil
        }
        let changes = NotificationPolicy.changes(previous: baselines[server.id], current: status.problems,
                                                  hideServicesOnDownHosts: hideServicesOnDownHosts)
        baselines[server.id] = status.problems
        if current.notifications, !changes.isEmpty { onProblemChanges?(current, changes) }
    }

    private func activeServer(_ id: UUID) -> NagiosServer? {
        servers.first { $0.id == id && $0.isActive }
    }
}
