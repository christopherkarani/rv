import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

/// The file-tool door denies Edit/Write (not Read) to rv's own wiring, and
/// to case-variant or symlinked spellings of secret paths whose leaf does
/// not exist yet.
@Suite("File door: rv wiring and path spellings")
struct WiringFileDoorTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func withHome(_ body: (URL, HomeDirectory) throws -> Void) throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-wiring-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raw) }
        let root = raw.resolvingSymlinksInPath()
        try body(root, try #require(HomeDirectory(validating: root.path)))
    }

    static func decide(
        _ kind: FileToolKind, _ path: String, home: HomeDirectory, cwd: String? = nil,
        mode: GuardMode = .enforce
    ) -> EvaluationResult {
        GatedEvaluate().decideFile(
            FileToolAction(kind: kind, path: FileToolPath(rawValue: path)),
            home: home, cwd: cwd.flatMap(WorkingDirectory.init(rawValue:)),
            host: .hook(.claude), now: now, guardMode: mode
        ).result
    }

    static func isWiringDeny(_ result: EvaluationResult) -> Bool {
        if case .deny(let deny) = result.decision { return deny.ruleID == RVWiringPaths.ruleID }
        return false
    }

    static func touch(_ url: URL, _ text: String = "{}") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("Edit/Write to wiring deny; Read stays allowed", arguments: [
        ".claude/settings.json", ".claude/hooks/rv-guard.py", ".cursor/hooks.json", ".codex/hooks.json",
        ".gemini/config/hooks.json", ".local/bin/rvd", ".local/bin/rv-cli", ".local/bin/rv",
        "Library/LaunchAgents/dev.rv.evaluate.plist", ".config/systemd/user/dev.rv.evaluate.service",
    ])
    func wiringWritesDeny(relative: String) throws {
        try Self.withHome { root, home in
            let absolute = root.path + "/" + relative
            #expect(Self.isWiringDeny(Self.decide(.write, absolute, home: home)), "\(relative)")
            #expect(Self.isWiringDeny(Self.decide(.edit, "~/" + relative, home: home)), "\(relative)")
            #expect(Self.decide(.read, absolute, home: home).decision == .allow, "\(relative)")
        }
    }

    @Test("observe mode still enforces a wiring write")
    func observeHoldsWiring() throws {
        try Self.withHome { root, home in
            let path = root.path + "/.claude/settings.json"
            #expect(Self.isWiringDeny(Self.decide(.write, path, home: home, mode: .observe)))
        }
    }

    @Test("case variants, relative spellings and symlinked dirs reach wiring")
    func spellingsReachWiring() throws {
        try Self.withHome { root, home in
            try Self.touch(root.appendingPathComponent(".claude/settings.json"))
            try FileManager.default.createSymbolicLink(
                atPath: root.path + "/cl", withDestinationPath: root.path + "/.claude")
            #if canImport(Darwin)
            #expect(Self.isWiringDeny(Self.decide(.write, root.path + "/.CLAUDE/settings.json", home: home)))
            #endif
            #expect(Self.isWiringDeny(Self.decide(.edit, root.path + "/cl/settings.json", home: home)))
            #expect(Self.isWiringDeny(Self.decide(.write, ".claude/settings.json", home: home, cwd: root.path)))
            #expect(Self.isWiringDeny(Self.decide(.write, "x/../.claude/settings.json", home: home, cwd: root.path)))
        }
    }

    @Test("a dotfiles target of a symlinked wiring file is wiring")
    func dotfilesTargetIsWiring() throws {
        try Self.withHome { root, home in
            let target = root.appendingPathComponent("dotfiles/claude-settings.json")
            try Self.touch(target)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: root.path + "/.claude/settings.json", withDestinationPath: target.path)
            #expect(Self.isWiringDeny(Self.decide(.write, target.path, home: home)))
        }
    }

    @Test("project host files are guarded only when rv's hook is wired there")
    func projectHostFiles() throws {
        try Self.withHome { root, home in
            let plain = root.appendingPathComponent("src/app/.claude/settings.json")
            try Self.touch(plain, #"{"permissions":{"allow":["Bash(ls)"]}}"#)
            #expect(Self.decide(.write, plain.path, home: home).decision == .allow)
            let wired = root.appendingPathComponent("src/other/.claude/settings.local.json")
            try Self.touch(wired, #"{"hooks":{"PreToolUse":[{"hooks":[{"command":"python3 /x/rv-guard.py"}]}]}}"#)
            #expect(Self.isWiringDeny(Self.decide(.edit, wired.path, home: home)))
        }
    }

    @Test("ordinary files stay allowed")
    func ordinaryAllowed() throws {
        try Self.withHome { root, home in
            for path in ["/src/app/main.swift", "/.claude/CLAUDE.md", "/.local/bin/node",
                         "/Library/LaunchAgents/com.example.plist"] {
                #expect(Self.decide(.write, root.path + path, home: home).decision == .allow, "\(path)")
            }
        }
    }

    @Test("Write to a case variant of a not-yet-existing secret file denies")
    func caseVariantSecretWrite() throws {
        #if canImport(Darwin)
        try Self.withHome { root, home in
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
            let result = Self.decide(.write, root.path + "/.SSH/authorized_keys", home: home)
            guard case .deny(let deny) = result.decision else {
                Issue.record("~/.SSH/authorized_keys must deny, got \(result.decision)")
                return
            }
            #expect(deny.ruleID.pack == .coreSecrets)
            #expect(Self.decide(.write, "~/.SSH/authorized_keys", home: home).decision != .allow)
        }
        #endif
    }

    @Test("Write through a symlinked dir to a missing secret leaf denies")
    func symlinkedMissingLeafDenies() throws {
        try Self.withHome { root, home in
            let ssh = root.appendingPathComponent(".ssh")
            try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: root.path + "/keys", withDestinationPath: ssh.path)
            let result = Self.decide(.write, root.path + "/keys/authorized_keys", home: home)
            guard case .deny = result.decision else {
                Issue.record("symlinked ~/.ssh with a missing leaf must deny, got \(result.decision)")
                return
            }
        }
    }
}
