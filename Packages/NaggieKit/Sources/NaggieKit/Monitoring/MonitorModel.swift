import Foundation
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
    public var pollInterval: Duration = .seconds(60)

    @ObservationIgnored public let store: ServerStore
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    public init(store: ServerStore) {
        self.store = store
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
        // Drop status of removed and disabled servers so they don't count towards the overall state.
        let active = Set(servers.filter(\.enabled).map(\.id))
        states = states.filter { active.contains($0.key) }
    }

    public func setShowDockIcon(_ show: Bool) throws {
        defer { reload() }
        try store.setShowDockIcon(show)
    }

    public func add(_ server: NagiosServer, password: String?) throws {
        try store.add(server, password: password)
        reload()
        Task { await refresh(server) }
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

    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAll()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers where server.enabled {
                group.addTask { await self.refresh(server) }
            }
        }
    }

    public func refresh(_ server: NagiosServer) async {
        guard isEnabled(server.id) else { return }
        if states[server.id] == nil { states[server.id] = .loading }
        let result: ServerState
        do {
            let password = try store.password(for: server.id)
            result = .ok(try await NagiosClient(server: server, password: password).fetchStatus())
        } catch {
            result = .failed(error.localizedDescription)
        }
        // The server may have been disabled or deleted while the request was in flight.
        if isEnabled(server.id) { states[server.id] = result }
    }

    private func isEnabled(_ id: UUID) -> Bool {
        servers.contains { $0.id == id && $0.enabled }
    }
}
