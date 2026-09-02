import Foundation
import Testing
import RVDomain
import RVHooks
@testable import RVCLI

struct HostAskSpendTests {
    @Test func piSpendThroughHookEvaluateAllowsOnceThenReplayDenies() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        let stdin = """
        {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"},"hostAsk":"spend"}
        """
        let wire = await client.hookEvaluate(host: .pi, stdin: stdin)
        #expect(wire.stdout.isEmpty)
        #expect(wire.exitCode == 0)

        let replay = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny = replay.decision else {
            Issue.record("replay after production hookEvaluate spend must deny")
            return
        }
    }

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

    @Test func openCodeSessionShellSpendCallbackAllowsOnceThenReplayDenies() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        let stdin = """
        {"tool":"session.shell","cwd":"/tmp/ws","args":{"command":"git reset --hard"},"hostAsk":"spend"}
        """
        let firstCall = """
        {"tool":"session.shell","cwd":"/tmp/ws","args":{"command":"git reset --hard"}}
        """
        let firstWire = await hookWire(host: .opencode, stdin: firstCall) { command, cwd in
            await client.evaluateResult(command: command, cwd: cwd)
        }
        #expect(firstWire.stdout.isEmpty == false)
        #expect(firstWire.stdout.contains("\"decision\":\"ask\""))
        #expect(firstWire.stdout.contains("\"decision\":\"allow\"") == false)

        let wire = await hookWire(
            host: .opencode,
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
            Issue.record("replay after session.shell host spend must deny")
            return
        }
    }

    @Test func openCodeSpendCallbackAllowsOnceThenReplayDenies() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        let stdin = """
        {"tool":"bash","cwd":"/tmp/ws","args":{"command":"git reset --hard"},"hostAsk":"spend"}
        """
        let wire = await hookWire(
            host: .opencode,
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
            Issue.record("replay after OpenCode host spend must deny")
            return
        }
    }

    @Test func claudeSpendCallbackAllowsOnceThenReplayDenies() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        let stdin = """
        {"hook_event_name":"PreToolUse","cwd":"/tmp/ws","tool_name":"Bash","tool_input":{"command":"git reset --hard"},"hostAsk":"spend"}
        """
        let wire = await hookWire(
            host: .claude,
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
        #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)

        let replay = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny = replay.decision else {
            Issue.record("replay after Claude host spend must deny")
            return
        }
    }

    @Test func openCodeSpendWithoutCallbackStaysDeny() async throws {
        let stdin = """
        {"tool":"bash","cwd":"/tmp/ws","args":{"command":"git reset --hard"},"hostAsk":"spend"}
        """
        let wire = await hookWire(host: .opencode, stdin: stdin) { _, _ in
            EvaluationResult(outcome: .plain)
        }
        #expect(wire.stdout.isEmpty == false)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
    }

    @Test func claudeSpendWithoutCallbackStaysDeny() async throws {
        let stdin = """
        {"hook_event_name":"PreToolUse","cwd":"/tmp/ws","tool_name":"Bash","tool_input":{"command":"git reset --hard"},"hostAsk":"spend"}
        """
        let wire = await hookWire(host: .claude, stdin: stdin) { _, _ in
            EvaluationResult(outcome: .plain)
        }
        #expect(wire.stdout.isEmpty == false)
        #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
        #expect(wire.stdout.contains("\"permissionDecision\":\"deny\""))
    }

    @Test func hermesSpendCallbackAllowsOnceThenReplayDenies() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        let stdin = """
        {"toolName":"terminal","cwd":"/tmp/ws","args":{"command":"git reset --hard"},"hostAsk":"spend"}
        """
        let wire = await hookWire(
            host: .hermes,
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
            Issue.record("replay after Hermes host spend must deny")
            return
        }
    }

    @Test func claudePermissionRequestSpendAllowsOnceThenReplayDenies() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        let stdin = """
        {"hook_event_name":"PermissionRequest","cwd":"/tmp/ws","tool_name":"Bash","tool_input":{"command":"git reset --hard"}}
        """
        let wire = await hookWire(
            host: .claude,
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
        #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)

        let replay = await client.evaluateResult(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        guard case .deny = replay.decision else {
            Issue.record("replay after Claude PermissionRequest spend must deny")
            return
        }
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

    @Test func grokSpendCallbackDoesNotAllow() async throws {
        let client = try isolatedClient(transport: nil)
        let stdin = """
        {"hookEventName":"pre_tool_use","cwd":"/tmp/ws","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"},"hostAsk":"spend"}
        """
        let wire = await hookWire(
            host: .grok,
            stdin: stdin,
            evaluate: { command, cwd in
                await client.evaluateResult(command: command, cwd: cwd)
            },
            spendHostAsk: { command, cwd in
                await client.spendHostAsk(command: command, cwd: cwd)
            }
        )
        #expect(wire.stdout.isEmpty == false)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
    }
}
