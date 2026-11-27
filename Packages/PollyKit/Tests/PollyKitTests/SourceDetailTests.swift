import Foundation
import Testing
@testable import PollyKit

/// What the source detail in the macOS panel shows about one source.
struct SourceDetailTests {
    let server = NagiosServer(name: "monitor", baseURL: URL(string: "https://monitor.example.com")!, username: "")
    let now = Date(timeIntervalSince1970: 10_000)

    private func ok(notifications: Bool? = true, fetchedAt: Date) -> MonitorModel.ServerState {
        .ok(ServerStatus(hosts: HostCounts(up: 1), services: ServiceCounts(ok: 1), problems: [], fetchedAt: fetchedAt,
                         notificationsEnabled: notifications))
    }

    private func detail(_ state: MonitorModel.ServerState?, server: NagiosServer? = nil, lastSuccess: Date? = nil,
                        lastAttempt: Date? = nil, request: NotificationRequest? = nil) -> SourceDetail {
        SourceDetail(server: server ?? self.server, state: state, lastSuccess: lastSuccess, lastAttempt: lastAttempt,
                     notificationRequest: request, now: now)
    }

    /// Shown under "Last refresh".
    @Test func saysWhenTheSourceLastAnswered() {
        let answered = now - 14
        #expect(detail(ok(fetchedAt: answered), lastSuccess: answered, lastAttempt: answered).lastRefresh == "14 s ago")
        #expect(detail(nil).lastRefresh == "Not yet")
        #expect(detail(.loading).lastRefresh == "Not yet")
        #expect(detail(.failed("timeout"), lastAttempt: now - 60).lastRefresh == "Failed 1 min ago")
        #expect(detail(.failed("timeout"), lastSuccess: now - 600, lastAttempt: now - 60).lastRefresh
            == "Failed 1 min ago · last answer 10 min ago")
        var disabled = server
        disabled.enabled = false
        #expect(detail(nil, server: disabled).lastRefresh == "Disabled")
    }

    /// A paused source keeps saying when Polly last heard from it, and has no notification switch to show.
    @Test func aPausedSourceShowsItsLastAnswer() {
        var paused = server
        paused.pausedSince = now - 60
        let last = detail(ok(fetchedAt: now - 1080), server: paused, lastSuccess: now - 1080, lastAttempt: now - 1080)
        #expect(last.lastRefresh == "18 min ago")
        #expect(last.paused)
        #expect(last.notifications == nil)
        #expect(detail(nil, server: paused).lastRefresh == "Not yet")
        #expect(!detail(nil).paused)
    }

    @Test func notificationSwitchFollowsTheMonitor() {
        #expect(detail(ok(fetchedAt: now)).notifications == .on)
        #expect(detail(ok(notifications: false, fetchedAt: now)).notifications == .off)
        // Not reported, not reachable or not checked yet: there is nothing to switch.
        #expect(detail(ok(notifications: nil, fetchedAt: now)).notifications == nil)
        #expect(detail(.failed("timeout")).notifications == nil)
        #expect(detail(nil).notifications == nil)
    }

    /// Nagios applies a command after `status_update_interval`, so a just-sent change is shown as pending.
    @Test func aRequestIsPendingUntilTheMonitorAgreesOrItGetsOld() {
        let request = NotificationRequest(enabled: false, at: now - 20)
        #expect(detail(ok(fetchedAt: now), request: request).notifications == .switching(to: false))
        #expect(detail(ok(notifications: false, fetchedAt: now), request: request).notifications == .off)
        let old = NotificationRequest(enabled: false, at: now - SourceDetail.switchingTimeout - 1)
        #expect(detail(ok(fetchedAt: now), request: old).notifications == .on)
        #expect(SourceDetail.Notifications.switching(to: false).isOn == false)
        #expect(SourceDetail.Notifications.on.isOn)
    }
}
