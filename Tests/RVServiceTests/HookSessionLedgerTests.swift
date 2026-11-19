import Foundation
import Testing
import RVDomain
import RVHistory
import RVHooks
import RVIPC
import RVPolicy
@testable import RVService

/// The host's session id rides from hook stdin through `HookDoor` and the
/// live world into the rows a deny writes: `blocks.jsonl` and `audit.jsonl`.
@Suite struct HookSessionLedgerTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let session = "0b7f3c2e-claude-session"

    private struct Env {
        let homeURL: URL
        let allowOnceDirectory: URL
        let home: HomeDirectory

        init() throws {
            homeURL = try isolatedHomeDirectory()
            allowOnceDirectory = try isolatedAllowOnceDirectory()
            home = try #require(HomeDirectory(validating: homeURL.path))
        }

        func run(_ stdin: String) async throws -> HookEvaluateReply {
            let live = LiveEvaluateWorld(
                home: home,
                store: AllowOnceStore(baseDirectory: allowOnceDirectory),
                clock: { HookSessionLedgerTests.now },
                allowlist: { _, _ in .empty }
            )
            let world = HookEvaluateWorld.live(
                world: live, host: .claude, pending: nil, clock: { HookSessionLedgerTests.now })
            return try await HookDoor.run(host: .claude, stdin: stdin, world: world)
        }

        func blocks() -> [DenialLedgerRecord] {
            DenialLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
                .records(asOf: HookSessionLedgerTests.now)
        }

        func auditLines() -> [String] {
            let file = RVPolicyPaths.configDirectory(home: home)
                .appendingPathComponent(AuditLedger.Source.audit.rawValue)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
    }

    private static func claudeStdin(tool: String, input: [String: String], session: String? = Self.session) throws
        -> String
    {
        var object: [String: Any] = [
            "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": input, "cwd": "/tmp/ws",
        ]
        if let session { object["session_id"] = session }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test func shellDenyRowsCarryTheHookSession() async throws {
        let env = try Env()
        defer { env.tearDown() }
        let reply = try await env.run(Self.claudeStdin(tool: "Bash", input: ["command": "git reset --hard"]))
        #expect(reply.stdout.contains("deny"))

        let block = try #require(env.blocks().last)
        #expect(block.session == Self.session)
        let audit = try #require(env.auditLines().last)
        #expect(audit.contains("\"command.denied\""))
        #expect(audit.contains("\"session\":\"\(Self.session)\""))
    }

    /// The file door (`decideFile`): a Write to rv's own hook wiring.
    @Test func fileDenyRowsCarryTheHookSession() async throws {
        let env = try Env()
        defer { env.tearDown() }
        let target = env.homeURL.appendingPathComponent(".claude/settings.json").path
        let reply = try await env.run(Self.claudeStdin(tool: "Write", input: ["file_path": target, "content": "{}"]))
        #expect(reply.stdout.contains("deny"))

        let block = try #require(env.blocks().last)
        #expect(block.session == Self.session)
        let audit = try #require(env.auditLines().last)
        #expect(audit.contains("\"session\":\"\(Self.session)\""))
    }

    @Test func noSessionIdMeansNoSessionKey() async throws {
        let env = try Env()
        defer { env.tearDown() }
        _ = try await env.run(Self.claudeStdin(tool: "Bash", input: ["command": "git reset --hard"], session: nil))
        let block = try #require(env.blocks().last)
        #expect(block.session == nil)
        #expect(env.auditLines().last?.contains("\"session\"") == false)
    }
}
