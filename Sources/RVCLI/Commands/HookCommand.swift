import ArgumentParser
import Foundation
import RVDomain
import RVHooks
import RVPresentation

enum HookRun {
    static func run(
        stdin: String,
        host: HookHost = .grok,
        evaluate: (@Sendable (String) async -> EvaluationResult)? = nil
    ) async -> HookWire {
        let codec = GrokHostCodec()
        guard host == .grok else {
            return codec.encodeAllow()
        }
        let request = codec.decode(stdin)
        guard let command = request.command else {
            return codec.encodeAllow()
        }
        let result: EvaluationResult
        if let evaluate {
            result = await evaluate(command.rawValue)
        } else {
            result = await ServiceClient().evaluateResult(command: command.rawValue)
        }
        switch result.decision {
        case .allow:
            return codec.encodeAllow()
        case .deny, .indeterminate:
            return codec.encodeDeny(
                reason: hostDenyText(from: result, command: command) ?? incompleteEvalSentence
            )
        }
    }
}

struct Hook: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Evaluate a host shell hook on stdin."
    )

    @Option(name: .customLong("host"), help: "Host codec.")
    var hostName: String = "grok"

    func run() async throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let stdin = String(data: data, encoding: .utf8) ?? ""
        let host = HookHost(rawValue: hostName) ?? .grok
        let wire = await HookRun.run(stdin: stdin, host: host)
        FileHandle.standardOutput.write(Data(wire.stdout.utf8))
        throw ExitCode(wire.exitCode)
    }
}
