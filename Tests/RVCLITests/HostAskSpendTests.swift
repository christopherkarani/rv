import Foundation
import Testing
import RVDomain
import RVHooks
@testable import RVCLI

struct HostAskSpendTests {
    @Test func piSpendCallbackAllowsOnceThenReplayDenies() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        let stdin = """
        {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"},"hostAsk":"spend"}
        """
        let wire = await hookWire(
            host: .pi,
            stdin: stdin,
            evaluate: { command, cwd in
                await client.evaluateResult(command: command, cwd: cwd)
            },
            spendHostAsk: { command, cwd in
                await client.spendHostAsk(command: command, cwd: cwd)
            }
        )
        #expect(wire.stdout.isEmpty)
        #expect(wire.exitCode == 0)

        let replay = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny = replay.decision else {
            Issue.record("replay after host spend must deny")
            return
        }
    }

    @Test func piSpendWithoutCallbackStaysDeny() async throws {
        let stdin = """
        {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"},"hostAsk":"spend"}
        """
        let wire = await hookWire(host: .pi, stdin: stdin) { _, _ in
            EvaluationResult(outcome: .plain)
        }
        #expect(wire.stdout.isEmpty == false)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
    }

    @Test func grokFirstCallDenyIsNotAllow() async throws {
        let client = try isolatedClient(transport: nil)
        let stdin = """
        {"hookEventName":"pre_tool_use","cwd":"/tmp/ws","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
        """
        let wire = await hookWire(host: .grok, stdin: stdin) { command, cwd in
            await client.evaluateResult(command: command, cwd: cwd)
        }
        #expect(wire.stdout.isEmpty == false)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
    }
}
