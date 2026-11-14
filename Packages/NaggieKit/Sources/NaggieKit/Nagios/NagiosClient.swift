import Foundation

public enum NagiosClientError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case unauthorized
    case notStatusJSON
    case queryFailed(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server returned an invalid response."
        case .httpStatus(404): "statusjson.cgi was not found (HTTP 404). Is this a Nagios server?"
        case .httpStatus(let code): "The server returned HTTP \(code)."
        case .unauthorized: "Authentication failed. Check the username and password."
        case .notStatusJSON: "The response was not valid statusjson.cgi output."
        case .queryFailed(let message): "Nagios reported an error: \(message)"
        case .transport(let message): message
        }
    }
}

/// Talks to a single Nagios server through `/nagios/cgi-bin/statusjson.cgi`.
public struct NagiosClient: Sendable {
    public var endpoint: URL
    public var username: String
    public var password: String?
    public var session: URLSession

    public init(endpoint: URL, username: String, password: String?, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.session = session
    }

    public init(server: NagiosServer, password: String?, session: URLSession = .shared) {
        self.init(endpoint: server.statusJSONURL, username: server.username, password: password, session: session)
    }

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

        return try await ServerStatus(
            hosts: hosts.data?.count ?? HostCounts(),
            services: services.data?.count ?? ServiceCounts(),
            problems: problems.data?.problems ?? [],
            fetchedAt: Date()
        )
    }

    // MARK: - Request plumbing

    func request(query: String, extra: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: query)] + extra
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !username.isEmpty || password != nil {
            let token = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func get<T: Decodable>(query: String, extra: [URLQueryItem] = []) async throws -> StatusJSONEnvelope<T> {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request(query: query, extra: extra))
        } catch {
            throw NagiosClientError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw NagiosClientError.invalidResponse }
        return try Self.decode(data: data, statusCode: http.statusCode)
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
        return envelope
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

        private enum CodingKeys: String, CodingKey {
            case status
            case lastStateChange = "last_state_change"
        }

        init(from decoder: Decoder) throws {
            if let status = try? decoder.singleValueContainer().decode(Int.self) {
                self.status = status
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(Int.self, forKey: .status)
            // statusjson.cgi times are milliseconds since the epoch; 0 means "never".
            if let millis = try container.decodeIfPresent(Double.self, forKey: .lastStateChange), millis > 0 {
                lastStateChange = Date(timeIntervalSince1970: millis / 1000)
            }
        }
    }

    var servicelist: [String: [String: Entry]]

    var problems: [ServiceProblem] {
        servicelist.flatMap { host, services in
            services.compactMap { service, entry in
                NagiosServiceState(rawValue: entry.status)?.severity.map {
                    ServiceProblem(host: host, service: service, severity: $0, since: entry.lastStateChange)
                }
            }
        }
        .sorted { ($0.severity, $1.host, $1.service) > ($1.severity, $0.host, $0.service) }
    }
}
