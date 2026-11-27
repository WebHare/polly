import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PollyKit

/// Answers every request of a `URLSession` from a closure, so the client is tested without a network.
final class StubProtocol: URLProtocol {
    struct Response {
        var status = 200
        var body = ""
        var redirectTo: URL?
        /// Seconds to wait before answering, to let a later request overtake this one.
        var delay: TimeInterval = 0
        /// Leave the request pending so cancellation tests cannot race a completed response.
        var waitsForCancellation = false
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
        guard !stub.waitsForCancellation else { return }
        if let target = stub.redirectTo {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": target.absoluteString])!
            // Corelibs traps on URLProtocol redirects; MockIntegrationTests checks real redirects on Linux.
            #if !canImport(FoundationNetworking)
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            #endif
            // A refused redirect makes URLSession wait for the 302 itself as the final response.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        // Linux URLProtocol has an unavailable Sendable conformance; only this callback crosses queues.
        let instance = Box(self)
        let deliver: @Sendable () -> Void = {
            let instance = instance.value
            instance.client?.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
            instance.client?.urlProtocol(instance, didLoad: Data(stub.body.utf8))
            instance.client?.urlProtocolDidFinishLoading(instance)
        }
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: deliver)
        } else {
            deliver()
        }
    }
}

#if canImport(Darwin)
extension StubProtocol: @unchecked Sendable {}
#endif

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

func statusJSON(for request: URLRequest, problems: String = "{}", hostsUp: Int = 1,
                        notifications: Bool? = nil) -> StubProtocol.Response {
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
    let data = switch query {
    case "hostcount": #"{"count":{"up":\#(hostsUp),"down":0,"unreachable":0,"pending":0}}"#
    case "servicecount": #"{"count":{"ok":\#(hostsUp),"warning":0,"critical":0,"unknown":0,"pending":0}}"#
    case "hostlist": #"{"hostlist":{}}"#
    case "programstatus": #"{"programstatus":{"version":"4.5.14"\#(notifications.map { ",\"enable_notifications\":\($0)" } ?? "")}}"#
    default: #"{"servicelist":\#(problems)}"#
    }
    return .init(body: #"{"result":{"type_code":0},"data":\#(data)}"#)
}

/// The stub handler is shared state, so everything that uses it runs one test at a time.
@Suite(.serialized)
struct TransportTests {
    let server = NagiosServer(name: "Prod", baseURL: URL(string: "https://nagios.test")!, username: "alice",
                                      notifications: true)
    private let target = ServiceProblem(host: "web1", service: "HTTP", severity: .critical)
    private var client: NagiosClient { NagiosClient(server: server, password: "s3cret", session: StubProtocol.session()) }

    private let form = "<input name='cmd_typ' value='34'><input name='cmd_mod' value='2'><input name='host' value='web1'>"
        + "<input name='service' value='HTTP'><input name='com_author' value='Alice Admin'><input name='nagFormId' value='test-token'"

    @MainActor @Test func sourceSummaryStaysScopedAsItsStatusChanges() async throws {
        let other = NagiosServer(name: "Other", baseURL: URL(string: "https://other.test")!, username: "")
        let unavailable = Box(false)
        StubProtocol.handler = { request in
            if request.url?.host == "other.test" {
                return statusJSON(for: request, problems: #"{"other-host":{"HTTP":{"status":16}}}"#, hostsUp: 9)
            }
            if unavailable.value { return .init(status: 401) }
            return statusJSON(for: request, problems: #"{"web1":{"Disk":{"status":4}}}"#, hostsUp: 3)
        }
        defer { StubProtocol.handler = nil }
        let store = try ServerStore(fileURL: nil, credentials: InMemoryCredentialStore())
        try store.add(server, password: "test-password")
        try store.add(other, password: nil)
        let model = MonitorModel(store: store, session: StubProtocol.session())

        #expect(model.summary(for: server.id).screen == .waiting)
        await model.refreshAll()
        let summary = model.summary(for: server.id)
        #expect(summary.hosts == 3)
        #expect(summary.entries.map(\.problem.host) == ["web1"])
        #expect(summary.mood == .warning)
        #expect(summary.answeredServers == 1)
        #expect(summary.lastFetched != nil)

        unavailable.value = true
        await model.refresh(server)
        let failed = model.summary(for: server.id)
        #expect(failed.screen == .unreachable)
        #expect(failed.unreachable?.server.id == server.id)
        #expect(failed.entries.isEmpty)
        #expect(failed.lastFetched == nil)

        try model.setEnabled(false, for: server)
        #expect(model.summary(for: server.id).isPaused)
        #expect(model.summary(for: server.id).screen == .waiting)
        try model.delete(server)
        #expect(model.summary(for: server.id).screen == .empty)
    }

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

    @Test func statusCarriesTheProgramWideNotificationSwitch() async throws {
        StubProtocol.handler = { statusJSON(for: $0, notifications: false) }
        defer { StubProtocol.handler = nil }
        #expect(try await client.fetchStatus().notificationsEnabled == false)
    }

    /// Turning notifications off fetches the form for cmd_typ 11 and posts it exactly once.
    @Test func switchingNotificationsFetchesTheFormAndPostsOnce() async throws {
        let requests = Box<[URLRequest]>([])
        let bodies = Box<[String]>([])
        StubProtocol.handler = { request in
            requests.value.append(request)
            guard request.httpMethod == "POST" else {
                return .init(body: "<form method='post' action='cmd.cgi'>\n<INPUT TYPE='hidden' NAME='nagFormId' VALUE='tok'\n"
                    + "<tr><td><INPUT TYPE='HIDDEN' NAME='cmd_typ' VALUE='11'><INPUT TYPE='HIDDEN' NAME='cmd_mod' VALUE='2'></td></tr>")
            }
            bodies.value.append(StubProtocol.body(of: request))
            return .init(body: "<div class='infoMessage'>Your command request was successfully submitted to Nagios for processing.</div>")
        }
        defer { StubProtocol.handler = nil }

        #expect(client.capabilities.contains(.monitorNotifications))
        try await client.setNotificationsEnabled(false)
        #expect(requests.value.map(\.httpMethod) == ["GET", "POST"])
        #expect(requests.value[0].url?.absoluteString == "https://nagios.test/nagios/cgi-bin/cmd.cgi?cmd_typ=11")
        #expect(requests.value[1].url?.absoluteString == "https://nagios.test/nagios/cgi-bin/cmd.cgi")
        #expect(bodies.value == ["cmd_mod=2&cmd_typ=11&nagFormId=tok"])
    }

    @Test func switchingNotificationsNeedsTheFormAndAConfirmation() async {
        let posts = Box(0)
        StubProtocol.handler = { request in
            if request.httpMethod == "POST" { posts.value += 1 }
            return .init(body: "<P><DIV CLASS='errorMessage'>Sorry, but you are not authorized to commit the specified command.</DIV></P>")
        }
        defer { StubProtocol.handler = nil }
        await #expect(throws: BackendError.self) { try await client.setNotificationsEnabled(true) }
        #expect(posts.value == 0)

        StubProtocol.handler = { request in
            request.httpMethod == "POST" ? .init(body: "<p>Error: Invalid or missing CSRF cookie!</p>")
                : .init(body: "<input name='cmd_typ' value='12'><input name='cmd_mod' value='2'>")
        }
        await #expect(throws: BackendError.self) { try await client.setNotificationsEnabled(true) }
    }

    /// Nagios applies the command later, so the switch shows the requested value until the status agrees.
    @MainActor @Test func monitorNotificationsShowTheRequestUntilNagiosAgrees() async throws {
        let enabled = Box(true)
        StubProtocol.handler = { request in
            if request.url?.lastPathComponent == "cmd.cgi" {
                return request.httpMethod == "POST"
                    ? .init(body: "<div class='infoMessage'>Your command request was successfully submitted to Nagios for processing.</div>")
                    : .init(body: "<input name='cmd_typ' value='11'><input name='cmd_mod' value='2'>")
            }
            return statusJSON(for: request, notifications: enabled.value)
        }
        defer { StubProtocol.handler = nil }

        let store = try ServerStore(fileURL: nil, credentials: InMemoryCredentialStore())
        try store.add(server, password: "s3cret")
        let model = MonitorModel(store: store, session: StubProtocol.session())
        await model.refreshAll()
        #expect(model.sourceDetail(for: server).notifications == .on)

        try await model.setMonitorNotifications(false, for: server)
        #expect(model.sourceDetail(for: server).notifications == .switching(to: false))
        enabled.value = false
        await model.refresh(server)
        #expect(model.sourceDetail(for: server).notifications == .off)
        #expect(model.notificationRequests.isEmpty)
    }

    /// Nagios shows an account without permissions an empty installation, which must not look healthy.
    @Test func noHostsAndServicesIsNotHealthy() async {
        StubProtocol.handler = { statusJSON(for: $0, hostsUp: 0) }
        defer { StubProtocol.handler = nil }
        await #expect(throws: NagiosClientError.empty) { try await client.fetchStatus() }
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
        #expect(lines.count == 5)
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
        let holdResponse = Box(false)
        StubProtocol.handler = { request in
            started.value = true
            var response = statusJSON(for: request)
            response.waitsForCancellation = holdResponse.value
            return response
        }
        defer { StubProtocol.handler = nil }
        let store = try ServerStore(fileURL: nil, credentials: InMemoryCredentialStore())
        try store.add(server, password: "s3cret")
        let model = MonitorModel(store: store, session: StubProtocol.session())
        defer { model.stopPolling() }

        await model.refreshAll()
        let previous = model.states[server.id]
        started.value = false
        holdResponse.value = true
        model.startPolling()
        let deadline = ContinuousClock.now + .seconds(2)
        while !started.value, ContinuousClock.now < deadline { await Task.yield() }
        try #require(started.value)
        // Allow a busy test runner to resume after the stub has had time to answer.
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.nextPollAt == nil)
        model.stopPolling()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.nextPollAt == nil)
        #expect(model.states[server.id] == previous)
    }

    @MainActor @Test func webPollTimesAreRecordedOnlyAfterCompletionAndShutdownWaits() async throws {
        let started = Box(false)
        let hold = Box(true)
        let unauthorized = Box(false)
        StubProtocol.handler = { request in
            started.value = true
            var response = statusJSON(for: request)
            response.waitsForCancellation = hold.value
            if unauthorized.value { response.status = 401 }
            return response
        }
        defer { StubProtocol.handler = nil }
        let store = try ServerStore(fileURL: nil, credentials: InMemoryCredentialStore())
        try store.add(server, password: nil)
        let model = MonitorModel(store: store, session: StubProtocol.session())
        model.startPolling()
        let deadline = ContinuousClock.now + .seconds(2)
        while !started.value, ContinuousClock.now < deadline { await Task.yield() }
        try #require(started.value)
        #expect(model.lastAttempts.isEmpty)
        #expect(model.lastPollCompletedAt == nil)
        await model.stopPollingAndWait()
        #expect(model.lastAttempts.isEmpty)
        hold.value = false
        await model.refreshAll()
        let success = try #require(model.lastSuccesses[server.id])
        #expect(model.lastAttempts[server.id] != nil)
        #expect(model.lastPollCompletedAt != nil)
        unauthorized.value = true
        await model.refreshAll()
        #expect(model.lastSuccesses[server.id] == success)
        #expect(model.lastAttempts[server.id]! >= success)
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
