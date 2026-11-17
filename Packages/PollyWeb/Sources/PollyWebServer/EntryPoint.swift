/* swift run --package-path /absolute/path/to/polly/Packages/PollyWeb polly-web */
import PollyWeb
import Foundation
import Vapor

@main
enum EntryPoint {
    static func main() async {
        do {
            if CommandLine.arguments.dropFirst().first == "hash-password" {
                guard CommandLine.arguments.count == 2 else {
                    throw WebConfigurationError(message: "hash-password accepts no arguments; provide the password on stdin.")
                }
                guard isatty(STDIN_FILENO) == 0 else {
                    throw WebConfigurationError(message: "Read the password securely and pipe it to hash-password on stdin.")
                }
                let data = try FileHandle.standardInput.read(upToCount: 1024) ?? Data()
                // Reaching the read limit is not proof of EOF; never hash a truncated password.
                guard data.count < 1024 else {
                    throw WebConfigurationError(message: "Password input is too long.")
                }
                guard let input = String(data: data, encoding: .utf8) else {
                    throw WebConfigurationError(message: "The password must be UTF-8 text.")
                }
                let password = input.trimmingCharacters(in: .newlines)
                guard (12...72).contains(password.utf8.count), !password.contains(where: { $0.isNewline }) else {
                    throw WebConfigurationError(message: "Use a password of 12 through 72 UTF-8 bytes without newlines.")
                }
                print(try Bcrypt.hash(password))
                return
            }
            let app = try await Application.make(Environment(name: "production", arguments: CommandLine.arguments))
            app.logger.logLevel = .critical
            do {
                if !CommandLine.arguments.contains("--help") && !CommandLine.arguments.contains("-h") {
                    try await configureWeb(app, configuration: WebConfiguration(environment: ProcessInfo.processInfo.environment))
                }
                try await app.execute()
            } catch {
                try? await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        } catch {
            let message = (error as? WebConfigurationError)?.message ?? "Could not start Polly web. Check the command options and listener configuration."
            FileHandle.standardError.write(Data("❌ \(message)\n".utf8))
            exit(1)
        }
    }
}
