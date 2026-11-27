import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads a Polly feed (see `FeedDocument` and doc/feed-format.md) with one GET of the URL as entered. Feeds are
/// read-only: there are no commands, and the only link is the item's own page.
public struct FeedClient: MonitorBackend {
    public var url: URL
    public var credentials: SourceCredentials
    public var session: URLSession
    /// Records every request and response when set.
    public var wireLog: WireLog?

    public init(url: URL, credentials: SourceCredentials = SourceCredentials(), session: URLSession = .shared) {
        self.url = url
        self.credentials = credentials
        self.session = session
    }

    /// The permission to read a feed file, and how long it may stay unchanged.
    public var fileBookmark: Data?
    public var staleAfter: TimeInterval = NagiosServer.defaultStaleAfter
    /// Reads a feed file: its contents and modification time. Replaced in tests.
    public var readFile: @Sendable (URL, Data?) throws -> (Data, Date) = { try FeedFile.read($0, bookmark: $1) }
    public var now: @Sendable () -> Date = { .now }

    public init(server: NagiosServer, password: String?, session: URLSession = .shared) {
        self.init(url: server.baseURL, credentials: server.credentials(password: password), session: session)
        fileBookmark = server.fileBookmark
        staleAfter = server.staleAfter ?? NagiosServer.defaultStaleAfter
    }

    public var capabilities: BackendCapabilities { [.links] }

    public func testConnection() async throws {
        _ = try await fetchStatus()
    }

    public func fetchStatus() async throws -> ServerStatus {
        if url.isFileURL {
            let (data, modified) = try readFile(url, fileBookmark)
            return try FeedFile.status(from: data, modifiedAt: modified, now: now(), staleAfter: staleAfter)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        credentials.apply(to: &request)
        let started = Date()

        let data: Data
        let response: URLResponse
        do {
            #if canImport(FoundationNetworking)
            // Corelibs ignores the per-task redirect delegate; keep the configuration but use a session delegate.
            let session = URLSession(configuration: session.configuration, delegate: RedirectRefuser(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            #endif
            (data, response) = try await session.data(for: request, delegate: RedirectRefuser())
        } catch {
            wireLog?.record(request: request, status: nil, body: nil, error: error.localizedDescription)
            throw FeedError.transport(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        wireLog?.record(request: request, status: http?.statusCode, body: data, error: nil)
        guard let http else { throw FeedError.invalidResponse }
        if (300..<400).contains(http.statusCode) { throw FeedError.redirect }
        return try FeedDocument.status(from: data, statusCode: http.statusCode, fetchedAt: started)
    }

    public func checkURL(for problem: ServiceProblem) throws -> URL {
        guard let link = problem.link else { throw BackendError("The feed has no page for this item.") }
        return link
    }
}
