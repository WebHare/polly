import Foundation
import Testing
@testable import PollyKit

/// Answers every request of a `URLSession` from a closure, so the client is tested without a network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status = 200
        var body = ""
        var redirectTo: URL?
        /// Seconds to wait before answering, to let a later request overtake this one.
        var delay: TimeInterval = 0
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Response)?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// URLSession hands a request body to URLProtocol as a stream.
    static func body(of request: URLRequest) -> String {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let stub = Self.handler!(request)
        if let target = stub.redirectTo {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": target.absoluteString])!
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // A refused redirect makes URLSession wait for the 302 itself as the final response.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        let deliver: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: deliver)
        } else {
            deliver()
        }
    }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func statusJSON(for request: URLRequest, problems: String = "{}", hostsUp: Int = 1) -> StubProtocol.Response {
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
    let data = switch query {
    case "hostcount": #"{"count":{"up":\#(hostsUp),"down":0,"unreachable":0,"pending":0}}"#
    case "servicecount": #"{"count":{"ok":\#(hostsUp),"warning":0,"critical":0,"unknown":0,"pending":0}}"#
    default: #"{"servicelist":\#(problems)}"#
    }
    return .init(body: #"{"result":{"type_code":0},"data":\#(data)}"#)
}

/// The stub handler is shared state, so everything that uses it runs one test at a time.
@Suite(.serialized)
struct TransportTests {
    private let server = NagiosServer(name: "Prod", baseURL: URL(string: "https://nagios.test")!, username: "alice",
                                      notifications: true)
    private let target = ServiceProblem(host: "web1", service: "HTTP", severity: .critical)
    private var client: NagiosClient { NagiosClient(server: server, password: "s3cret", session: StubProtocol.session()) }

    private let form = "<input name='cmd_typ' value='34'><input name='cmd_mod' value='2'><input name='host' value='web1'>"
        + "<input name='service' value='HTTP'><input name='com_author' value='Alice Admin'><input name='nagFormId' value='test-token'"

    @Test func preparingOnlyReadsAndSubmittingPostsOnce() async throws {
        let requests = Box<[URLRequest]>([])
        let bodies = Box<[String]>([])
        let form = form
        StubProtocol.handler = { request in
            requests.value.append(request)
            guard request.httpMethod == "POST" else { return .init(body: form) }
            bodies.value.append(StubProtocol.body(of: request))
            return .init(body: "<div class='infoMessage'>Your command request was successfully submitted to Nagios for processing.</div>")
        }
        defer { StubProtocol.handler = nil }

        let command = try await client.prepareCommand(.acknowledge, for: target)
        #expect(requests.value.map(\.httpMethod) == ["GET"])
        #expect(requests.value[0].url?.absoluteString == "https://nagios.test/nagios/cgi-bin/cmd.cgi?cmd_typ=34&host=web1&service=HTTP")
        #expect(command.defaults.author == "Alice Admin")

        try await command.submit(CommandInput(author: "Alice Admin", comment: "Investigating"))
        #expect(requests.value.map(\.httpMethod) == ["GET", "POST"])
        let post = requests.value[1]
        // The query only selects the form; the command itself is the POST body.
        #expect(post.url?.absoluteString == "https://nagios.test/nagios/cgi-bin/cmd.cgi")
        #expect(post.value(forHTTPHeaderField: "Authorization") == "Basic YWxpY2U6czNjcmV0")
        #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(bodies.value == ["cmd_mod=2&cmd_typ=34&com_author=Alice%20Admin&com_data=Investigating&host=web1"
            + "&nagFormId=test-token&service=HTTP&sticky_ack=on"])
    }

    @Test func unexpectedFormCannotProduceACommand() async {
        StubProtocol.handler = { _ in .init(body: "<div class='errorMessage'>Not authorized</div>") }
        defer { StubProtocol.handler = nil }
        await #expect(throws: BackendError.self) { try await client.prepareCommand(.downtime, for: target) }
    }

    @Test func unconfirmedSubmissionIsAnError() async throws {
        let form = form
        StubProtocol.handler = { request in
            request.httpMethod == "POST" ? .init(body: "<p>Error: Invalid or missing CSRF cookie!</p>") : .init(body: form)
        }
        defer { StubProtocol.handler = nil }
        let command = try await client.prepareCommand(.acknowledge, for: target)
        await #expect(throws: BackendError.self) { try await command.submit(CommandInput(author: "a", comment: "c")) }
    }

    /// Nagios shows an account without permissions an empty installation, which must not look healthy.
    @Test func noHostsAndServicesIsNotHealthy() async {
        StubProtocol.handler = { statusJSON(for: $0, hostsUp: 0) }
        defer { StubProtocol.handler = nil }
        await #expect(throws: NagiosClientError.empty) { try await client.fetchStatus() }
    }

    /// Regression test for a startup crash with `async let` in `fetchStatus()`: a refused server next to busy ones
    /// crashed the process ("freed pointer was not the last allocation", or a jump into freed memory). It is timing
    /// dependent, so it catches a regression most of the time, not always. Needs nothing listening on 127.0.0.1:9.
    @Test func refusedServerNextToBusyOnesDoesNotCrash() async {
        StubProtocol.handler = { request in
            var response = statusJSON(for: request)
            response.delay = 0.002
            return response
        }
        let busy = client
        let refused = NagiosClient(endpoint: URL(string: "http://127.0.0.1:9/nagios/cgi-bin/statusjson.cgi")!,
                                   username: "alice", password: "s3cret")
        for _ in 0..<20 {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<64 {
                    group.addTask { _ = try? await busy.fetchStatus() }
                    group.addTask { _ = try? await refused.fetchStatus() }
                }
            }
        }
        await #expect(throws: NagiosClientError.self) { try await refused.fetchStatus() }
    }

    /// Following a redirect would send the Basic credentials to wherever it points.
    @Test func redirectsAreRefused() async {
        let requests = Box<[URL]>([])
        StubProtocol.handler = { request in
            requests.value.append(request.url!)
            return request.url?.host() == "nagios.test" ? .init(redirectTo: URL(string: "https://elsewhere.test/login")!)
                : statusJSON(for: request)
        }
        defer { StubProtocol.handler = nil }
        await #expect(throws: NagiosClientError.redirect) { try await client.testConnection() }
        #expect(!requests.value.contains { $0.host() == "elsewhere.test" })
    }

    @Test func wireLogRecordsTrafficWithoutCredentials() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "polly-wire-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        StubProtocol.handler = { statusJSON(for: $0, problems: #"{"web1":{"HTTP":{"status":16,"plugin_output":"down"}}}"#) }
        defer { StubProtocol.handler = nil }

        var client = client
        client.wireLog = WireLog(fileURL: file)
        _ = try await client.fetchStatus()

        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 3)
        for line in lines {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
        }
        #expect(text.contains("query=servicelist"))
        #expect(text.contains("plugin_output"))
        #expect(text.contains("Basic <redacted>"))
        #expect(!text.contains("YWxpY2U6czNjcmV0"))
        #expect(!text.contains("s3cret"))
    }

    @Test func wireLogRotatesInsteadOfGrowingForever() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "polly-wire-\(UUID().uuidString).log")
        let rotated = file.appendingPathExtension("1")
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: rotated) }
        let log = WireLog(fileURL: file, maxBytes: 300)
        let request = URLRequest(url: URL(string: "https://nagios.test/a")!)
        for _ in 0..<4 { log.record(request: request, status: 200, body: Data(repeating: 0x61, count: 200), error: nil) }
        #expect(FileManager.default.fileExists(atPath: rotated.path(percentEncoded: false)))
        #expect(try Data(contentsOf: file).count < 600)
    }

    /// A slow poll that started before a recovery must not bring the problem back when it finally answers.
    @MainActor @Test func staleResponseDoesNotOverwriteANewerOne() async throws {
        let critical = Box(true)
        let delay = Box(0.0)
        StubProtocol.handler = { request in
            var response = statusJSON(for: request, problems: critical.value ? #"{"web1":{"HTTP":{"status":16}}}"# : "{}")
            response.delay = delay.value
            return response
        }
        defer { StubProtocol.handler = nil }

        let store = try ServerStore(fileURL: nil, credentials: InMemoryCredentialStore())
        try store.add(server, password: "s3cret")
        let model = MonitorModel(store: store, session: StubProtocol.session())
        var received: [ProblemChanges] = []
        model.onProblemChanges = { _, changes in received.append(changes) }
        await model.refreshAll()

        delay.value = 0.5
        async let slow: Void = model.refresh(server)
        try await Task.sleep(for: .milliseconds(150))
        critical.value = false
        delay.value = 0
        await model.refresh(server)
        await slow

        #expect(received.map { $0.recovered.map(\.id) } == [["web1/HTTP"]])
        #expect(received.allSatisfy { $0.raised.isEmpty })
        guard case .ok(let status) = model.states[server.id] else {
            Issue.record("expected a status")
            return
        }
        #expect(status.problems.isEmpty)
    }

    @MainActor @Test func stoppingAnInFlightPollKeepsTheScheduleCleared() async throws {
        let started = Box(false)
        StubProtocol.handler = { request in
            started.value = true
            return statusJSON(for: request)
        }
        defer { StubProtocol.handler = nil }
        let store = try ServerStore(fileURL: nil, credentials: InMemoryCredentialStore())
        try store.add(server, password: "s3cret")
        let model = MonitorModel(store: store, session: StubProtocol.session())
        defer { model.stopPolling() }

        await model.refreshAll()
        let previous = model.states[server.id]
        started.value = false
        model.startPolling()
        let deadline = ContinuousClock.now + .seconds(2)
        while !started.value, ContinuousClock.now < deadline { await Task.yield() }
        try #require(started.value)
        print("Stopping poll: request started, nextPollAt = \(String(describing: model.nextPollAt))")
        model.stopPolling()
        try await Task.sleep(for: .milliseconds(100))
        print("After cancellation: nextPollAt = \(String(describing: model.nextPollAt))")
        #expect(model.nextPollAt == nil)
        #expect(model.states[server.id] == previous)
    }

    @MainActor @Test func foregroundPollingRefreshesImmediatelyAndPreservesTheBaseline() async throws {
        let critical = Box(true)
        let requests = Box(0)
        StubProtocol.handler = { request in
            requests.value += 1
            return statusJSON(for: request, problems: critical.value ? #"{"web1":{"HTTP":{"status":16}}}"# : "{}")
        }
        defer { StubProtocol.handler = nil }
        let store = try ServerStore(fileURL: nil, credentials: InMemoryCredentialStore())
        try store.add(server, password: "s3cret")
        let model = MonitorModel(store: store, session: StubProtocol.session())
        defer { model.stopPolling() }
        var received: [ProblemChanges] = []
        model.onProblemChanges = { _, changes in received.append(changes) }

        model.setPollingActive(true)
        let firstDeadline = ContinuousClock.now + .seconds(2)
        while model.nextPollAt == nil, ContinuousClock.now < firstDeadline { await Task.yield() }
        try #require(model.nextPollAt != nil)
        #expect(model.problemCount == 1)
        #expect(received.isEmpty)
        let initialRequests = requests.value

        model.setPollingActive(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests.value == initialRequests)
        model.setPollingActive(false)
        #expect(model.nextPollAt == nil)
        critical.value = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests.value == initialRequests)
        #expect(model.problemCount == 1)

        // Resume well before the normal 60-second interval, with a changed server response.
        model.setPollingActive(true)
        let resumeDeadline = ContinuousClock.now + .seconds(2)
        while model.nextPollAt == nil, ContinuousClock.now < resumeDeadline { await Task.yield() }
        try #require(model.nextPollAt != nil)
        #expect(requests.value == initialRequests * 2)
        #expect(model.problemCount == 0)
        #expect(received.map { $0.recovered.map(\.id) } == [["web1/HTTP"]])
    }

    @MainActor @Test func modelNotifiesAfterTheBaselineAndOnlyWhenEnabled() async throws {
        let critical = Box(true)
        StubProtocol.handler = { request in
            statusJSON(for: request, problems: critical.value ? #"{"web1":{"HTTP":{"status":16}}}"# : "{}")
        }
        defer { StubProtocol.handler = nil }

        let store = try ServerStore(fileURL: nil, credentials: InMemoryCredentialStore())
        try store.add(server, password: "s3cret")
        let model = MonitorModel(store: store, session: StubProtocol.session())
        var received: [ProblemChanges] = []
        model.onProblemChanges = { _, changes in received.append(changes) }

        await model.refreshAll()
        #expect(received.isEmpty)

        critical.value = false
        await model.refreshAll()
        #expect(received.map { $0.recovered.map(\.id) } == [["web1/HTTP"]])

        try model.setNotifications(false, for: server)
        critical.value = true
        await model.refreshAll()
        #expect(received.count == 1)
    }
}
