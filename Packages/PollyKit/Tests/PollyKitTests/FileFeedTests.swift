import Foundation
import Testing
@testable import PollyKit

/// A feed read from a JSON file on the Mac instead of a server. A file that stops changing is stale, so a script
/// that died doesn't leave Polly saying all is well.
struct FileFeedTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let feed = #"{"polly":1,"okCount":3,"items":[{"id":"1","group":"acme","title":"Crash","severity":"critical"}]}"#
    private let fileURL = URL(fileURLWithPath: "/Users/someone/feeds/tickets.json")

    private func client(modified: Date, staleAfter: TimeInterval? = nil, data: Data? = nil) -> FeedClient {
        var server = NagiosServer(name: "Tickets", baseURL: fileURL, username: "", kind: .feed)
        server.staleAfter = staleAfter
        var client = FeedClient(server: server, password: nil)
        let body = data ?? Data(feed.utf8)
        client.readFile = { _, _ in (body, modified) }
        client.now = { [now] in now }
        return client
    }

    @Test func readsAFreshFile() async throws {
        let status = try await client(modified: now - 180).fetchStatus()
        #expect(status.problems.map(\.title) == ["Crash"])
        #expect(status.updatedAt == now - 180)
        #expect(status.fetchedAt == now)
    }

    @Test func aFileThatStopsChangingIsStale() async {
        await #expect(throws: FeedError.stale(age: 16 * 60, limit: 15 * 60)) {
            try await client(modified: now - 16 * 60).fetchStatus()
        }
        #expect(FeedError.stale(age: 16 * 60, limit: 15 * 60).localizedDescription
            == "The file hasn't changed for 16 min (the limit is 15 min). Is whatever writes it still running?")
        // The limit can be set per source.
        await #expect(throws: Never.self) { try await client(modified: now - 16 * 60, staleAfter: 3600).fetchStatus() }
    }

    @Test func formatErrorsAreReportedAsForAnyFeed() async {
        await #expect(throws: FeedError.notJSON) { try await client(modified: now, data: Data("nope".utf8)).fetchStatus() }
    }

    @Test func theSourceLineSaysWhenTheFileChanged() async throws {
        let status = try await client(modified: now - 180).fetchStatus()
        let server = NagiosServer(name: "Tickets", baseURL: fileURL, username: "", kind: .feed)
        #expect(ServerLine(server: server, state: .ok(status), now: now).text == "4 items, 1 crit · updated 3 min ago")
    }

    @Test func urlParserAcceptsFilesForFeedsOnly() {
        #expect(ServerURLParser.parse("file:///Users/someone/feeds/tickets.json", keepPath: true, allowFile: true)?.baseURL
            == fileURL)
        #expect(ServerURLParser.parse("file:///Users/someone/feeds/tickets.json", keepPath: true) == nil)
    }

    @Test func roundTripsInTheSettingsFile() throws {
        var server = NagiosServer(name: "Tickets", baseURL: fileURL, username: "", kind: .feed)
        server.fileBookmark = Data([1, 2, 3, 250])
        server.staleAfter = 3600
        let settings = PollySettings(servers: [.init(server: server)])
        let yaml = SettingsFile.render(settings)
        #expect(yaml.contains("    url: file:///Users/someone/feeds/tickets.json\n"))
        #expect(yaml.contains("    bookmark: AQID+g==\n"))
        #expect(yaml.contains("    staleAfterMinutes: 60\n"))
        #expect(try SettingsFile.parse(yaml) == settings)
        // The default limit isn't written.
        server.staleAfter = nil
        #expect(!SettingsFile.render(PollySettings(servers: [.init(server: server)])).contains("staleAfter"))
    }

    @MainActor @Test func formTakesAChosenFileWithItsPermission() {
        let form = ServerFormModel(kind: .feed)
        form.chooseFile(fileURL, bookmark: Data([7]))
        form.staleAfterMinutes = 30
        #expect(form.isFile)
        let server = form.makeServer()
        #expect(server?.baseURL == fileURL)
        #expect(server?.fileBookmark == Data([7]))
        #expect(server?.staleAfter == 1800)
        #expect(server?.name == "tickets.json")
        // Typing another path drops the permission, which only covers the chosen file.
        form.urlFieldText = "file:///Users/someone/other.json"
        #expect(form.makeServer()?.fileBookmark == nil)
        // A file is no option for the other types.
        form.kind = .url
        #expect(!form.isFile)
        #expect(form.makeServer() == nil)
    }

    @MainActor @Test func editingKeepsTheFileAndThePause() {
        var server = NagiosServer(name: "Tickets", baseURL: fileURL, username: "", kind: .feed)
        server.fileBookmark = Data([9])
        server.pausedSince = now
        let form = ServerFormModel(editing: server, password: nil)
        #expect(form.isFile)
        #expect(form.staleAfterMinutes == 15)
        #expect(form.makeServer()?.fileBookmark == Data([9]))
        #expect(form.makeServer()?.pausedSince == now)
    }
}
