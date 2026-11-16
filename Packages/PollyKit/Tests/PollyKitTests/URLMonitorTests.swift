import Foundation
import Security
import Testing
@testable import PollyKit

/// Self-signed certificates made with `openssl req -x509`: one with a UTCTime and one with a GeneralizedTime
/// `notAfter` (dates from 2050 on).
private let utcTimeCertificate = Data(base64Encoded: "MIIBXzCCAQSgAwIBAgIUIhinN+nP6P6mOJsbqXrnWE8gBa4wCgYIKoZIzj0EAwIwFTETMBEGA1UEAwwKcG9sbHkudGVzdDAeFw0yNjExMTQyMzExMjNaFw0yNjExMTUyMzExMjNaMBUxEzARBgNVBAMMCnBvbGx5LnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQRztwN0tnGy/m/rXIvO8kKPB0gjtMaJhD/k0vaEI3nlu2qZPNXOAwTTtOBkFK/izLvvVyhJl7+i1qRuwDxckqqozIwMDAdBgNVHQ4EFgQUOspHe+BXLHeZ0WT2W0iE2SoOeccwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEA9Z5RzT8bitWbB6Ys7XpuvGT6ki84ulSHw6G0jVXoeucCIQCxoU7yjuH1CEUL5nqRmrFypWCt5LtdRnbQ6NucFZwrtw==")!
private let generalizedTimeCertificate = Data(base64Encoded: "MIIBYDCCAQagAwIBAgIUVGzne/jWs4YXUnDPANHOrQCfkEowCgYIKoZIzj0EAwIwFTETMBEGA1UEAwwKcG9sbHkudGVzdDAgFw0yNjExMTQyMzExMjNaGA8yMDU0MDQwMTIzMTEyM1owFTETMBEGA1UEAwwKcG9sbHkudGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABCyC+l2+YwENGU3P901GIxUoI/QENXO+DYuMyYtLm4KauOy2BuA5yCQexavTgSKXyssHB9KDUMvVBlGEvkPQZA+jMjAwMB0GA1UdDgQWBBQfpX85g2WgmMxltKRnyfA2QfmByjAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQDypNHQUbXFvSMzGcO28dTO+pZe0q2jDrEBq6t2DkHkzgIgCJW/Nw70AaQTkpmRzfxsQ5KQw7Znal3dz44ckn1o0eA=")!

private func utc(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

struct CertificateTests {
    @Test func readsNotAfterFromBothTimeFormats() {
        #expect(CertificateDates.notAfter(utcTimeCertificate) == utc("2026-11-15T23:11:23Z"))
        #expect(CertificateDates.notAfter(generalizedTimeCertificate) == utc("2054-04-01T23:11:23Z"))
    }

    @Test func rejectsMalformedCertificates() {
        #expect(CertificateDates.notAfter(Data()) == nil)
        #expect(CertificateDates.notAfter(utcTimeCertificate.prefix(100)) == nil)
        #expect(CertificateDates.notAfter(Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])) == nil)
        #expect(CertificateDates.time(tag: 0x17, "261315000000Z") == nil) // month 13
        #expect(CertificateDates.time(tag: 0x17, "2611150000Z") == nil)
        #expect(CertificateDates.time(tag: 0x17, "491231235959Z") == utc("2049-12-31T23:59:59Z"))
        #expect(CertificateDates.time(tag: 0x17, "500101000000Z") == utc("1950-01-01T00:00:00Z"))
    }

    @Test func warnsForTheFirstCertificateToExpire() {
        let now = utc("2026-11-01T00:00:00Z")
        let soon = utc("2026-11-10T00:00:00Z"), later = utc("2027-06-01T00:00:00Z")
        #expect(CertificateCheck.expiry(of: [later, soon], warningPeriod: 14 * 86400, now: now) == .expiring(soon))
        #expect(CertificateCheck.expiry(of: [later], warningPeriod: 14 * 86400, now: now) == .valid)
        #expect(CertificateCheck.expiry(of: [], warningPeriod: 14 * 86400, now: now) == .valid)
    }

    @Test func untrustedCertificateIsInvalid() throws {
        let certificate = try #require(SecCertificateCreateWithData(nil, utcTimeCertificate as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "polly.test" as CFString), &trust) == errSecSuccess)
        guard case .invalid = CertificateCheck.evaluate(try #require(trust), warningPeriod: 0) else {
            Issue.record("A self-signed certificate must not be trusted")
            return
        }
    }
}

struct URLKindTests {
    @Test func keepsPathAndQueryOfAURLToCheck() throws {
        let parsed = try #require(ServerURLParser.parse("https://bob:pw@www.example.com/nagios/health?full=1#top", keepPath: true))
        #expect(parsed.baseURL.absoluteString == "https://www.example.com/nagios/health?full=1")
        #expect(parsed.username == "bob")
    }

    @MainActor @Test func addFormForAURL() throws {
        let model = ServerFormModel(kind: .url)
        model.urlText = "www.example.com/status"
        let server = try #require(model.makeServer())
        #expect(server.kind == .url)
        #expect(server.baseURL.absoluteString == "https://www.example.com/status")
        #expect(server.name == "www.example.com")
        #expect(server.makeBackend(password: nil) is URLMonitor)
    }

    @Test func roundTripsInSettingsFile() throws {
        let server = NagiosServer(name: "Site", baseURL: URL(string: "https://www.example.com/?a=b")!, username: "", kind: .url)
        let settings = PollySettings(servers: [.init(server: server)])
        let yaml = SettingsFile.render(settings)
        #expect(yaml.contains("type: url"))
        #expect(try SettingsFile.parse(yaml) == settings)
    }

    @Test func statusCountsOneHostWithAServicePerCheck() {
        let now = Date()
        let healthy = URLMonitor.status(host: "web", results: [("DNS", .ok("")), ("HTTP", .ok("")), ("Certificate", .ok(""))],
                                        checkedAt: now)
        #expect(healthy.hosts == HostCounts(up: 1))
        #expect(healthy.services == ServiceCounts(ok: 3))
        #expect(healthy.severity == .ok)

        let expiring = URLMonitor.status(host: "web", results: [("DNS", .ok("")), ("HTTP", .ok("")),
                                                                ("Certificate", .problem(.warning, "expires"))], checkedAt: now)
        #expect(expiring.hosts == HostCounts(up: 1))
        #expect(expiring.severity == .warning)
        #expect(expiring.problems.map(\.id) == ["web/Certificate"])

        let unresolved = URLMonitor.status(host: "web", results: [("DNS", .problem(.critical, "no")), ("HTTP", .skipped),
                                                                  ("Certificate", .skipped)], checkedAt: now)
        #expect(unresolved.hosts == HostCounts(down: 1))
        #expect(unresolved.services == ServiceCounts(critical: 1, pending: 2))
        #expect(unresolved.problems.map(\.service) == ["DNS"])
    }

    @Test func httpStatusCodes() {
        // The timing is formatted for the user's locale.
        let timing = 0.1.formatted(.number.precision(.fractionLength(2)))
        #expect(URLMonitor.httpResult(statusCode: 200, seconds: 0.1) == .ok("HTTP 200 in \(timing) s"))
        #expect(URLMonitor.httpResult(statusCode: 302, seconds: 0.1) == .ok("HTTP 302 in \(timing) s"))
        guard case .problem(.critical, _) = URLMonitor.httpResult(statusCode: 503, seconds: 0.1) else {
            Issue.record("503 must be critical")
            return
        }
    }
}

/// Uses the shared `StubProtocol` handler, so it runs in the serialized `TransportTests` suite.
extension TransportTests {
    private func urlMonitor(_ url: String, password: String? = nil,
                            resolve: @escaping @Sendable (String) async throws -> [String] = { _ in ["192.0.2.1"] }) -> URLMonitor {
        var monitor = URLMonitor(url: URL(string: url)!, username: password == nil ? "" : "bob", password: password,
                                 session: StubProtocol.session())
        monitor.resolve = resolve
        return monitor
    }

    @Test func urlMonitorReportsAHealthySite() async throws {
        let requests = Box<[URLRequest]>([])
        StubProtocol.handler = { requests.value.append($0); return .init(body: "<html>hi</html>") }
        defer { StubProtocol.handler = nil }

        let status = try await urlMonitor("http://www.example.com/health?x=1").fetchStatus()
        #expect(status.problems.isEmpty)
        #expect(status.hosts == HostCounts(up: 1))
        #expect(status.services == ServiceCounts(ok: 2)) // no certificate check over http
        #expect(requests.value.map { $0.url?.absoluteString } == ["http://www.example.com/health?x=1"])
        #expect(requests.value[0].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func urlMonitorReportsServerErrorsAndSendsCredentials() async throws {
        let requests = Box<[URLRequest]>([])
        StubProtocol.handler = { requests.value.append($0); return .init(status: 503) }
        defer { StubProtocol.handler = nil }

        let monitor = urlMonitor("http://www.example.com/", password: "pw")
        let status = try await monitor.fetchStatus()
        #expect(status.hosts == HostCounts(down: 1))
        #expect(status.problems.map(\.id) == ["www.example.com/HTTP"])
        #expect(status.problems[0].output.hasPrefix("HTTP 503"))
        #expect(requests.value[0].value(forHTTPHeaderField: "Authorization") == "Basic Ym9iOnB3")
        await #expect(throws: BackendError.self) { try await monitor.testConnection() }
    }

    @Test func urlMonitorDoesNotFollowRedirects() async throws {
        let requests = Box<[URLRequest]>([])
        StubProtocol.handler = { requests.value.append($0); return .init(redirectTo: URL(string: "http://elsewhere.test/")!) }
        defer { StubProtocol.handler = nil }

        let status = try await urlMonitor("http://www.example.com/").fetchStatus()
        #expect(status.problems.isEmpty)
        #expect(requests.value.count == 1)
    }

    @Test func urlMonitorSkipsTheRestWhenDNSFails() async throws {
        let requests = Box<[URLRequest]>([])
        StubProtocol.handler = { requests.value.append($0); return .init() }
        defer { StubProtocol.handler = nil }

        let status = try await urlMonitor("https://nowhere.test/") { _ in throw BackendError("not found") }.fetchStatus()
        #expect(status.problems.map(\.service) == ["DNS"])
        #expect(status.services == ServiceCounts(critical: 1, pending: 2))
        #expect(requests.value.isEmpty)
    }
}

/// Real lookups of names that need no DNS server: a literal address, and the reserved `.invalid` domain.
struct DNSResolverTests {
    @Test func resolvesLiteralAddressesWithoutANetwork() async throws {
        #expect(try await DNSResolver.addresses("127.0.0.1") == ["127.0.0.1"])
        #expect(try await DNSResolver.addresses("::1") == ["::1"])
    }

    @Test func failsForAnInvalidName() async {
        await #expect(throws: BackendError.self) { try await DNSResolver.addresses("polly-does-not-exist.invalid") }
    }
}

/// Real websites, including badssl.com's broken certificates. Skipped unless `POLLY_NETWORK_TESTS` is set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["POLLY_NETWORK_TESTS"] != nil))
struct URLMonitorNetworkTests {
    private func problems(_ url: String) async throws -> [String: Severity] {
        let status = try await URLMonitor(url: URL(string: url)!).fetchStatus()
        return Dictionary(uniqueKeysWithValues: status.problems.map { ($0.service, $0.severity) })
    }

    @Test func healthySite() async throws {
        #expect(try await problems("https://www.example.com/") == [:])
    }

    @Test func readsTheExpiryOfARealChain() async throws {
        var monitor = URLMonitor(url: URL(string: "https://www.example.com/")!)
        monitor.certificateWarningPeriod = 5 * 365 * 86400 // longer than any certificate may last
        let problem = try #require(try await monitor.fetchStatus().problems.first)
        #expect(problem.service == "Certificate")
        #expect(problem.severity == .warning)
        #expect(problem.output.hasPrefix("The certificate expires in "))
    }

    @Test func brokenCertificatesStillShowWhetherTheServerAnswers() async throws {
        #expect(try await problems("https://expired.badssl.com/") == ["Certificate": .critical])
        #expect(try await problems("https://self-signed.badssl.com/") == ["Certificate": .critical])
        #expect(try await problems("https://wrong.host.badssl.com/") == ["Certificate": .critical])
    }

    @Test func unresolvableHost() async throws {
        #expect(try await problems("https://polly-does-not-exist.invalid/") == ["DNS": .critical])
    }
}
