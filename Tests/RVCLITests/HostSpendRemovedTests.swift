import Foundation
import Testing
import RVDomain
import RVHistory
import RVHooks
import RVPolicy
@testable import RVCLI

/// Step 8B: host-native spend is removed. A `hostAsk: "spend"` attestation
/// is caller-controlled bytes with no human proof, so it decodes as an
/// ordinary shell request and can never manufacture ALLOW.
struct HostSpendRemovedTests {
    private actor SeenCommand {
        var command: ShellCommand?
        func set(_ command: ShellCommand) { self.command = command }
    }
    private func spendStdin(host: HookHost, command: String) -> String {
        switch host {
        case .pi:
            return """
            {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"\(command)"},"hostAsk":"spend"}
            """
        case .opencode:
            return """
            {"tool":"bash","cwd":"/tmp/ws","args":{"command":"\(command)"},"hostAsk":"spend"}
            """
        case .claude:
            return """
            {"hook_event_name":"PreToolUse","cwd":"/tmp/ws","tool_name":"Bash","tool_input":{"command":"\(command)"},"hostAsk":"spend"}
            """
        case .openclaw:
            return """
            {"toolName":"exec","cwd":"/tmp/ws","params":{"command":"\(command)"},"hostAsk":"spend"}
            """
        case .hermes:
            return """
            {"toolName":"terminal","cwd":"/tmp/ws","args":{"command":"\(command)"},"hostAsk":"spend"}
            """
        case .grok, .codex, .cursor, .antigravity:
            return command
        }
    }

    @Test func spendStdin_decodesAsOrdinaryShellRequest() async throws {
        // The spend attestation is ignored: the request consults the
        // ordinary evaluate port with the decoded command.
        for host in [HookHost.pi, .opencode, .claude, .openclaw, .hermes] as [HookHost] {
            let stdin = spendStdin(host: host, command: "git reset --hard")
            let seen = SeenCommand()
            _ = await hookWire(
                host: host,
                stdin: stdin,
                world: hookWorld { command, _ in
                    await seen.set(command)
                    return EvaluationResult(outcome: .plain)
                }
            )
            #expect(await seen.command?.rawValue == "git reset --hard", "\(host)")
        }
    }

    @Test func spendStdin_neverAllowsDeniedCommand() async throws {
        let client = try isolatedClient(transport: nil)
        for host in [HookHost.pi, .opencode, .claude, .openclaw, .hermes] as [HookHost] {
            let stdin = spendStdin(host: host, command: "git reset --hard")
            let wire = await hookWire(
                host: host,
                stdin: stdin,
                world: hookWorld { command, cwd in
                    await client.evaluateResult(command: command, cwd: cwd)
                }
            )
            #expect(
                wire.stdout.isEmpty == false,
                "\(host) spend stdin must not allow a denied command"
            )
            #expect(wire.stdout.contains("\"permissionDecision\":\"ask\"") == false)
        }
    }

    @Test func spendStdin_honorsEvaluateAllowAsShell() async throws {
        // The shell path is intact: an allow verdict still allows, through
        // the ordinary evaluate port. There is no spend port anymore.
        for host in [HookHost.pi, .opencode, .claude, .openclaw, .hermes] as [HookHost] {
            let stdin = spendStdin(host: host, command: "git status")
            let wire = await hookWire(host: host, stdin: stdin, world: hookWorld { _, _ in
                EvaluationResult(outcome: .plain)
            })
            #expect(wire.exitCode == 0, "\(host)")
        }
    }

    @Test func replayAfterSpendDeny_staysDeny() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        let stdin = spendStdin(host: .pi, command: "git reset --hard")
        for _ in 0..<2 {
            let wire = await hookWire(
                host: .pi,
                stdin: stdin,
                world: hookWorld { command, cwd in
                    await client.evaluateResult(command: command, cwd: cwd)
                }
            )
            #expect(wire.stdout.isEmpty == false)
        }
        // No grant was planted: the store is untouched.
        let rows = await AllowOnceStore(baseDirectory: directory)
            .list(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(rows.isEmpty)
    }

    @Test func hookEvaluateSpendDeny_recordsHookHost() async throws {
        let home = try isolatedHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let client = ServiceClient(
            transport: nil,
            allowOnceDirectory: try isolatedAllowOnceDirectory(),
            home: home,
            clock: { now }
        )
        let stdin = """
        {"toolName":"bash","cwd":"\(home.rawValue)","input":{"command":"cat .env"},"hostAsk":"spend"}
        """
        // Step 8: with no service transport, hookEvaluate falls back to
        // a boundary deny without evaluating — nothing reaches the
        // ledger. (Hook-host ledger recording is pinned through the
        // gated door by DenialLedgerRecordTests.)
        let wire = await client.hookEvaluate(host: .pi, stdin: stdin)
        #expect(wire.stdout.contains("\"decision\":\"deny\""))
        let rows = DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .records(asOf: now)
        #expect(rows.isEmpty)
    }

    @Test func grokFirstCallDenyIsNotAllow() async throws {
        let client = try isolatedClient(transport: nil)
        let stdin = """
        {"hookEventName":"pre_tool_use","cwd":"/tmp/ws","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
        """
        let wire = await hookWire(host: .grok, stdin: stdin, world: hookWorld { command, cwd in
            await client.evaluateResult(command: command, cwd: cwd)
        })
        #expect(wire.stdout.isEmpty == false)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
    }

    @Test func piFirstCallAsk_encodesDenyWithoutCode() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let client = ServiceClient(
            transport: nil,
            allowOnceDirectory: directory,
            home: try isolatedHome(),
            clock: { now }
        )
        let stdin = """
        {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"}}
        """
        // No transport: boundary deny before any evaluation or mint.
        let wire = await client.hookEvaluate(host: .pi, stdin: stdin)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(allowOnceUnlockCode(in: wire.stdout) == nil)
        #expect((await AllowOnceStore(baseDirectory: directory).list(now: now)).isEmpty)
    }

    @Test func grokHookEvaluateLockFailureStaysDenyWithoutCode() async throws {
        let directory = try isolatedAllowOnceDirectory()
        let lock = RVPolicyPaths.allowOnceLockFile(inConfigDir: directory)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let client = ServiceClient(
            transport: nil,
            allowOnceDirectory: directory,
            home: try isolatedHome(),
            clock: { now }
        )
        let stdin = """
        {"hookEventName":"pre_tool_use","cwd":"/tmp/ws","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
        """
        let wire = await client.hookEvaluate(host: .grok, stdin: stdin)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(allowOnceUnlockCode(in: wire.stdout) == nil)
        #expect(json["next"] == nil)
    }
}
