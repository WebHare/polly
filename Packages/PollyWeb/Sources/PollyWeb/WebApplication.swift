import Foundation
import Vapor

/// Registers the read-only surface. Configuration and secrets never enter a static-file directory.
@discardableResult
public func configureWeb(_ app: Application, configuration: WebConfiguration) async throws -> WebMonitor {
    let monitor = try await WebMonitor(configuration: configuration)
    app.logger.logLevel = .critical
    app.http.server.configuration.hostname = "127.0.0.1"
    app.http.server.configuration.port = 8088
    app.routes.defaultMaxBodySize = "1kb"
    app.middleware = .init()
    app.middleware.use(SafeHTTP())
    if let viewer = configuration.viewer {
        app.middleware.use(ViewerAuthenticator(credentials: viewer))
        app.middleware.use(Viewer.guardMiddleware(throwing: Abort(.unauthorized, headers: ["WWW-Authenticate": "Basic realm=\"Polly\""])))
    }
    app.middleware.use(try FileMiddleware(bundle: .module, publicDirectory: "Public"))
    let page = try Data(contentsOf: Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Public")!)
    let homepage: @Sendable (Request) -> Response = { _ in
        Response(status: .ok, headers: ["Content-Type": "text/html; charset=utf-8"], body: .init(data: page))
    }
    app.get(use: homepage)
    app.get("index.html", use: homepage)
    app.get("api", "status") { _ async throws -> Response in
        let snapshot = await monitor.snapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: try encoder.encode(snapshot)))
    }
    app.get("healthz") { _ async -> Response in
        let healthy = await monitor.healthy()
        return Response(status: healthy ? .ok : .serviceUnavailable,
                        headers: ["Content-Type": "application/json"], body: .init(string: healthy ? "{\"status\":\"ok\"}" : "{\"status\":\"unavailable\"}"))
    }
    app.servers.use { app in
        ValidatedServer(server: app.http.server.shared, configuration: configuration, monitor: monitor)
    }
    app.lifecycle.use(MonitorLifecycle(monitor: monitor))
    return monitor
}

private struct MonitorLifecycle: LifecycleHandler {
    let monitor: WebMonitor
    func shutdownAsync(_ application: Application) async { await monitor.stop() }
}

private struct ValidatedServer: Server {
    let server: HTTPServer
    let configuration: WebConfiguration
    let monitor: WebMonitor
    var onShutdown: EventLoopFuture<Void> { server.onShutdown }

    func start(address: BindAddress?) throws {
        throw WebConfigurationError(message: "Start Polly with the asynchronous server entry point.")
    }

    func start(address: BindAddress?) async throws {
        let resolved: BindAddress
        switch address {
        case .hostname(let host, let port):
            resolved = .hostname(host ?? server.configuration.hostname, port: port ?? server.configuration.port)
        case .some(let value): resolved = value
        case .none: resolved = server.configuration.address
        }
        try configuration.validate(address: resolved)
        try await server.start(address: resolved)
        await monitor.start()
        print("Polly web (Vapor 4.122.3) listening on \(server.configuration.hostname):\(server.configuration.port)")
    }

    func shutdown() { server.shutdown() }
    func shutdown() async { await monitor.stop(); await server.shutdown() }
}

private struct SafeHTTP: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response: Response
        do {
            guard request.method == .GET || request.method == .HEAD else {
                throw Abort(.methodNotAllowed, headers: ["Allow": "GET, HEAD"])
            }
            response = try await next.respond(to: request)
        } catch {
            let failure = error as? any AbortError
            let status = failure?.status ?? .internalServerError
            // Never serialize or log arbitrary errors; they can carry upstream URLs or credentials.
            response = Response(status: status, headers: failure?.headers ?? [:], body: .init(string: status.reasonPhrase))
        }
        // Vapor's MIME table omits WOFF2; nosniff must still allow our bundled fonts.
        if response.status == .ok && request.url.path.hasSuffix(".woff2") {
            response.headers.replaceOrAdd(name: .contentType, value: "font/woff2")
        }
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        response.headers.replaceOrAdd(name: "Content-Security-Policy", value: "default-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")
        return response
    }
}
