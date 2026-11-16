import Vapor

struct Viewer: Authenticatable {}

/// One bounded budget for the single viewer account, independent of spoofable proxy headers.
actor LoginBudget {
    private var failures = 0
    private var inFlight = 0
    private var window = ContinuousClock.now

    func begin(now: ContinuousClock.Instant = .now) -> Bool {
        if window.duration(to: now) >= .seconds(60) { failures = 0; window = now }
        guard failures + inFlight < 10, inFlight < 8 else { return false }
        inFlight += 1
        return true
    }

    func finish(success: Bool) {
        inFlight -= 1
        if !success { failures += 1 }
    }
}

struct ViewerAuthenticator: AsyncBasicAuthenticator {
    let credentials: WebConfiguration.ViewerCredentials
    let budget = LoginBudget()

    func authenticate(basic: BasicAuthorization, for request: Request) async throws {
        guard await budget.begin() else {
            throw Abort(.tooManyRequests, headers: ["Retry-After": "60"])
        }
        let matches: Bool
        do {
            if !basic.password.isEmpty, basic.password.utf8.count <= 72 {
                matches = try await request.password.async.verify(basic.password, created: credentials.hash)
            } else { matches = false }
        } catch {
            await budget.finish(success: false)
            throw Abort(.unauthorized)
        }
        let success = matches && basic.username == credentials.username
        await budget.finish(success: success)
        if success { request.auth.login(Viewer()) }
    }
}
