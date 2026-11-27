import Foundation
import Testing
@testable import PollyKit

/// "Add to Polly" links (`polly-monitor://add?…`) from web pages: they only ever open the add form, filled in.
struct AddSourceLinkTests {
    private func link(_ text: String) throws -> AddSourceLink {
        try AddSourceLink.parse(URL(string: text)!)
    }

    private func problem(_ text: String) -> String? {
        do {
            _ = try link(text)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func readsAFeedLink() throws {
        let feed = try link("polly-monitor://add?type=feed&url=https%3A%2F%2Fsla.example.com%2Fpolly.json%3Flist%3Dmine&name=SLA%20tickets&header=X-API-Key")
        #expect(feed == AddSourceLink(kind: .feed, url: "https://sla.example.com/polly.json?list=mine", name: "SLA tickets",
                                      username: nil, headerName: "X-API-Key"))
    }

    @Test func typeDefaultsToNagiosAndTheRestIsOptional() throws {
        let nagios = try link("polly-monitor://add?url=https://monitor.example.com&username=alice")
        #expect(nagios == AddSourceLink(kind: .nagios, url: "https://monitor.example.com", name: nil, username: "alice",
                                        headerName: nil))
        // Unknown parameters are left alone, for links made for a newer Polly.
        #expect(try link("polly-monitor://add?url=https://example.com&color=red").url == "https://example.com")
    }

    /// Links end up in browser history, server logs and screenshots: no secrets.
    @Test func refusesSecrets() {
        let message = "An \"Add to Polly\" link can't contain a password or token. Enter it in the form instead."
        #expect(problem("polly-monitor://add?url=https://example.com&password=s3cret") == message)
        #expect(problem("polly-monitor://add?url=https://example.com&value=k3y") == message)
        #expect(problem("polly-monitor://add?url=https://example.com&token=k3y") == message)
        #expect(problem("polly-monitor://add?url=https://alice:s3cret@example.com") == message)
    }

    /// A web page must not point Polly at files on this Mac, or at anything but a web address.
    @Test func onlyTakesWebAddresses() {
        let message = "The link's url must be an http or https address."
        #expect(problem("polly-monitor://add?type=feed&url=file:///Users/someone/feed.json") == message)
        #expect(problem("polly-monitor://add?url=javascript:alert(1)") == message)
        #expect(problem("polly-monitor://add?type=feed") == "The link has no url.")
    }

    @Test func refusesWhatItDoesNotKnow() {
        #expect(problem("polly-monitor://add?type=zabbix&url=https://example.com")
            == "The link asks for a source of type \"zabbix\", which this version of Polly doesn't know.")
        #expect(problem("polly-monitor://remove?url=https://example.com")
            == "Polly doesn't know what to do with this link.")
        #expect(problem("polly-monitor://add?url=https://example.com&header=X%20Key")
            == "A header name can't contain spaces, colons or other separators.")
        let long = String(repeating: "a", count: 2100)
        #expect(problem("polly-monitor://add?url=https://example.com/\(long)") == "The link is too long.")
    }

    @MainActor @Test func fillsInTheAddForm() throws {
        let form = ServerFormModel(link: try link("polly-monitor://add?type=feed&url=https://sla.example.com/polly.json&name=SLA&header=X-API-Key"))
        #expect(form.purpose == .add)
        #expect(form.kind == .feed)
        #expect(form.urlText == "https://sla.example.com/polly.json")
        #expect(form.name == "SLA")
        #expect(form.authentication == .header)
        #expect(form.headerName == "X-API-Key")
        #expect(form.password.isEmpty)
        #expect(form.checkState == .idle)
    }

    /// Opening a link never adds anything by itself; a source the user already has is shown instead.
    @MainActor @Test func modelTurnsALinkIntoARequest() throws {
        let store = try ServerStore(fileURL: nil, credentials: InMemoryCredentialStore())
        let existing = NagiosServer(name: "Prod", baseURL: URL(string: "https://monitor.example.com")!, username: "alice")
        try store.add(existing, password: nil)
        let model = MonitorModel(store: store)

        model.open(URL(string: "polly-monitor://add?url=https://monitor.example.com/nagios/&username=alice")!)
        #expect(model.linkRequest == .existing(existing.id))

        model.open(URL(string: "polly-monitor://add?url=https://monitor.example.com&username=bob")!)
        guard case .add(let link) = model.linkRequest else { Issue.record("expected an add request"); return }
        #expect(link.username == "bob")
        #expect(model.servers.count == 1)

        model.open(URL(string: "polly-monitor://add?url=https://example.com&password=x")!)
        guard case .invalid = model.linkRequest else { Issue.record("expected an invalid request"); return }
    }
}
