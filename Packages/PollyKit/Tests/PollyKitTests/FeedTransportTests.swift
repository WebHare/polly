import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PollyKit

/// Feeds and custom authentication headers over the stub transport. An extension of `TransportTests`, so these
/// run one at a time with the other tests that share `StubProtocol.handler`.
extension TransportTests {
    private static let feedBody = """
        {"polly":1,"url":"https://portal.test/tickets","items":[
          {"id":"t1","group":"acme","title":"Crash","severity":"critical","url":"https://portal.test/ticket/1"}]}
        """

    private func feedServer(header: String? = nil, username: String = "") -> NagiosServer {
        NagiosServer(name: "Tickets", baseURL: URL(string: "https://portal.test/polly/feed?list=mine")!, username: username,
                     kind: .feed, authHeader: header)
    }

    @Test func feedIsReadFromTheURLAsEntered() async throws {
        let seen = Box<[URLRequest]>([])
        StubProtocol.handler = { request in
            seen.value.append(request)
            return .init(body: Self.feedBody)
        }
        defer { StubProtocol.handler = nil }

        let backend = try feedServer(username: "alice").makeBackend(password: "s3cret", session: StubProtocol.session())
        #expect(backend.capabilities == [.links])
        let status = try await backend.fetchStatus()
        #expect(status.problems.map(\.title) == ["Crash"])
        #expect(try backend.checkURL(for: status.problems[0]) == URL(string: "https://portal.test/ticket/1"))
        try await backend.testConnection()

        let request = try #require(seen.value.first)
        #expect(request.url?.absoluteString == "https://portal.test/polly/feed?list=mine")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("alice:s3cret".utf8).base64EncodedString())
    }

    @Test func feedSendsACustomHeaderInsteadOfBasicAuthentication() async throws {
        let seen = Box<[URLRequest]>([])
        StubProtocol.handler = { request in
            seen.value.append(request)
            return .init(body: Self.feedBody)
        }
        defer { StubProtocol.handler = nil }

        _ = try await feedServer(header: "X-API-Key").makeBackend(password: "k3y", session: StubProtocol.session()).fetchStatus()
        _ = try await feedServer(header: "Authorization").makeBackend(password: "Bearer t0ken", session: StubProtocol.session())
            .fetchStatus()

        #expect(seen.value[0].value(forHTTPHeaderField: "X-API-Key") == "k3y")
        #expect(seen.value[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(seen.value[1].value(forHTTPHeaderField: "Authorization") == "Bearer t0ken")
    }

    @Test func feedReportsWhyItFailed() async throws {
        StubProtocol.handler = { _ in .init(status: 401, body: #"{"error":"Token expired"}"#) }
        defer { StubProtocol.handler = nil }
        let backend = try feedServer(header: "X-API-Key").makeBackend(password: "old", session: StubProtocol.session())
        await #expect(throws: FeedError.http(401, "Token expired")) { try await backend.fetchStatus() }
    }

    #if !canImport(FoundationNetworking)
    @Test func feedDoesNotFollowRedirects() async throws {
        let requests = Box<[URL]>([])
        StubProtocol.handler = { request in
            requests.value.append(request.url!)
            return request.url?.host == "elsewhere.test" ? .init(body: Self.feedBody)
                : .init(redirectTo: URL(string: "https://elsewhere.test/feed")!)
        }
        defer { StubProtocol.handler = nil }
        let backend = try feedServer(header: "X-API-Key").makeBackend(password: "k3y", session: StubProtocol.session())
        await #expect(throws: FeedError.redirect) { try await backend.fetchStatus() }
        #expect(!requests.value.contains { $0.host() == "elsewhere.test" })
    }
    #endif

    @Test func nagiosSendsACustomHeaderToo() async throws {
        let headers = Box<[String?]>([])
        StubProtocol.handler = { request in
            headers.value.append(request.value(forHTTPHeaderField: "X-Proxy-Token"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return statusJSON(for: request)
        }
        defer { StubProtocol.handler = nil }
        var server = server
        server.authHeader = "X-Proxy-Token"
        _ = try await server.makeBackend(password: "pr0xy", session: StubProtocol.session()).fetchStatus()
        #expect(!headers.value.isEmpty)
        #expect(headers.value.allSatisfy { $0 == "pr0xy" })
    }

    @Test func wireLogLeavesOutCustomHeaders() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "polly-wire-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        StubProtocol.handler = { _ in .init(body: Self.feedBody) }
        defer { StubProtocol.handler = nil }

        var client = FeedClient(server: feedServer(header: "X-API-Key"), password: "k3y-value", session: StubProtocol.session())
        client.wireLog = WireLog(fileURL: file)
        _ = try await client.fetchStatus()

        let text = try String(contentsOf: file, encoding: .utf8)
        // Linux Foundation writes the header name as "X-Api-Key"; header names don't depend on case.
        #expect(text.lowercased().contains("x-api-key"))
        #expect(text.contains("<redacted>"))
        #expect(text.contains("application/json"))
        #expect(!text.contains("k3y-value"))
    }
}
