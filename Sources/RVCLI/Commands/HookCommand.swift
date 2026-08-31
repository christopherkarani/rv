import ArgumentParser
import Foundation
import RVDomain
import RVHooks

extension HookHost: ExpressibleByArgument {}

struct Hook: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Evaluate a host shell hook on stdin."
    )

    @Option(name: .customLong("host"), help: "Host codec.")
    var host: HookHost = .grok

    func run() async throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let stdin = String(data: data, encoding: .utf8) ?? ""
        let outcome = await run(stdin: stdin, client: ServiceClient())
        FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        if !outcome.stderr.isEmpty {
            FileHandle.standardError.write(Data(outcome.stderr.utf8))
        }
        throw ExitCode(outcome.exitCode)
    }

    func run(stdin: String, client: ServiceClient) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let wire = await client.hookEvaluate(host: host, stdin: stdin)
        return (wire.stdout, wire.stderr, wire.exitCode)
    }

    func run(
        stdin: String,
        evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
        spendHostAsk: (@Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult)? = nil
    ) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let wire = await hookWire(
            host: host,
            stdin: stdin,
            evaluate: evaluate,
            spendHostAsk: spendHostAsk
        )
        return (wire.stdout, wire.stderr, wire.exitCode)
    }
}
