import ArgumentParser
import Foundation
import RVDomain
import RVHooks

extension HookHost: ExpressibleByArgument {}

enum HookRun {
    static func run<C: HostCodec>(
        stdin: String,
        codec: C,
        evaluate: @Sendable (ShellCommand, String?) async -> EvaluationResult
    ) async -> HookWire {
        let request = codec.decode(stdin)
        guard let command = request.command else {
            return codec.encodeAllow()
        }
        let result = await evaluate(command, request.cwd)
        return hookWire(from: result, command: command, using: codec)
    }
}

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
        let client = ServiceClient()
        let outcome = await run(
            stdin: stdin,
            environment: ProcessInfo.processInfo.environment,
            evaluate: { command, cwd in
                await client.evaluateResult(command: command, cwd: cwd)
            }
        )
        FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        if !outcome.stderr.isEmpty {
            FileHandle.standardError.write(Data(outcome.stderr.utf8))
        }
        throw ExitCode(outcome.exitCode)
    }

    func run(
        stdin: String,
        environment _: [String: String],
        evaluate: @Sendable (ShellCommand, String?) async -> EvaluationResult
    ) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let wire: HookWire
        switch host {
        case .grok:
            wire = await HookRun.run(
                stdin: stdin,
                codec: GrokHostCodec(),
                evaluate: evaluate
            )
        case .pi:
            wire = await HookRun.run(
                stdin: stdin,
                codec: PiHostCodec(),
                evaluate: evaluate
            )
        case .opencode:
            wire = await HookRun.run(
                stdin: stdin,
                codec: OpenCodeHostCodec(),
                evaluate: evaluate
            )
        }
        return (wire.stdout, "", wire.exitCode)
    }
}
