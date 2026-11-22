import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

/// The hook-local evaluator: what it answers itself, what it hands to rvd,
/// and that every answer it gives is the reply rvd gives.
@Suite("Hook-local decider")
struct LocalHookDeciderTests {
    @Test func safeLaneShellAllowIsFinalAndMatchesRvd() async throws {
        let fixture = try LocalHookFixture()
        let stdin = claudeBash("ls -la", cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        let rvd = try await fixture.rvdReply(host: .claude, stdin: stdin)
        #expect(local == .final(rvd))
    }

    @Test func unlockablePackDenyEscalatesWithoutWriting() async throws {
        let fixture = try LocalHookFixture()
        let stdin = claudeBash("git reset --hard", cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        #expect(local == .escalate(.policyGate))
        #expect(fixture.configFileExists("audit.jsonl") == false)
        #expect(fixture.configFileExists("judge-log.jsonl") == false)
    }

    @Test func judgedCallEscalatesToTheJudge() async throws {
        let fixture = try LocalHookFixture(judgeBundle: true)
        // Pack-allowed, not safe-lane: the judge would score it.
        let stdin = claudeBash("python3 build.py --release", cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        #expect(local == .escalate(.judge))
        #expect(fixture.configFileExists("judge-log.jsonl") == false)
    }

    @Test func safeLaneStaysLocalWithAJudgeInstalled() async throws {
        let fixture = try LocalHookFixture(judgeBundle: true)
        let stdin = claudeBash("git status", cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        guard case .final(let reply) = local else {
            Issue.record("safe-lane call must be decided locally, got \(local)")
            return
        }
        #expect(reply.stdout.isEmpty)
        #expect(reply.exitCode == 0)
        // The safe-lane judge-log row rvd would have written.
        let log = try fixture.configFileText("judge-log.jsonl")
        #expect(log.contains("\"note\":\"safe-lane"))
    }

    @Test func fileToolSecretDenyIsFinalAuditedAndMatchesRvd() async throws {
        let fixture = try LocalHookFixture()
        let stdin = claudeFile("Read", path: fixture.workspace + "/.env", cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        guard case .final(let reply) = local else {
            Issue.record("file deny must be decided locally, got \(local)")
            return
        }
        #expect(reply.stdout.contains("\"permissionDecision\":\"deny\""))
        let audit = try fixture.configFileText("audit.jsonl")
        #expect(audit.contains("command.denied"))
        let rvd = try await LocalHookFixture().rvdReply(host: .claude, stdin: stdin)
        #expect(reply == rvd)
    }

    @Test func foreignToolIsTheSameAllow() async throws {
        let fixture = try LocalHookFixture()
        let stdin = #"{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/tmp","tool_name":"mcp__demo__tool","tool_input":{"name":"demo"}}"#
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        let rvd = try await fixture.rvdReply(host: .claude, stdin: stdin)
        #expect(local == .final(rvd))
    }

    @Test func malformedPayloadEscalates() async throws {
        let fixture = try LocalHookFixture()
        let local = await fixture.decider.decide(host: .claude, stdin: "{not json")
        #expect(local == .escalate(.malformed))
    }

    @Test func emptyFilePathEscalates() async throws {
        let fixture = try LocalHookFixture()
        let stdin = claudeFile("Write", path: "", cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        #expect(local == .escalate(.unexpected) || local == .escalate(.malformed))
    }

    /// An evaluator that cannot find or compile its packs never answers.
    @Test(arguments: [EvaluateSession.missingCore, EvaluateSession.uncompilableCore])
    func brokenPacksEscalate(_ session: EvaluateSession) async throws {
        let fixture = try LocalHookFixture()
        let decider = LocalHookDecider(home: fixture.home, clock: { Date() }, session: { session })
        let local = await decider.decide(host: .claude, stdin: claudeBash("ls", cwd: fixture.workspace))
        #expect(local == .escalate(.indeterminate))
    }

    @Test func unloadablePolicyNeverAllowsLocally() async throws {
        let fixture = try LocalHookFixture()
        let rv = URL(fileURLWithPath: fixture.workspace).appendingPathComponent(".rv", isDirectory: true)
        try FileManager.default.createDirectory(at: rv, withIntermediateDirectories: true)
        try Data("this is [not toml\n".utf8).write(to: rv.appendingPathComponent("policy.toml"))
        let stdin = claudeBash("ls", cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: stdin)
        let rvd = try await fixture.rvdReply(host: .claude, stdin: stdin)
        #expect(rvd.stdout.contains("\"permissionDecision\":\"deny\""))
        guard case .final(let reply) = local else { return }
        #expect(reply.stdout.contains("\"permissionDecision\":\"deny\""))
        #expect(reply == rvd)
    }

    /// The calls and observe configs the mode-flip test runs: each call is a
    /// final deny under enforce and an observed allow (which must escalate)
    /// under observe, through the file door and the shell door, with
    /// observe set globally or for this host only.
    enum ModeFlip: String, CaseIterable, Sendable {
        case fileGlobal, shellGlobal, shellHost

        /// A secret read is enforced in every mode, so the file door's
        /// observable deny is a host MCP config write while rv's gateway is
        /// in use (`MCPHostConfigDoor`).
        func stdin(home: HomeDirectory) -> String {
            switch self {
            case .fileGlobal: claudeFile("Write", path: home.rawValue + "/.cursor/mcp.json", cwd: "/tmp")
            case .shellGlobal, .shellHost: claudeBash("touch /etc/x", cwd: "/tmp")
            }
        }

        var observe: Data {
            switch self {
            case .fileGlobal, .shellGlobal: Data(#"{"guard":{"mode":"observe"}}"#.utf8)
            case .shellHost: Data(#"{"guard":{"mode":"enforce","hosts":{"claude":"observe"}}}"#.utf8)
            }
        }
    }

    /// A config.json flipping between enforce and observe must never get
    /// an observed would-be deny past the enforce comparison: the mode that
    /// decides the comparison is the one the evaluation itself read, not a
    /// separate read a writer can flip in between. (Before the fix about a
    /// third of the file-door decides came back a final allow.) Each run
    /// must also see the observe side at least once, so it cannot pass with
    /// the flip never landing.
    @Test(arguments: ModeFlip.allCases)
    func guardModeFlipsNeverFinalizeAnObservedDeny(_ flip: ModeFlip) async throws {
        let fixture = try LocalHookFixture(guardMode: "enforce")
        let configDirectory = RVPolicyPaths.configDirectory(home: fixture.home)
        try Data("{}".utf8).write(to: configDirectory.appendingPathComponent(MCPHostConfigPaths.gatewayConfigFileName))
        let stdin = flip.stdin(home: fixture.home)
        let enforced = await fixture.decider.decide(host: .claude, stdin: stdin)
        guard case .final(let deny) = enforced, deny.stdout.isEmpty == false else {
            Issue.record("expected a final enforce deny, got \(enforced)")
            return
        }

        let config = configDirectory.appendingPathComponent("config.json")
        let enforce = Data(#"{"guard":{"mode":"enforce"}}"#.utf8)
        let observe = flip.observe
        let stop = UnfairLock(false)
        let flipper = Thread {
            var toggle = false
            while stop.withLock({ $0 }) == false {
                try? (toggle ? observe : enforce).write(to: config, options: .atomic)
                toggle.toggle()
            }
        }
        flipper.start()
        defer { stop.withLock { $0 = true } }
        var observed = 0
        for _ in 0..<200 {
            let local = await fixture.decider.decide(host: .claude, stdin: stdin)
            if local == .escalate(.observe) {
                observed += 1
            } else if local != enforced {
                Issue.record("a mode flip let a would-be deny through: \(local)")
                return
            }
        }
        #expect(observed > 0, "the observe side of the flip never landed")
    }

    @Test func observeAllowIsFinalOnlyWhenEnforceAllowsToo() async throws {
        let fixture = try LocalHookFixture(guardMode: "observe")
        let allowed = claudeBash("ls", cwd: fixture.workspace)
        let local = await fixture.decider.decide(host: .claude, stdin: allowed)
        let rvd = try await fixture.rvdReply(host: .claude, stdin: allowed)
        #expect(local == .final(rvd))
        // rvd observes this deny into an allow, but its launch environment
        // may pin enforce: the would-be goes to rvd.
        let denied = claudeBash("git reset --hard", cwd: fixture.workspace)
        let observed = await fixture.decider.decide(host: .claude, stdin: denied)
        guard case .escalate = observed else {
            Issue.record("observe would-be deny must escalate, got \(observed)")
            return
        }
    }
}

/// The `rv-hook-local` process contract the C hook parses (local_eval.h).
@Suite("Hook-local command")
struct LocalHookCommandTests {
    static let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    @Test func acceptsOnlyTheExactArgv() {
        let good = ["--host", "claude", "--request-id", Self.id.uuidString]
        #expect(LocalHookCommand.parse(good) == .init(host: .claude, requestID: Self.id))
        #expect(LocalHookCommand.parse(good + ["--extra"]) == nil)
        #expect(LocalHookCommand.parse(["--host", "nope", "--request-id", Self.id.uuidString]) == nil)
        #expect(LocalHookCommand.parse(["--host", "claude", "--request-id", "x"]) == nil)
        #expect(LocalHookCommand.parse(["--request-id", Self.id.uuidString, "--host", "claude"]) == nil)
    }

    @Test func finalIsTheTaggedIPCReplyForThisRequest() async throws {
        let fixture = try LocalHookFixture()
        let stdin = claudeBash("ls", cwd: fixture.workspace)
        let out = await LocalHookCommand.respond(
            to: .init(host: .claude, requestID: Self.id), input: Data(stdin.utf8), home: fixture.home)
        let tag = Data(LocalHookCommand.finalTag.utf8)
        #expect(out.starts(with: tag))
        let response = try IPCJSON.decode(IPCResponse.self, from: out.dropFirst(tag.count))
        #expect(response.id == Self.id)
        guard case .hookEvaluate(let reply) = response.result else {
            Issue.record("expected a hookEvaluate result, got \(response.result)")
            return
        }
        #expect(reply == (try await fixture.rvdReply(host: .claude, stdin: stdin)))
    }

    @Test func escalationsAreOneTaggedLine() async throws {
        let fixture = try LocalHookFixture()
        let args = LocalHookCommand.Arguments(host: .claude, requestID: Self.id)
        let malformed = await LocalHookCommand.respond(to: args, input: Data("{".utf8), home: fixture.home)
        #expect(String(decoding: malformed, as: UTF8.self) == "rv-hook-local/1 escalate malformed\n")
        let notUTF8 = await LocalHookCommand.respond(to: args, input: Data([0xFF, 0xFE]), home: fixture.home)
        #expect(String(decoding: notUTF8, as: UTF8.self) == "rv-hook-local/1 escalate malformed\n")
        let noHome = await LocalHookCommand.respond(
            to: args, input: Data(claudeBash("ls", cwd: "/").utf8), home: nil)
        #expect(String(decoding: noHome, as: UTF8.self) == "rv-hook-local/1 escalate unexpected\n")
    }
}

// MARK: - Fixture

/// An isolated home and workspace, the local decider over it, and an rvd
/// runtime over the same home for the reply to compare against.
struct LocalHookFixture {
    let home: HomeDirectory
    let workspace: String
    let decider: LocalHookDecider

    init(judgeBundle: Bool = false, guardMode: String? = nil, repo: Bool = true) throws {
        let root = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: root.path))
        let workspace = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if repo {
            try FileManager.default.createDirectory(
                at: workspace.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true)
            try Data("ref: refs/heads/feature\n".utf8)
                .write(to: workspace.appendingPathComponent(".git/HEAD"))
        }
        let config = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        if let guardMode {
            try Data(#"{"guard":{"mode":"\#(guardMode)"}}"#.utf8)
                .write(to: config.appendingPathComponent("config.json"))
        }
        if judgeBundle {
            let bundle = config.appendingPathComponent("models/\(JudgeRuntime.ftBundleName)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: bundle.appendingPathComponent("model.mlpackage", isDirectory: true),
                withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: bundle.appendingPathComponent("tokenizer.json"))
        }
        self.home = home
        self.workspace = workspace.path
        self.decider = LocalHookDecider(home: home)
    }

    /// rvd's reply for the same call, from a fresh runtime over this home.
    func rvdReply(host: HookHost, stdin: String) async throws -> HookEvaluateReply {
        let runtime = hookTestRuntime(
            home: home, allowOnceDirectory: try isolatedAllowOnceDirectory())
        let response = await runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: host, stdin: stdin))),
            context: peerHookContext()
        )
        guard case .hookEvaluate(let reply) = response.result else {
            throw LocalHookFixtureError.noReply("\(response.result)")
        }
        return reply
    }

    func configFileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: RVPolicyPaths.configDirectory(home: home).appendingPathComponent(name).path)
    }

    func configFileText(_ name: String) throws -> String {
        try String(
            contentsOf: RVPolicyPaths.configDirectory(home: home).appendingPathComponent(name),
            encoding: .utf8)
    }
}

enum LocalHookFixtureError: Error {
    case noReply(String)
}

func claudeBash(_ command: String, cwd: String) -> String {
    claudePayload(tool: "Bash", input: ["command": command], cwd: cwd)
}

func claudeFile(_ tool: String, path: String, cwd: String) -> String {
    claudePayload(tool: tool, input: ["file_path": path], cwd: cwd)
}

func claudePayload(tool: String, input: [String: String], cwd: String) -> String {
    let object: [String: Any] = [
        "hook_event_name": "PreToolUse",
        "session_id": "local-hook-test",
        "cwd": cwd,
        "tool_name": tool,
        "tool_input": input,
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
