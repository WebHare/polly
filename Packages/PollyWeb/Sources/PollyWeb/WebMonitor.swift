import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PollyKit

@MainActor
public final class WebMonitor {
    private let model: MonitorModel
    private let session: URLSession
    private let redactions: [String]
    private var startedAt: Date?
    public private(set) var isRunning = false

    init(configuration: WebConfiguration) throws {
        let transport = URLSessionConfiguration.ephemeral
        transport.timeoutIntervalForRequest = 15
        transport.timeoutIntervalForResource = 20
        session = URLSession(configuration: transport)
        let store = try ServerStore(fileURL: nil, credentials: InMemoryCredentialStore(), initial: configuration.settings)
        model = MonitorModel(store: store, session: session)
        redactions = configuration.redactions
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        startedAt = .now
        model.startPolling()
    }

    public func stop() async {
        isRunning = false
        await model.stopPollingAndWait()
        session.invalidateAndCancel()
    }

    public func snapshot() -> WebSnapshot { model.webSnapshot(redactions: redactions) }

    public func healthy(now: Date = .now) -> Bool {
        guard isRunning, let heartbeat = model.lastPollCompletedAt ?? startedAt else { return false }
        // Failed Nagios polls still complete; only a stalled poll loop fails liveness.
        return now.timeIntervalSince(heartbeat) < 180
    }
}
