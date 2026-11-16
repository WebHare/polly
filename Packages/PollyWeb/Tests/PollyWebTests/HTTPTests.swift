/* swift test --package-path /absolute/path/to/polly/Packages/PollyWeb --filter HTTPTests */
import Foundation
import PollyKit
import Testing
import VaporTesting
@testable import PollyWeb

@Suite(.serialized)
struct HTTPTests {
    private func headers(password: String = "viewer-secret") -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.basicAuthorization = .init(username: "viewer", password: password)
        return headers
    }

    private func withWebApp(auth: Bool = true, body: (Application, WebMonitor, WebConfiguration) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "polly-http-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "polly.yaml")
        try "passwordStorage: file\nservers: []".write(to: file, atomically: true, encoding: .utf8)
        var environment = ["POLLY_CONFIG": file.path]
        if auth {
            let secret = directory.appending(path: "viewer.hash")
            try Bcrypt.hash("viewer-secret", cost: 10).write(to: secret, atomically: true, encoding: .utf8)
            environment["POLLY_VIEWER_USERNAME"] = "viewer"
            environment["POLLY_VIEWER_PASSWORD_HASH_FILE"] = secret.path
        }
        let config = try WebConfiguration(environment: environment)
        try await withApp { app in
            let monitor = try await configureWeb(app, configuration: config)
            try await body(app, monitor, config)
        }
    }

    @Test func authProtectsHTMLAPIAndHealth() async throws {
        try await withWebApp { app, monitor, _ in
            await monitor.start()
            for path in ["/", "/index.html", "/api/status", "/healthz"] {
                try await app.test(.GET, path) { response in
                    #expect(response.status == .unauthorized)
                    #expect(response.headers.first(name: .wwwAuthenticate) == "Basic realm=\"Polly\"")
                }
                try await app.test(.GET, path, headers: headers(password: "wrong")) { response in
                    #expect(response.status == .unauthorized)
                }
                try await app.test(.GET, path, headers: headers()) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers.first(name: .cacheControl) == "no-store")
                    #expect(response.headers.first(name: .accessControlAllowOrigin) == nil)
                    #expect(!response.body.string.contains("viewer-secret"))
                }
            }
        }
    }

    @Test func onlyDisplayDataIsReturnedAndReadsDoNotStartPolling() async throws {
        try await withWebApp { app, monitor, _ in
            for _ in 0..<3 {
                try await app.test(.GET, "/api/status", headers: headers()) { response in
                    #expect(response.status == .ok)
                    let snapshot = try response.content.decode(WebSnapshot.self)
                    #expect(snapshot.state == .empty)
                    for forbidden in ["password", "username", "baseURL", "Authorization"] {
                        #expect(!response.body.string.contains(forbidden))
                    }
                }
            }
            #expect(await monitor.isRunning == false)
        }
    }

    @Test func writesAndPrivatePathsAreUnavailable() async throws {
        try await withWebApp { app, _, _ in
            for method in [HTTPMethod.POST, .PUT, .PATCH, .DELETE] {
                try await app.test(method, "/api/status", headers: headers()) { response in
                    #expect(response.status == .methodNotAllowed)
                }
            }
            for path in ["/polly.yaml", "/viewer.hash", "/../polly.yaml", "/%2e%2e/viewer.hash", "/api/command", "/api/config"] {
                try await app.test(.GET, path, headers: headers()) { response in
                    #expect(response.status == .notFound)
                    #expect(!response.body.string.contains("passwordStorage"))
                }
            }
        }
    }

    @Test func repeatedFailedLoginsAreLimited() async throws {
        try await withWebApp { app, _, _ in
            for _ in 0..<10 {
                try await app.test(.GET, "/", headers: headers(password: "wrong")) { response in
                    #expect(response.status == .unauthorized)
                }
            }
            try await app.test(.GET, "/", headers: headers(password: "wrong")) { response in
                #expect(response.status == .tooManyRequests)
                #expect(response.headers.first(name: .retryAfter) != nil)
            }
        }
    }

    @Test func loginBudgetAllowsPageAssetsAndResetsAfterItsWindow() async {
        let budget = LoginBudget()
        for _ in 0..<8 { #expect(await budget.begin()) }
        #expect(await budget.begin() == false)
        for _ in 0..<8 { await budget.finish(success: true) }
        for _ in 0..<10 {
            #expect(await budget.begin())
            await budget.finish(success: false)
        }
        #expect(await budget.begin() == false)
        #expect(await budget.begin(now: .now + .seconds(61)))
        await budget.finish(success: true)
    }

    @Test func unsafeBindIsRejectedBeforeOpeningASocket() async throws {
        try await withWebApp(auth: false) { app, monitor, _ in
            await #expect(throws: WebConfigurationError.self) {
                try await app.server.start(address: .hostname("0.0.0.0", port: 0))
            }
            #expect(await monitor.isRunning == false)
            try await app.test(.GET, "/api/status") { response in #expect(response.status == .ok) }
        }
    }

    @Test func pollerHealthDetectsStallingAndShutdownIsAwaited() async throws {
        try await withWebApp(auth: false) { _, monitor, _ in
            #expect(await monitor.healthy() == false)
            await monitor.start()
            #expect(await monitor.healthy())
            #expect(await monitor.healthy(now: Date.now + 181) == false)
            await monitor.stop()
            #expect(await monitor.isRunning == false)
            #expect(await monitor.healthy() == false)
        }
    }

    @Test func portOnlyOverrideStillChecksTheConfiguredHost() async throws {
        try await withWebApp(auth: false) { app, _, _ in
            app.http.server.configuration.hostname = "0.0.0.0"
            await #expect(throws: WebConfigurationError.self) {
                try await app.server.start(address: .hostname(nil, port: 0))
            }
            await app.server.shutdown()
        }
    }
}
