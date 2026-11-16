import Foundation
#if canImport(Security)
import Security

/// Monitors a single website without any monitoring system behind it. The URL is one host with three
/// services, checked from this device on every poll:
///
/// - **DNS**: the host name resolves.
/// - **HTTP**: a GET of the URL gets an answer below 400. Redirects are not followed; a redirect is an answer.
/// - **Certificate** (https only): the server's certificate chain is trusted for the host name, and stays
///   valid for at least `certificateWarningPeriod`.
///
/// Every outcome is reported as a service, so `fetchStatus` only throws for a URL without a host.
public struct URLMonitor: MonitorBackend {
    public static let dnsService = "DNS"
    public static let httpService = "HTTP"
    public static let certificateService = "Certificate"

    public var url: URL
    public var username: String
    public var password: String?
    /// Its configuration is used for a fresh session per check: only a new connection shows the certificate.
    public var session: URLSession
    public var wireLog: WireLog?
    /// A certificate chain that expires within this period is a warning.
    public var certificateWarningPeriod: TimeInterval = 14 * 24 * 3600
    /// Resolves a host name to its addresses. Replaceable for tests.
    public var resolve: @Sendable (String) async throws -> [String] = DNSResolver.addresses

    public init(url: URL, username: String = "", password: String? = nil, session: URLSession = .shared) {
        self.url = url
        self.username = username
        self.password = password
        self.session = session
    }

    public init(server: NagiosServer, password: String?, session: URLSession = .shared) {
        self.init(url: server.baseURL, username: server.username, password: password, session: session)
    }

    /// Succeeds unless a check is critical; a certificate that expires soon doesn't stop adding the URL.
    public func testConnection() async throws {
        let status = try await fetchStatus()
        if let problem = status.problems.first(where: { $0.severity == .critical }) {
            throw BackendError("\(problem.service): \(problem.output)")
        }
    }

    public func fetchStatus() async throws -> ServerStatus {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw BackendError("This URL has no host name.")
        }
        let started = Date()
        var results: [(service: String, result: CheckResult)] = []

        let dns: CheckResult
        do {
            let addresses = try await resolve(host)
            dns = .ok("\(host) resolves to \(addresses.joined(separator: ", "))")
        } catch {
            dns = .problem(.critical, "DNS lookup of \(host) failed: \(error.localizedDescription)")
        }
        results.append((Self.dnsService, dns))

        let isHTTPS = url.scheme?.lowercased() == "https"
        if case .problem = dns {
            // Without an address there is nothing to connect to; don't report the same outage three times.
            results.append((Self.httpService, .skipped))
            if isHTTPS { results.append((Self.certificateService, .skipped)) }
        } else {
            let (http, certificate) = await checkHTTP()
            results.append((Self.httpService, http))
            if isHTTPS { results.append((Self.certificateService, certificate)) }
        }
        return Self.status(host: host, results: results, checkedAt: started)
    }

    // MARK: - Checks

    enum CheckResult: Equatable, Sendable {
        case ok(String)
        case problem(Severity, String)
        /// Not checked because a check it depends on failed.
        case skipped
    }

    /// One GET over a new connection, so the TLS handshake (and with it the certificate) is always seen.
    private func checkHTTP() async -> (http: CheckResult, certificate: CheckResult) {
        let sendsCredentials = !username.isEmpty || password != nil
        let recorder = TLSRecorder(warningPeriod: certificateWarningPeriod, acceptUntrusted: !sendsCredentials)
        let configuration = session.configuration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let checkSession = URLSession(configuration: configuration, delegate: recorder, delegateQueue: nil)
        defer { checkSession.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        if sendsCredentials {
            let token = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }

        let started = Date()
        let http: CheckResult
        do {
            let (_, response) = try await checkSession.data(for: request)
            let seconds = Date().timeIntervalSince(started)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            wireLog?.record(request: request, status: code, body: nil, error: nil)
            http = Self.httpResult(statusCode: code, seconds: seconds)
        } catch {
            wireLog?.record(request: request, status: nil, body: nil, error: error.localizedDescription)
            if case .invalid? = recorder.certificate, sendsCredentials {
                http = .problem(.critical, "Not connected: the certificate is not valid, and Polly does not send your password to such a server.")
            } else {
                http = .problem(.critical, error.localizedDescription)
            }
        }

        let certificate: CheckResult = switch recorder.certificate {
        case .valid?: .ok("The certificate is valid.")
        case .invalid(let message)?: .problem(.critical, "The certificate is not valid: \(message)")
        case .expiring(let date)?: .problem(.warning, Self.expiryMessage(date))
        // No handshake took place, e.g. because the connection was refused. HTTP reports that already.
        case nil: .skipped
        }
        return (http, certificate)
    }

    static func expiryMessage(_ date: Date, now: Date = Date()) -> String {
        let days = Int((date.timeIntervalSince(now) / 86400).rounded(.down))
        let when = days < 1 ? "within a day" : days == 1 ? "in 1 day" : "in \(days) days"
        return "The certificate expires \(when), on \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    static func httpResult(statusCode: Int, seconds: TimeInterval) -> CheckResult {
        let timing = "in \(seconds.formatted(.number.precision(.fractionLength(2)))) s"
        switch statusCode {
        case 200..<400: return .ok("HTTP \(statusCode) \(timing)")
        case 400..<600: return .problem(.critical, "HTTP \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode)) \(timing)")
        default: return .problem(.critical, "Invalid HTTP response \(timing)")
        }
    }

    /// One host with a service per check. The host is down when it can't be resolved or doesn't answer.
    static func status(host: String, results: [(service: String, result: CheckResult)], checkedAt: Date) -> ServerStatus {
        var services = ServiceCounts()
        var problems: [ServiceProblem] = []
        var hostDown = false
        for (service, result) in results {
            switch result {
            case .ok:
                services.ok += 1
            case .skipped:
                services.pending += 1
            case .problem(let severity, let output):
                switch severity {
                case .ok: services.ok += 1
                case .warning: services.warning += 1
                case .unknown: services.unknown += 1
                case .critical: services.critical += 1
                }
                if severity == .critical, service == dnsService || service == httpService { hostDown = true }
                problems.append(ServiceProblem(host: host, service: service, severity: severity, output: output,
                                               lastCheck: checkedAt))
            }
        }
        return ServerStatus(hosts: HostCounts(up: hostDown ? 0 : 1, down: hostDown ? 1 : 0), services: services,
                            problems: problems.sorted { $0.severity > $1.severity }, fetchedAt: checkedAt)
    }
}

#endif

// MARK: - Certificate

enum CertificateCheck: Equatable, Sendable {
    case valid
    case invalid(String)
    /// Trusted now, but a certificate in the chain expires at this date.
    case expiring(Date)

    #if canImport(Security)
    static func evaluate(_ trust: SecTrust, warningPeriod: TimeInterval, now: Date = Date()) -> CertificateCheck {
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            return .invalid(error.map { CFErrorCopyDescription($0) as String } ?? "it is not trusted.")
        }
        var chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        // The last one is the trusted root. Roots are replaced through system updates, not by the site.
        if chain.count > 1 { chain.removeLast() }
        return expiry(of: chain.compactMap { CertificateDates.notAfter(SecCertificateCopyData($0) as Data) },
                      warningPeriod: warningPeriod, now: now)
    }

    #endif

    static func expiry(of notAfters: [Date], warningPeriod: TimeInterval, now: Date = Date()) -> CertificateCheck {
        guard let first = notAfters.min(), first < now.addingTimeInterval(warningPeriod) else { return .valid }
        return .expiring(first)
    }
}

/// Reads the validity dates from a DER encoded X.509 certificate. Apple's APIs only offer them on macOS.
enum CertificateDates {
    /// `notAfter` from Certificate → TBSCertificate → Validity.
    static func notAfter(_ der: Data) -> Date? {
        var reader = DERReader(bytes: [UInt8](der))
        guard var certificate = reader.read(tag: 0x30)?.contents, var tbs = certificate.read(tag: 0x30)?.contents else {
            return nil
        }
        if tbs.peekTag == 0xA0 { _ = tbs.read() } // [0] version
        guard tbs.read(tag: 0x02) != nil, // serialNumber
              tbs.read(tag: 0x30) != nil, // signature
              tbs.read(tag: 0x30) != nil, // issuer
              var validity = tbs.read(tag: 0x30)?.contents,
              validity.read() != nil, // notBefore
              let notAfter = validity.read()
        else { return nil }
        return time(tag: notAfter.tag, String(decoding: notAfter.contents.bytes, as: UTF8.self))
    }

    /// UTCTime `YYMMDDHHMMSSZ` (years 1950–2049) or GeneralizedTime `YYYYMMDDHHMMSSZ`.
    static func time(tag: UInt8, _ text: String) -> Date? {
        var text = text
        switch tag {
        case 0x17:
            guard let year = Int(text.prefix(2)) else { return nil }
            text = (year >= 50 ? "19" : "20") + text
        case 0x18: break
        default: return nil
        }
        let digits = Array(text.utf8)
        guard digits.count == 15, digits.last == UInt8(ascii: "Z"),
              digits.dropLast().allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
        func number(_ from: Int, _ length: Int) -> Int { Int(String(decoding: digits[from..<from + length], as: UTF8.self))! }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: number(0, 4), month: number(4, 2), day: number(6, 2),
                                        hour: number(8, 2), minute: number(10, 2), second: number(12, 2))
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }
}

/// Minimal DER walker: just enough to step through the outer structure of a certificate.
struct DERReader {
    var bytes: ArraySlice<UInt8>

    init(bytes: [UInt8]) { self.bytes = bytes[...] }
    init(slice: ArraySlice<UInt8>) { bytes = slice }

    var peekTag: UInt8? { bytes.first }

    /// The next element, or nil when it is missing, truncated or doesn't have `tag`.
    mutating func read(tag expected: UInt8? = nil) -> (tag: UInt8, contents: DERReader)? {
        var index = bytes.startIndex
        guard index < bytes.endIndex else { return nil }
        let tag = bytes[index]
        if let expected, tag != expected { return nil }
        index += 1
        guard index < bytes.endIndex else { return nil }
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), bytes.endIndex - index >= count else { return nil }
            length = bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
            index += count
        }
        guard bytes.endIndex - index >= length else { return nil }
        let contents = bytes[index..<index + length]
        bytes = bytes[(index + length)...]
        return (tag, DERReader(slice: contents))
    }
}

#if canImport(Security)
/// Records the outcome of the server trust evaluation and refuses redirects.
private final class TLSRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let warningPeriod: TimeInterval
    /// Whether to continue over a certificate that isn't trusted, so the HTTP check still says whether the
    /// server answers. Only done when no credentials are sent.
    private let acceptUntrusted: Bool
    private let lock = NSLock()
    private var recorded: CertificateCheck?

    init(warningPeriod: TimeInterval, acceptUntrusted: Bool) {
        self.warningPeriod = warningPeriod
        self.acceptUntrusted = acceptUntrusted
    }

    var certificate: CertificateCheck? { lock.withLock { recorded } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let result = CertificateCheck.evaluate(trust, warningPeriod: warningPeriod)
        lock.withLock { recorded = result }
        if case .invalid = result {
            if acceptUntrusted {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - DNS

public enum DNSResolver {
    /// The numeric addresses of `host`, through the system resolver.
    @Sendable public static func addresses(_ host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            // getaddrinfo blocks, so keep it off the cooperative thread pool.
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try lookup(host) })
            }
        }
    }

    private static func lookup(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, nil, &hints, &list)
        guard code == 0 else { throw BackendError(String(cString: gai_strerror(code))) }
        defer { freeaddrinfo(list) }

        var addresses: [String] = []
        var entry = list
        while let info = entry?.pointee {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if let address = info.ai_addr,
               getnameinfo(address, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !addresses.contains(text) { addresses.append(text) }
            }
            entry = info.ai_next
        }
        guard !addresses.isEmpty else { throw BackendError("no addresses found") }
        return addresses
    }
}
#endif
