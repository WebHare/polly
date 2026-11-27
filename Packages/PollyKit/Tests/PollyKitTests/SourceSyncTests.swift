import Foundation
import Testing
@testable import PollyKit

/// Merging this device's sources with the list in iCloud. Only the sources themselves are shared; pause and the
/// notification bell stay on each device.
struct SourceSyncTests {
    let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    private func server(_ id: UUID, _ name: String, url: String? = nil, username: String = "admin") -> NagiosServer {
        NagiosServer(id: id, name: name, baseURL: URL(string: url ?? "https://\(host(name)).example.com")!,
                     username: username)
    }

    /// The host for a name: its first word, so renaming a source doesn't move it.
    private func host(_ name: String) -> String {
        String(name.split(separator: " ")[0].lowercased().filter(\.isLetter))
    }

    private func synced(_ servers: NagiosServer...) -> [SyncedSource] { servers.map(SyncedSource.init) }

    @Test func roundTripsTheSharedList() throws {
        var disabled = server(b, "Staging: \"old\"", url: "https://staging.example.com:8443/nagios")
        disabled.enabled = false
        disabled.kind = .url
        let list = synced(server(a, "Production"), disabled)
        let yaml = SyncedSource.render(list)
        #expect(yaml.hasPrefix("version: 1\n"))
        #expect(try SyncedSource.parse(yaml) == list)
        #expect(try SyncedSource.parse(SyncedSource.render([])) == [])
    }

    /// Pause, the bell and passwords are this device's business.
    @Test func leavesDeviceSettingsOut() {
        var paused = server(a, "Production")
        paused.pausedSince = Date(timeIntervalSince1970: 0)
        paused.notifications = true
        let yaml = SyncedSource.render(synced(paused))
        #expect(!yaml.contains("paused"))
        #expect(!yaml.contains("notifications"))
        #expect(!yaml.contains("password"))
    }

    @Test func rejectsAnUnknownVersion() {
        #expect(throws: SettingsFileError.self) { try SyncedSource.parse("version: 2\nsources: []\n") }
    }

    @Test func firstDeviceUploadsItsList() {
        let local = [server(a, "Production")]
        let merge = SourceSync.merge(local: local, base: nil, remote: nil)
        #expect(merge.servers == local)
        #expect(merge.upload == synced(local[0]))
        #expect(merge.renamed.isEmpty)
    }

    /// A device that joins adopts the IDs from iCloud for sources it already has, so they aren't doubled.
    @Test func joiningDeviceMatchesSourcesByTypeURLAndUsername() {
        let remote = synced(server(a, "Production"), server(c, "Web"))
        var mine = server(b, "Prod (phone)", url: "https://production.example.com")
        mine.notifications = true
        mine.pausedSince = Date(timeIntervalSince1970: 5)
        let other = server(UUID(), "Lab")
        let merge = SourceSync.merge(local: [mine, other], base: nil, remote: remote)
        #expect(merge.renamed == [b: a])
        #expect(merge.servers.map(\.id) == [a, c, other.id])
        #expect(merge.servers[0].name == "Production")
        #expect(merge.servers[0].notifications)
        #expect(merge.servers[0].pausedSince == Date(timeIntervalSince1970: 5))
        #expect(!merge.servers[1].notifications)
        #expect(merge.upload == remote + synced(other))
    }

    @Test func nothingToDoWhenInStep() {
        let local = [server(a, "Production")]
        let merge = SourceSync.merge(local: local, base: synced(local[0]), remote: synced(local[0]))
        #expect(merge.servers == local)
        #expect(merge.upload == nil)
    }

    @Test func changesOnEitherSideAreKept() {
        let base = synced(server(a, "Production"), server(b, "Staging"))
        let local = [server(a, "Production (renamed here)"), server(b, "Staging")]
        let remote = synced(server(a, "Production"), server(b, "Staging (renamed there)"))
        let merge = SourceSync.merge(local: local, base: base, remote: remote)
        #expect(merge.servers.map(\.name) == ["Production (renamed here)", "Staging (renamed there)"])
        #expect(merge.upload == synced(merge.servers[0], merge.servers[1]))
    }

    /// When both sides changed the same source, iCloud wins: it holds the change made last.
    @Test func iCloudWinsWhenBothChangedTheSameSource() {
        let base = synced(server(a, "Production"))
        let merge = SourceSync.merge(local: [server(a, "Here")], base: base, remote: synced(server(a, "There")))
        #expect(merge.servers.map(\.name) == ["There"])
        #expect(merge.upload == nil)
    }

    @Test func additionsOnBothSidesAreKept() {
        let base = synced(server(a, "Production"))
        let merge = SourceSync.merge(local: [server(a, "Production"), server(b, "Here")], base: base,
                                     remote: synced(server(a, "Production"), server(c, "There")))
        #expect(merge.servers.map(\.id) == [a, c, b])
        #expect(merge.upload == synced(server(a, "Production"), server(c, "There"), server(b, "Here")))
    }

    @Test func deletionsOnBothSidesAreKept() {
        let base = synced(server(a, "Production"), server(b, "Staging"), server(c, "Web"))
        let merge = SourceSync.merge(local: [server(a, "Production"), server(c, "Web")], base: base,
                                     remote: synced(server(a, "Production"), server(b, "Staging")))
        #expect(merge.servers.map(\.id) == [a])
        #expect(merge.deleted == [c])
        #expect(merge.upload == synced(server(a, "Production")))
    }

    /// A source that one side deleted and the other changed is kept: losing a change is worse than a source to
    /// delete again.
    @Test func aChangedSourceSurvivesADeletion() {
        let base = synced(server(a, "Production"), server(b, "Staging"))
        let merge = SourceSync.merge(local: [server(a, "Production (edited)")], base: base,
                                     remote: synced(server(b, "Staging (edited)")))
        #expect(merge.servers.map(\.name) == ["Staging (edited)", "Production (edited)"])
    }

    @Test func disablingIsShared() {
        var disabled = server(a, "Production")
        disabled.enabled = false
        let base = synced(server(a, "Production"))
        let merge = SourceSync.merge(local: [server(a, "Production")], base: base, remote: synced(disabled))
        #expect(merge.servers.map(\.enabled) == [false])
    }

    @Test func reorderingHereIsSharedUnlessICloudReorderedToo() {
        let base = synced(server(a, "A"), server(b, "B"))
        let reordered = SourceSync.merge(local: [server(b, "B"), server(a, "A")], base: base, remote: base)
        #expect(reordered.servers.map(\.id) == [b, a])
        #expect(reordered.upload == synced(server(b, "B"), server(a, "A")))
        let remoteOrder = SourceSync.merge(local: [server(a, "A"), server(b, "B")], base: base,
                                           remote: synced(server(b, "B"), server(a, "A")))
        #expect(remoteOrder.servers.map(\.id) == [b, a])
    }

    /// A changed URL or type is a different system, which the model checks again from scratch.
    @Test func reportsSourcesThatPointElsewhere() {
        let base = synced(server(a, "Production"))
        let merge = SourceSync.merge(local: [server(a, "Production")], base: base,
                                     remote: synced(server(a, "Production", url: "https://new.example.com")))
        #expect(merge.servers[0].baseURL.absoluteString == "https://new.example.com")
    }
}

/// The explanation under the "Sync sources with iCloud" switch.
struct SyncSettingTextTests {
    @Test func saysWhatIsSharedAndWhatIsNot() {
        #expect(SourceSync.settingText(on: true, passwordStorage: .keychain, error: nil)
            == "Sources and their passwords are shared with your other devices through iCloud. Pausing a source and its notifications stay on each device.")
        #expect(SourceSync.settingText(on: true, passwordStorage: .file, error: nil)
            == "Sources are shared with your other devices through iCloud, but passwords in polly.yaml are not: enter them on each device. Pausing a source and its notifications stay on each device.")
        #expect(SourceSync.settingText(on: false, passwordStorage: .keychain, error: nil)
            == "Sources stay on this device.")
        #expect(SourceSync.settingText(on: true, passwordStorage: .keychain, error: "No network.").hasSuffix(" Last sync failed: No network."))
    }
}
