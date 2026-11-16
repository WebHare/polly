import Foundation
import Testing
@testable import PollyKit

@MainActor
struct ServerFormTests {
    private let custom = NagiosServer(name: "Production", baseURL: URL(string: "https://mon.example.com/ops")!,
                                      username: "alice", enabled: false, kind: .nagios, notifications: true)
    private let hostNamed = NagiosServer(name: "www.example.com", baseURL: URL(string: "https://www.example.com/health")!,
                                         username: "", kind: .url)

    @Test func editFormIsPrefilledAndKeepsTheServerIdentity() throws {
        let model = ServerFormModel(editing: custom, password: "pw")
        #expect(model.isEditing)
        #expect(model.kind == .nagios)
        #expect(model.urlText == "https://mon.example.com/ops")
        #expect(model.name == "Production")
        #expect(model.username == "alice")
        #expect(model.password == "pw")
        #expect(model.checkState == .idle)

        model.name = "Prod"
        let saved = try #require(model.makeServer())
        #expect(saved.id == custom.id)
        #expect(saved.name == "Prod")
        #expect(saved.enabled == false)
        #expect(saved.notifications == true)
    }

    @Test func aNameThatIsJustTheHostIsLeftEmptySoItFollowsTheURL() throws {
        let model = ServerFormModel(editing: hostNamed, password: nil)
        #expect(model.name == "")
        #expect(model.urlText == "https://www.example.com/health")
        model.urlText = "https://shop.example.com/health"
        #expect(try #require(model.makeServer()).name == "shop.example.com")
    }

    @Test func duplicateFormMakesANewServerWithTheSameSettings() throws {
        let model = ServerFormModel(duplicating: custom, password: "pw")
        #expect(!model.isEditing)
        #expect(model.name == "Production copy")
        #expect(model.password == "pw")
        let copy = try #require(model.makeServer())
        #expect(copy.id != custom.id)
        #expect(copy.baseURL == custom.baseURL)
        #expect(copy.username == "alice")
        #expect(copy.kind == .nagios)
        #expect(copy.enabled)
        #expect(copy.notifications)

        #expect(ServerFormModel(duplicating: hostNamed, password: nil).name == "")
    }

    @Test func editingOnlyTestsTheConnectionWhenTheConnectionChanged() {
        let model = ServerFormModel(editing: custom, password: "pw")
        #expect(!model.needsConnectionTest)
        model.name = "Renamed"
        #expect(!model.needsConnectionTest)
        model.password = "other"
        #expect(model.needsConnectionTest)
        model.password = "pw"
        model.urlText = "https://mon2.example.com"
        #expect(model.needsConnectionTest)

        #expect(ServerFormModel().needsConnectionTest)
        #expect(ServerFormModel(duplicating: custom, password: "pw").needsConnectionTest)
    }

    @Test func updateSavesInPlaceAndForgetsTheOldStatusWhenTheURLChanged() throws {
        let store = try ServerStore(fileURL: nil, credentials: InMemoryCredentialStore())
        let other = NagiosServer(name: "Other", baseURL: URL(string: "https://other.example.com")!, username: "")
        try store.add(custom, password: "pw")
        try store.add(other, password: nil)
        let monitor = MonitorModel(store: store, session: StubProtocol.session())

        let form = try monitor.editForm(for: custom)
        #expect(form.password == "pw")
        form.name = "Renamed"
        form.password = "new"
        try monitor.update(try #require(form.makeServer()), password: form.password)
        #expect(monitor.servers.map(\.name) == ["Renamed", "Other"])
        #expect(try store.password(for: custom.id) == "new")

        let duplicate = try monitor.duplicateForm(for: other)
        #expect(duplicate.urlText == "https://other.example.com")
    }
}

@MainActor
struct ServerFormObservationTests {
    /// The form's buttons follow `canSubmit`; pasting a whole URL at once must notify them too.
    @Test(arguments: ["https://nagios.example.com", "https://alice:pw@nagios.example.com/nagios/"])
    func pastingAURLNotifiesObservers(pasted: String) {
        let model = ServerFormModel()
        final class Flag: @unchecked Sendable { var value = false }
        let changed = Flag()
        withObservationTracking { _ = model.canSubmit } onChange: { changed.value = true }
        model.urlText = pasted
        #expect(changed.value)
        #expect(model.canSubmit)
    }
}

@MainActor
struct ServerFormFieldTests {
    /// A text field ignores a value rewritten while it is setting it, so the field binding keeps the pasted
    /// text for this update and strips the credentials on the next turn of the main actor.
    @Test func theURLFieldStripsPastedCredentialsOnTheNextTurn() async throws {
        let model = ServerFormModel()
        model.urlFieldText = "https://alice:pw@nagios.example.com/nagios/"
        #expect(model.urlFieldText == "https://alice:pw@nagios.example.com/nagios/")
        #expect(model.canSubmit)
        for _ in 0..<10 where model.urlText.contains("@") { await Task.yield() }
        #expect(model.urlText == "https://nagios.example.com")
        #expect(model.username == "alice")
        #expect(model.password == "pw")
    }

    @Test func typingOnAfterAPasteWinsOverTheDelayedRewrite() async {
        let model = ServerFormModel()
        model.urlFieldText = "https://alice:pw@nagios.example.com"
        model.urlFieldText = "https://bob@other.example.com"
        for _ in 0..<10 { await Task.yield() }
        #expect(model.urlText == "https://other.example.com")
        #expect(model.username == "bob")
    }
}
