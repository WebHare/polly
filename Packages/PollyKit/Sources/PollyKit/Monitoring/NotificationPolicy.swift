import Foundation

public struct ProblemChanges: Equatable, Sendable {
    /// New problems and problems whose severity changed, in current order.
    public var raised: [ServiceProblem]
    /// Problems that are gone since the previous result.
    public var recovered: [ServiceProblem]

    public init(raised: [ServiceProblem] = [], recovered: [ServiceProblem] = []) {
        self.raised = raised
        self.recovered = recovered
    }

    public var isEmpty: Bool { raised.isEmpty && recovered.isEmpty }
}

/// Decides what is worth a notification between two successful status results of one server.
public enum NotificationPolicy {
    /// `previous == nil` means this is the first result (the baseline), which never notifies.
    /// With `hideServicesOnDownHosts`, a host that is down is the news and what happens to its services is not.
    public static func changes(previous: [ServiceProblem]?, current: [ServiceProblem],
                               hideServicesOnDownHosts: Bool = true) -> ProblemChanges {
        guard let previous else { return ProblemChanges() }
        let old = Dictionary(previous.map { ($0.id, $0.severity) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(current.map(\.id))
        let down = hideServicesOnDownHosts ? current.downHosts : []
        let candidates = hideServicesOnDownHosts ? current.hidingServicesOnDownHosts : current
        return ProblemChanges(
            // Someone is already on an acknowledged problem, and a downtime is planned work.
            raised: candidates.filter { !$0.acknowledged && $0.downtimeDepth == 0 && old[$0.id] != $0.severity },
            // A check that recovers during its downtime was planned work too.
            recovered: previous.filter { !currentIDs.contains($0.id) && $0.downtimeDepth == 0 && ($0.isHost || !down.contains($0.host)) }
        )
    }
}
