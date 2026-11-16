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
