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

        /// A generous deadline: a starved CI runner can take longer than
        /// `HookDeadline.budget` to evaluate, and a request past its
        /// deadline commits no block row and replies with a timeout deny.
        func run(
            _ stdin: String,
            host: HookHost = .claude,
            pending: (any PendingApprovalCoordinating)? = nil
        ) async throws -> HookEvaluateReply {
            let live = LiveEvaluateWorld(
                home: home,
                store: AllowOnceStore(baseDirectory: allowOnceDirectory),
                clock: { HookSessionLedgerTests.now },
                allowlist: { _, _ in .empty }
            )
            let world = HookEvaluateWorld.live(
                world: live, host: host, pending: pending, clock: { HookSessionLedgerTests.now })
            let reply = try await HookDoor.run(
                host: host, stdin: stdin, world: world, deadline: HookDeadline(budget: .seconds(600)))
            #expect(reply.stdout.contains(HookDoor.timeoutReason) == false)
            #expect(reply.stderr.contains(HookDoor.timeoutReason) == false)
            return reply

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

    private static func codexStdin(_ ids: [String: String]) throws -> String {
        var object: [String: Any] = [
            "hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": "/tmp/ws",
            "tool_input": ["command": "git reset --hard"],
        ]
        object.merge(ids) { _, new in new }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// An ask with no id to key an approval by records nothing, so the
    /// agent is told the ask went unrecorded, not to wait for a row.
    @Test func askWithoutAnyHostIDIsUnrecorded() async throws {
        let env = try Env()
        defer { env.tearDown() }
        let pending = FakePendingApprovals()
        let reply = try await env.run(Self.codexStdin([:]), host: .codex, pending: pending)
        #expect(await pending.createCalls.isEmpty)
        #expect(reply.stderr.contains("\nwho     ask "))
        #expect(reply.stderr.contains(approveInRVLine()) == false)
    }

    /// rvd without a pending store records nothing either: the agent is
    /// told the ask went unrecorded.
    @Test func askWithoutAPendingStoreIsUnrecorded() async throws {
        let env = try Env()
        defer { env.tearDown() }
        let reply = try await env.run(Self.codexStdin(["session_id": Self.session]), host: .codex, pending: nil)
        #expect(reply.stderr.contains("\nwho     ask "))
        #expect(reply.stderr.contains(approveInRVLine()) == false)
    }

    /// A Codex turn id keys the pending approval when there is no session
    /// id, but the block row carries no session.
    @Test func turnIDKeysTheApprovalButNotTheBlockRow() async throws {
        let env = try Env()
        defer { env.tearDown() }
        let pending = FakePendingApprovals()
        let reply = try await env.run(Self.codexStdin(["turn_id": "turn_main"]), host: .codex, pending: pending)
        let created = try #require(await pending.createCalls.first)
        #expect(created.identity.session == SessionID(validating: "turn_main"))
        #expect(reply.stderr.contains("\nwho     ask "))
        let block = try #require(env.blocks().last)
        #expect(block.session == nil)
    }
}
