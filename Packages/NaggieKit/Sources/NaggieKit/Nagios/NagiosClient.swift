import Foundation

public enum NagiosClientError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case unauthorized
    case notStatusJSON
    case queryFailed(String)
    case transport(String)
    case redirect
    case empty

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server returned an invalid response."
        case .httpStatus(404): "statusjson.cgi was not found (HTTP 404). Is this a Nagios server?"
        case .httpStatus(let code): "The server returned HTTP \(code)."
        case .unauthorized: "Authentication failed. Check the username and password."
        case .notStatusJSON: "The response was not valid statusjson.cgi output."
        case .queryFailed(let message): "Nagios reported an error: \(message)"
        case .transport(let message): message
        case .redirect: "The server redirected the request, which Naggie does not follow so your password stays with this server. Enter the final URL instead."
        case .empty: "Nagios returned no hosts or services. This account may not be allowed to see any."
        }
    }
}

/// Talks to a single Nagios server: status through `/nagios/cgi-bin/statusjson.cgi`, check links through
/// `extinfo.cgi` and commands through `cmd.cgi`.
public struct NagiosClient: MonitorBackend {
    public var endpoint: URL
    public var username: String
    public var password: String?
    public var session: URLSession
    /// Records every request and response when set.
    public var wireLog: WireLog?

    public init(endpoint: URL, username: String, password: String?, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.session = session
    }

    public init(server: NagiosServer, password: String?, session: URLSession = .shared) {
        self.init(endpoint: server.statusJSONURL, username: server.username, password: password, session: session)
    }

    public var capabilities: BackendCapabilities { [.links, .commands] }

    /// Connectivity check: runs the cheap `programstatus` query and verifies the answer.
    public func testConnection() async throws {
        let _: StatusJSONEnvelope<IgnoredPayload> = try await get(query: "programstatus")
    }

    public func fetchStatus() async throws -> ServerStatus {
        async let hosts: StatusJSONEnvelope<CountPayload<HostCounts>> = get(query: "hostcount")
        async let services: StatusJSONEnvelope<CountPayload<ServiceCounts>> = get(query: "servicecount")
        async let problems: StatusJSONEnvelope<ServiceListPayload> =
            get(query: "servicelist", extra: [URLQueryItem(name: "servicestatus", value: "warning critical unknown"),
                                         URLQueryItem(name: "details", value: "true")])

        let status = try await ServerStatus(
            hosts: hosts.data?.count ?? HostCounts(),
            services: services.data?.count ?? ServiceCounts(),
            problems: problems.data?.problems ?? [],
            fetchedAt: Date()
        )
        // Nagios shows an account without permissions an empty installation, which must not look healthy.
        let h = status.hosts, s = status.services
        if h.up + h.down + h.unreachable + h.pending + s.ok + s.warning + s.critical + s.unknown + s.pending == 0 {
            throw NagiosClientError.empty
        }
        return status
    }

    // MARK: - Links and commands

    public func checkURL(for problem: ServiceProblem) throws -> URL {
        try cgiURL("extinfo.cgi", ["type": "2", "host": problem.host, "service": problem.service])
    }

    public func relatedURL(for problem: ServiceProblem) async throws -> URL {
        let url = try checkURL(for: problem)
        return try NagiosHTML.relatedURL(html: try await page(request(url: url)), pageURL: url)
    }

    /// Fetches the command form. Its CSRF token and cookie are what make the later `submit` acceptable to Nagios.
    public func prepareCommand(_ kind: CommandKind, for problem: ServiceProblem) async throws -> any PreparedCommand {
        let formRequest = request(url: try cgiURL("cmd.cgi", ["cmd_typ": kind.nagiosCommandType,
                                                             "host": problem.host, "service": problem.service]))
        let form = NagiosCommandForm.inputs(try await page(formRequest))
        guard form["cmd_typ"] == kind.nagiosCommandType, form["cmd_mod"] == "2",
              form["host"] == problem.host, form["service"] == problem.service else {
            throw BackendError("Nagios did not return the expected command form. Check your command permissions in the browser.")
        }
        let defaults = CommandInput(author: form["com_author"].flatMap { $0.isEmpty ? nil : $0 } ?? username,
                                    start: form["start_time"] ?? "", end: form["end_time"] ?? "")
        return NagiosPreparedCommand(kind: kind, problem: problem, defaults: defaults, form: form,
                                     formRequest: formRequest, client: self)
    }

    // MARK: - Request plumbing

    func request(query: String, extra: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: query)] + extra
        var request = request(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        if !username.isEmpty || password != nil {
            let token = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Another CGI next to statusjson.cgi, with a strictly encoded query.
    private func cgiURL(_ name: String, _ parameters: [String: String]) throws -> URL {
        var components = URLComponents(url: endpoint.deletingLastPathComponent().appending(path: name),
                                       resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = NagiosCommandForm.encode(parameters)
        guard let url = components?.url else { throw BackendError("Could not build the \(name) URL for this server.") }
        return url
    }

    /// The only way requests leave this client: refuses redirects and records the exchange in `wireLog`.
    fileprivate func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: RedirectRefuser())
        } catch {
            wireLog?.record(request: request, status: nil, body: nil, error: error.localizedDescription)
            throw NagiosClientError.transport(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        wireLog?.record(request: request, status: http?.statusCode, body: data, error: nil)
        guard let http else { throw NagiosClientError.invalidResponse }
        if (300..<400).contains(http.statusCode) { throw NagiosClientError.redirect }
        return (data, http)
    }

    private func get<T: Decodable>(query: String, extra: [URLQueryItem] = []) async throws -> StatusJSONEnvelope<T> {
        let (data, response) = try await send(request(query: query, extra: extra))
        return try Self.decode(data: data, statusCode: response.statusCode)
    }

    /// An HTML page from one of the CGIs.
    fileprivate func page(_ request: URLRequest) async throws -> String {
        let (data, response) = try await send(request)
        if response.statusCode == 401 || response.statusCode == 403 { throw NagiosClientError.unauthorized }
        guard response.statusCode == 200 else {
            throw BackendError("\(request.url?.lastPathComponent ?? "Nagios") returned HTTP \(response.statusCode).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<T: Decodable>(data: Data, statusCode: Int) throws -> StatusJSONEnvelope<T> {
        if statusCode == 401 || statusCode == 403 { throw NagiosClientError.unauthorized }
        guard (200..<300).contains(statusCode) else { throw NagiosClientError.httpStatus(statusCode) }
        let envelope: StatusJSONEnvelope<T>
        do {
            envelope = try JSONDecoder().decode(StatusJSONEnvelope<T>.self, from: data)
        } catch {
            throw NagiosClientError.notStatusJSON
        }
        guard envelope.result.type_code == 0 else {
            throw NagiosClientError.queryFailed(envelope.result.message ?? envelope.result.type_text ?? "unknown error")
        }
        // A successful result without a payload must never be read as "no problems".
        guard envelope.data != nil else { throw NagiosClientError.notStatusJSON }
        return envelope
    }
}

/// Following a redirect would send the Basic credentials to wherever it points.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Commands

private struct NagiosPreparedCommand: PreparedCommand {
    let kind: CommandKind
    let problem: ServiceProblem
    let defaults: CommandInput
    let form: [String: String]
    let formRequest: URLRequest
    let client: NagiosClient

    func validate(_ input: CommandInput) throws {
        _ = try NagiosCommandForm.body(kind: kind, problem: problem, input: input, form: form)
    }

    /// Posts with the same session as the form GET, so the CSRF cookie Nagios set there travels along.
    func submit(_ input: CommandInput) async throws {
        var post = formRequest
        // The form's query only selects the form; the command itself is the POST body.
        var components = URLComponents(url: formRequest.url!, resolvingAgainstBaseURL: false)!
        components.query = nil
        post.url = components.url
        post.httpMethod = "POST"
        post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        post.setValue(formRequest.url!.absoluteString, forHTTPHeaderField: "Referer")
        post.httpBody = try NagiosCommandForm.body(kind: kind, problem: problem, input: input, form: form)
        try NagiosCommandForm.validateResult(try await client.page(post))
    }
}

// MARK: - Payloads

struct IgnoredPayload: Decodable {}

struct CountPayload<Counts: Decodable>: Decodable {
    var count: Counts
}

/// With `details=true`: `{"servicelist": {"host1": {"HTTP": {"status": 16, "last_state_change": 1731590000000, ...}}}}`.
/// Without details each service maps to just the status number; both forms are accepted.
struct ServiceListPayload: Decodable {
    struct Entry: Decodable {
        var status: Int
        var lastStateChange: Date?
        var lastCheck: Date?
        var output = ""
        var longOutput = ""
        var acknowledged = false
        var downtimeDepth = 0

        private enum CodingKeys: String, CodingKey {
            case status
            case lastStateChange = "last_state_change"
            case lastCheck = "last_check"
            case output = "plugin_output"
            case longOutput = "long_plugin_output"
            case acknowledged = "problem_has_been_acknowledged"
            case downtimeDepth = "scheduled_downtime_depth"
        }

        init(from decoder: Decoder) throws {
            if let status = try? decoder.singleValueContainer().decode(Int.self) {
                self.status = status
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(Int.self, forKey: .status)
            lastStateChange = try Self.date(container, .lastStateChange)
            lastCheck = try Self.date(container, .lastCheck)
            output = try container.decodeIfPresent(String.self, forKey: .output)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Nagios escapes the newlines in long output as a literal backslash-n.
            longOutput = try container.decodeIfPresent(String.self, forKey: .longOutput)?.replacingOccurrences(of: "\\n", with: "\n") ?? ""
            acknowledged = try container.decodeIfPresent(Bool.self, forKey: .acknowledged) ?? false
            downtimeDepth = try container.decodeIfPresent(Int.self, forKey: .downtimeDepth) ?? 0
        }

        /// statusjson.cgi times are milliseconds since the epoch; 0 means "never".
        private static func date(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date? {
            guard let millis = try container.decodeIfPresent(Double.self, forKey: key), millis > 0 else { return nil }
            return Date(timeIntervalSince1970: millis / 1000)
        }
    }

    var servicelist: [String: [String: Entry]]

    var problems: [ServiceProblem] {
        servicelist.flatMap { host, services in
            services.compactMap { service, entry in
                NagiosServiceState(rawValue: entry.status)?.severity.map {
                    ServiceProblem(host: host, service: service, severity: $0, since: entry.lastStateChange,
                                   output: entry.output, longOutput: entry.longOutput, lastCheck: entry.lastCheck,
                                   acknowledged: entry.acknowledged, downtimeDepth: entry.downtimeDepth)
                }
            }
        }
        .sorted { ($0.severity, $1.host, $1.service) > ($1.severity, $0.host, $0.service) }
    }
}
