import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
@testable import RVService

/// While rv's MCP gateway is in use, agent writes to host MCP configs deny
/// on the file-tool door and the shell door; reads stay allowed, and with
/// no gateway nothing changes.
@Suite("MCP host config doors")
struct MCPHostConfigDoorTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A temporary home (symlinks resolved) with an optional gateway config
    /// and a git repository at `work/repo`.
    static func withHome(gateway: Bool, _ body: (URL, HomeDirectory) async throws -> Void) async throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-mcp-door-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raw) }
        let root = raw.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("work/repo/.git"), withIntermediateDirectories: true)
        if gateway { try touch(root.appendingPathComponent(".config/rv/mcp.json"), #"{"version":1,"servers":[]}"#) }
        let home = try #require(HomeDirectory(validating: root.path))
        try await ManagedGate.$override.withValue(ManagedPolicyState.none) {
            try await body(root, home)
        }
    }

    static func touch(_ url: URL, _ text: String = "{}") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func file(_ kind: FileToolKind, _ path: String, home: HomeDirectory, cwd: String? = nil) -> EvaluationResult {
        GatedEvaluate().decideFile(
            FileToolAction(kind: kind, path: FileToolPath(rawValue: path)),
            home: home, cwd: cwd.flatMap(WorkingDirectory.init(rawValue:)),
            host: .hook(.claude), now: now, guardMode: .enforce
        ).result
    }

    static func shell(_ command: String, home: HomeDirectory, cwd: String) async -> EvaluationResult {
        await GatedEvaluate().decide(
            .peek, EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
            cwd: wd(cwd), home: home, grants: EphemeralAllowOnceTable(), now: now,
            allowlist: { .empty }, host: .hook(.claude), tool: .bash,
            inputs: EvaluationInputs(
                guardMode: .enforce,
                judge: JudgeSelection(engine: .ft, bundle: nil),
                store: .gather(home: home, cwd: wd(cwd))
            )
        ).result
    }

    static func isMCPDeny(_ result: EvaluationResult) -> Bool {
        if case .deny(let deny) = result.decision { return deny.ruleID == MCPHostConfigPaths.ruleID }
        return false
    }

    private func bundle(_ mcp: ManagedPolicy.MCP) -> ManagedPolicyState {
        var policy = ManagedPolicy()
        policy.mcp = mcp
        return .active(ManagedPolicyBundle(policy: policy, sha256: "test", isSigned: true, directory: "/etc/rv/managed"))
    }

    @Test func gatewayIsInUseWhenConfiguredOrManaged() async throws {
        try await Self.withHome(gateway: false) { _, home in
            #expect(MCPHostConfigDoor.gatewayInUse(home: home, managed: .none) == false)
            #expect(MCPHostConfigDoor.gatewayInUse(home: home, managed: bundle(ManagedPolicy.MCP())) == false)
            var rules = ManagedPolicy.MCP()
            rules.blocked = ["evil-*"]
            #expect(MCPHostConfigDoor.gatewayInUse(home: home, managed: bundle(rules)))
            #expect(MCPHostConfigDoor.gatewayInUse(home: home, managed: .invalid("bad owner")))
            #expect(MCPHostConfigDoor.gatewayInUse(home: nil, managed: .none) == false)
        }
        try await Self.withHome(gateway: true) { _, home in
            #expect(MCPHostConfigDoor.gatewayInUse(home: home, managed: .none))
        }
    }

    @Test func fileDoorDeniesConfigWritesWhileTheGatewayIsInUse() async throws {
        try await Self.withHome(gateway: true) { root, home in
            let repo = root.path + "/work/repo"
            #expect(Self.isMCPDeny(Self.file(.write, root.path + "/.claude.json", home: home)))
            #expect(Self.isMCPDeny(Self.file(.edit, "~/.cursor/mcp.json", home: home)))
            #expect(Self.isMCPDeny(Self.file(.write, ".mcp.json", home: home, cwd: repo)))
            #expect(Self.isMCPDeny(Self.file(.edit, repo + "/.vscode/mcp.json", home: home)))
            #expect(Self.isMCPDeny(Self.file(.write, root.path + "/.claude/plugins/cache/m/p/1/.mcp.json", home: home)))
            #expect(Self.file(.read, root.path + "/.claude.json", home: home).decision == .allow)
            #expect(Self.file(.write, repo + "/claude.json", home: home).decision == .allow)
            #expect(Self.file(.write, repo + "/src/main.swift", home: home).decision == .allow)
        }
    }

    @Test func fileDoorFollowsADotfilesSymlink() async throws {
        try await Self.withHome(gateway: true) { root, home in
            let target = root.appendingPathComponent("dotfiles/claude.json")
            try Self.touch(target)
            try FileManager.default.createSymbolicLink(
                atPath: root.path + "/.claude.json", withDestinationPath: target.path)
            #expect(Self.isMCPDeny(Self.file(.edit, target.path, home: home)))
        }
    }

    @Test func fileDoorIsUnchangedWithoutAGateway() async throws {
        try await Self.withHome(gateway: false) { root, home in
            #expect(Self.file(.write, root.path + "/.claude.json", home: home).decision == .allow)
            #expect(Self.file(.write, ".mcp.json", home: home, cwd: root.path + "/work/repo").decision == .allow)
        }
    }

    @Test func shellDoorDeniesConfigWritesWhileTheGatewayIsInUse() async throws {
        try await Self.withHome(gateway: true) { root, home in
            let repo = root.path + "/work/repo"
            #expect(Self.isMCPDeny(await Self.shell("sed -i 's/a/b/' .mcp.json", home: home, cwd: repo)))
            #expect(Self.isMCPDeny(await Self.shell("echo '{}' > .cursor/mcp.json", home: home, cwd: repo)))
            #expect(Self.isMCPDeny(await Self.shell("claude mcp add evil -- evil-mcp", home: home, cwd: repo)))
            #expect(await Self.shell("cat .mcp.json", home: home, cwd: repo).decision == .allow)
        }
        try await Self.withHome(gateway: false) { root, home in
            let repo = root.path + "/work/repo"
            #expect(await Self.shell("sed -i 's/a/b/' .mcp.json", home: home, cwd: repo).decision == .allow)
        }
    }

    /// The guard is not an observe floor: observe measures it first. The
    /// agent is let through and the would-be verdict lands in the denial
    /// ledger `rv blocks` lists (ask on the shell door, deny on the file door).
    @Test func observeModeRecordsTheWouldBeRow() async throws {
        try await Self.withHome(gateway: true) { root, home in
            try Self.touch(
                RVPolicyPaths.configDirectory(home: home).appendingPathComponent("config.json"),
                #"{"guard":{"mode":"observe"}}"#)
            let repo = root.path + "/work/repo"
            let shell = await GatedEvaluate().apply(
                command: ShellCommand(rawValue: "sed -i 's/a/b/' .mcp.json"), cwd: wd(repo), home: home,
                grants: EphemeralAllowOnceTable(), now: Self.now, allowlist: { .empty }, host: .hook(.claude)
            )
            #expect(shell.decision == .allow)
            let file = GatedEvaluate().decideFile(
                FileToolAction(kind: .write, path: FileToolPath(rawValue: root.path + "/.claude.json")),
                home: home, cwd: nil, host: .hook(.claude), now: Self.now, guardMode: .observe
            )
            #expect(file.result.decision == .allow)
            let fileRows = file.effects.compactMap { effect -> GatedEffect.DenialRow? in
                if case .denialRow(let row) = effect { return row }
                return nil
            }
            #expect(fileRows.map(\.ruleID) == [MCPHostConfigPaths.ruleID])
            #expect(fileRows.allSatisfy { $0.observed && $0.wouldBe == .deny })
            let rows = ledgerRows(home).filter { $0.ruleID == MCPHostConfigPaths.ruleID }
            #expect(rows.count == 1)
            #expect(rows.first?.observed == true)
            #expect(rows.first?.wouldBe == .ask)
        }
    }
}
