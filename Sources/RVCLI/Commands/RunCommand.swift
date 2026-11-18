import ArgumentParser
import Foundation
import RVIsolation

/// `rv run -- COMMAND`: the command runs uncontained, with placeholders for
/// the selected secrets. The full help, with what this does and does not
/// protect, is `HelpCatalog.run`.
struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command with secrets as placeholders. Not a sandbox; see `rv help run`."
    )

    @Option(name: .customLong("secret"), help: "A secrets.json secret to stage as a placeholder (repeatable).")
    var secrets: [String] = []

    @Flag(help: "Stage every secret that can be a placeholder.")
    var all = false

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments, after --.")
    var command: [String] = []

    func validate() throws {
        if all, secrets.isEmpty == false { throw ValidationError("--all and --secret cannot be combined") }
    }

    func run() throws {
        let request = RunCommandRun.request(secrets: secrets, all: all, captured: command)
        let outcome = SecretRunContext.production(
            environment: ProcessInfo.processInfo.environment,
            directory: FileManager.default.currentDirectoryPath,
            notice: { RunCommandRun.writeStderr($0) }
        ).flatMap { SecretRun.execute(request, context: $0) }
        switch outcome {
        case .success(let code):
            throw ExitCode(code)
        case .failure(let refusal):
            RunCommandRun.writeStderr(RunCommandRun.refusalLine(refusal))
            throw ExitCode(refusal.exitCode)
        }
    }
}

enum RunCommandRun {
    /// ArgumentParser keeps a leading `--` in a passthrough capture.
    static func request(secrets: [String], all: Bool, captured: [String]) -> SecretRunRequest {
        let command = captured.first == "--" ? Array(captured.dropFirst()) : captured
        return SecretRunRequest(secrets: secrets, all: all, command: command)
    }

    static func refusalLine(_ refusal: SecretRunRefusal) -> String {
        "rv run: \(refusal.message)"
    }

    static func writeStderr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
