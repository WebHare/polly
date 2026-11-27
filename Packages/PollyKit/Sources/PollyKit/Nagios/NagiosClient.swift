import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        case .redirect: "The server redirected the request, which Polly does not follow so your password stays with this server. Enter the final URL instead."
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
    /// When set, `password` is sent as this header instead of Basic authentication.
    public var authHeader: String?
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
        authHeader = server.authHeader
    }

    public var capabilities: BackendCapabilities { [.links, .relatedLinks, .commands, .monitorNotifications] }

    /// Connectivity check: runs the cheap `programstatus` query and verifies the answer.
    public func testConnection() async throws {
        let _: StatusJSONEnvelope<IgnoredPayload> = try await get(query: "programstatus")
    }

    public func fetchStatus() async throws -> ServerStatus {
        // A task group, not `async let`: with async let the process crashed when a server refused the connection while
        // other requests were in flight. It looks like the async let teardown bugs in Swift 6.1+ (see swiftlang/swift#81771).
        enum Part: Sendable {
            case hosts(HostCounts), services(ServiceCounts), problems([ServiceProblem]), hostProblems([ServiceProblem])
            case notifications(Bool?)
        }
        var hosts = HostCounts(), services = ServiceCounts(), problems: [ServiceProblem] = [], hostProblems: [ServiceProblem] = []
        var notifications: Bool?
        try await withThrowingTaskGroup(of: Part.self) { group in
            group.addTask {
                let envelope: StatusJSONEnvelope<CountPayload<HostCounts>> = try await get(query: "hostcount")
                return .hosts(envelope.data?.count ?? HostCounts())
            }
            group.addTask {
                let envelope: StatusJSONEnvelope<CountPayload<ServiceCounts>> = try await get(query: "servicecount")
                return .services(envelope.data?.count ?? ServiceCounts())
            }
            group.addTask {
                let envelope: StatusJSONEnvelope<ServiceListPayload> =
                    try await get(query: "servicelist", extra: [URLQueryItem(name: "servicestatus", value: "warning critical unknown"),
                                                                URLQueryItem(name: "details", value: "true")])
                return .problems(envelope.data?.problems ?? [])
            }
            group.addTask {
                let envelope: StatusJSONEnvelope<HostListPayload> =
                    try await get(query: "hostlist", extra: [URLQueryItem(name: "hoststatus", value: "down unreachable"),
                                                             URLQueryItem(name: "details", value: "true")])
                return .hostProblems(envelope.data?.problems ?? [])
            }
            group.addTask {
                let envelope: StatusJSONEnvelope<ProgramStatusPayload> = try await get(query: "programstatus")
                return .notifications(envelope.data?.programstatus?.notificationsEnabled)
            }
            for try await part in group {
                switch part {
                case .hosts(let value): hosts = value
                case .services(let value): services = value
                case .problems(let value): problems = value
                case .hostProblems(let value): hostProblems = value
                case .notifications(let value): notifications = value
                }
            }
        }

        let status = ServerStatus(hosts: hosts, services: services, problems: hostProblems + problems, fetchedAt: Date(),
                                  notificationsEnabled: notifications)
        // Nagios shows an account without permissions an empty installation, which must not look healthy.
        let h = status.hosts, s = status.services
        if h.up + h.down + h.unreachable + h.pending + s.ok + s.warning + s.critical + s.unknown + s.pending == 0 {
            throw NagiosClientError.empty
        }
        return status
    }

    // MARK: - Links and commands

    public func checkURL(for problem: ServiceProblem) throws -> URL {
        problem.isHost ? try cgiURL("extinfo.cgi", ["type": "1", "host": problem.host])
            : try cgiURL("extinfo.cgi", ["type": "2", "host": problem.host, "service": problem.service])
    }

    public func relatedURL(for problem: ServiceProblem) async throws -> URL {
        let url = try checkURL(for: problem)
        return try NagiosHTML.relatedURL(html: try await page(request(url: url)), pageURL: url)
    }

    /// Fetches the command forms. Their CSRF token and cookie are what make the later `submit` acceptable to Nagios.
    /// For a downtime it also fetches the forms behind the options (host and services, also acknowledge); an
    /// option whose form doesn't come back is simply not offered. The forms are fetched one after the other: on
    /// Nagios 4.5.12+ the first answer sets the CSRF cookie, and later requests have to carry it to get the same token.
    public func prepareCommand(_ kind: CommandKind, for problem: ServiceProblem) async throws -> any PreparedCommand {
        let acknowledge = NagiosCommand.acknowledge(problem), ownDowntime = NagiosCommand.downtime(problem)
        let main = kind == .acknowledge ? acknowledge : ownDowntime
        guard let form = try await form(main, for: problem) else {
            throw BackendError("Nagios did not return the expected command form. Check your command permissions in the browser.")
        }
        var forms = [main: form]
        if kind == .downtime {
            // Optional: a failure here only hides the option.
            for extra in [NagiosCommand.hostDowntime, .hostServicesDowntime] + (problem.acknowledged ? [] : [acknowledge])
            where forms[extra] == nil {
                forms[extra] = try? await self.form(extra, for: problem)
            }
        }
        var options: CommandOptions = []
        if forms[.hostDowntime] != nil, forms[.hostServicesDowntime] != nil { options.insert(.hostScope) }
        if kind == .downtime, forms[acknowledge] != nil { options.insert(.alsoAcknowledge) }
        let defaults = CommandInput(author: form["com_author"].flatMap { $0.isEmpty ? nil : $0 } ?? username,
                                    start: form["start_time"] ?? "", end: form["end_time"] ?? "",
                                    alsoAcknowledge: options.contains(.alsoAcknowledge))
        let notations = NagiosDateNotation.candidates(prefilledStart: defaults.start, prefilledEnd: defaults.end)
        return NagiosPreparedCommand(kind: kind, problem: problem, defaults: defaults, options: options, forms: forms,
                                     notations: notations, client: self)
    }

    /// Program-wide DISABLE_NOTIFICATIONS / ENABLE_NOTIFICATIONS: fetches the form, then posts it once with the same
    /// session, so the CSRF cookie travels along.
    public func setNotificationsEnabled(_ enabled: Bool) async throws {
        let command: NagiosCommand = enabled ? .enableNotifications : .disableNotifications
        let request = request(url: try cgiURL("cmd.cgi", ["cmd_typ": command.rawValue]))
        let inputs = NagiosCommandForm.inputs(try await page(request))
        guard NagiosCommandForm.isForm(inputs, for: command) else {
            throw BackendError("Nagios did not return the expected command form. Check your command permissions in the browser.")
        }
        try await commit(try NagiosCommandForm.body(command, form: inputs, author: username), formRequest: request)
    }

    /// Posts a filled-in form once, to the URL it came from without its query, and checks Nagios' confirmation.
    fileprivate func commit(_ body: Data, formRequest: URLRequest) async throws {
        var post = formRequest
        // The form's query only selects the form; the command itself is the POST body.
        var components = URLComponents(url: formRequest.url!, resolvingAgainstBaseURL: false)!
        components.query = nil
        post.url = components.url
        post.httpMethod = "POST"
        post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        post.setValue(formRequest.url!.absoluteString, forHTTPHeaderField: "Referer")
        post.httpBody = body
        try NagiosCommandForm.validateResult(try await page(post))
    }

    /// The form for `command`, or nil when Nagios answers with something else (no permission, a login page, ...).
    fileprivate func form(_ command: NagiosCommand, for problem: ServiceProblem) async throws -> NagiosForm? {
        var parameters = ["cmd_typ": command.rawValue, "host": problem.host]
        if command.hasService { parameters["service"] = problem.service }
        let request = request(url: try cgiURL("cmd.cgi", parameters))
        let inputs = NagiosCommandForm.inputs(try await page(request))
        guard NagiosCommandForm.isForm(inputs, for: command, problem: problem) else { return nil }
        return NagiosForm(inputs: inputs, request: request)
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
        SourceCredentials(username: authHeader == nil ? username : "", password: password, headerName: authHeader)
            .apply(to: &request)
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
            #if canImport(FoundationNetworking)
            // Corelibs ignores the per-task redirect delegate; keep cookies/configuration but use a session delegate.
            // shortcut: one session per request; reuse an owned session if Linux polling becomes frequent.
            let session = URLSession(configuration: session.configuration, delegate: RedirectRefuser(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            #endif
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

/// Following a redirect would send the credentials to wherever it points.
final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Commands

/// A fetched `cmd.cgi` form: its inputs and the request that fetched it.
private struct NagiosForm: Sendable {
    var inputs: [String: String]
    var request: URLRequest

    subscript(name: String) -> String? { inputs[name] }
}

private struct NagiosPreparedCommand: PreparedCommand {
    let kind: CommandKind
    let problem: ServiceProblem
    let defaults: CommandInput
    let options: CommandOptions
    let forms: [NagiosCommand: NagiosForm]
    /// The date notations the server may be using, for the presets.
    let notations: [NagiosDateNotation]
    let client: NagiosClient

    func end(for preset: DowntimePreset, from start: String) -> String? {
        kind == .downtime ? NagiosDateNotation.end(for: preset, from: start, candidates: notations) : nil
    }

    /// The requests `input` asks for, in the order they are sent, each with its POST body.
    private func steps(_ input: CommandInput) throws -> [(command: NagiosCommand, body: Data)] {
        var commands: [NagiosCommand]
        let acknowledge = NagiosCommand.acknowledge(problem)
        switch kind {
        case .acknowledge:
            commands = [acknowledge]
        case .downtime:
            if input.scope == .hostAndServices {
                guard options.contains(.hostScope) else { throw BackendError("Nagios does not allow a downtime for this host.") }
                commands = [.hostDowntime, .hostServicesDowntime]
            } else {
                commands = [NagiosCommand.downtime(problem)]
            }
            if input.alsoAcknowledge {
                guard options.contains(.alsoAcknowledge) else { throw BackendError("Nagios does not allow acknowledging this problem.") }
                commands.append(acknowledge)
            }
        }
        return try commands.map { command in
            // The acknowledgement that comes with a downtime doesn't notify: the downtime is the news.
            let stepInput = kind == .downtime && !command.isDowntime
                ? CommandInput(author: input.author, comment: input.comment) : input
            return (command, try NagiosCommandForm.body(command, problem: problem, input: stepInput, form: forms[command]!.inputs))
        }
    }

    func validate(_ input: CommandInput) throws {
        _ = try steps(input)
    }

    /// Posts each request once, in order, with the same session as the form GETs so the CSRF cookie Nagios set there
    /// travels along. Stops at the first request Nagios doesn't confirm.
    func submit(_ input: CommandInput) async throws {
        let steps = try steps(input)
        for (index, step) in steps.enumerated() {
            do {
                try await client.commit(step.body, formRequest: forms[step.command]!.request)
            } catch where steps.count > 1 {
                if index == 0 { throw error }
                throw CommandSequenceError(accepted: steps[..<index].map { $0.command.label(for: problem) },
                                           failed: step.command.label(for: problem),
                                           notSent: steps[(index + 1)...].map { $0.command.label(for: problem) },
                                           reason: error.localizedDescription)
            }
        }
    }
}

// MARK: - Payloads

struct IgnoredPayload: Decodable {}

/// `{"programstatus": {"version": "4.5.14", "enable_notifications": true, ...}}`; only the notification switch is read.
struct ProgramStatusPayload: Decodable {
    struct Status: Decodable {
        var notificationsEnabled: Bool?

        private enum CodingKeys: String, CodingKey {
            case notificationsEnabled = "enable_notifications"
        }
    }

    var programstatus: Status?
}

struct CountPayload<Counts: Decodable>: Decodable {
    var count: Counts
}

/// With `details=true`: `{"hostlist": {"host1": {"status": 4, "last_state_change": 1731590000000, ...}}}`, with the
/// same fields as a service. Only the hosts that are down or unreachable become problems.
struct HostListPayload: Decodable {
    var hostlist: [String: ServiceListPayload.Entry]

    var problems: [ServiceProblem] {
        hostlist.compactMap { host, entry in
            NagiosHostState(rawValue: entry.status)?.problem.map {
                ServiceProblem.host(host, $0, since: entry.lastStateChange, output: entry.output, longOutput: entry.longOutput,
                                    lastCheck: entry.lastCheck, acknowledged: entry.acknowledged,
                                    downtimeDepth: entry.downtimeDepth, checkAttempt: entry.checkAttempt, nextCheck: entry.nextCheck)
            }
        }
        .sorted { $0.host < $1.host }
    }
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
        var checkAttempt: CheckAttempt?
        var nextCheck: Date?

        private enum CodingKeys: String, CodingKey {
            case status
            case lastStateChange = "last_state_change"
            case lastCheck = "last_check"
            case output = "plugin_output"
            case longOutput = "long_plugin_output"
            case acknowledged = "problem_has_been_acknowledged"
            case downtimeDepth = "scheduled_downtime_depth"
            case stateType = "state_type"
            case currentAttempt = "current_attempt"
            case maxAttempts = "max_attempts"
            case nextCheck = "next_check"
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
            nextCheck = try Self.date(container, .nextCheck)
            // state_type is 0/1, or "soft"/"hard" when the server enumerates values as text.
            let hard = (try? container.decode(Int.self, forKey: .stateType)).map { $0 == 1 }
                ?? (try? container.decode(String.self, forKey: .stateType)).map { $0.lowercased() == "hard" }
            if let hard, let current = try container.decodeIfPresent(Int.self, forKey: .currentAttempt),
               let max = try container.decodeIfPresent(Int.self, forKey: .maxAttempts) {
                checkAttempt = CheckAttempt(hard: hard, current: current, max: max)
            }
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
                                   acknowledged: entry.acknowledged, downtimeDepth: entry.downtimeDepth,
                                   checkAttempt: entry.checkAttempt, nextCheck: entry.nextCheck)
                }
            }
        }
        .sorted { ($0.severity, $1.host, $1.service) > ($1.severity, $0.host, $0.service) }
    }
}
