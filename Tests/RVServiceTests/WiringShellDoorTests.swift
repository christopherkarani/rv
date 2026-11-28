import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

/// The shell door: hard links to wiring, and the observe floor holding a
/// wiring write however the path is spelled.
@Suite("Shell door: rv wiring")
struct WiringShellDoorTests {
    static func withRepo(_ body: (URL, HomeDirectory, WorkingDirectory) throws -> Void) throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-wiring-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raw) }
        let root = raw.resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try body(
            root, try #require(HomeDirectory(validating: root.path)),
            try #require(WorkingDirectory(rawValue: repo.path))
        )
    }

    static func decide(_ command: String, home: HomeDirectory, cwd: WorkingDirectory, mode: GuardMode) -> EvaluationResult {
        GatedEvaluate(EvaluateSession()).evaluateAgent(
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
            cwd: cwd, home: home, now: Date(),
            inputs: EvaluationInputs(
                guardMode: mode, judge: JudgeSelection(engine: .ft, bundle: nil, shadow: false), store: .gather(home: home, cwd: cwd)
            )
        )
    }

    static func isDeny(_ result: EvaluationResult) -> Bool {
        if case .deny = result.decision { return true }
        return false
    }

    @Test("a write through a hard link to a wiring file denies")
    func hardLinkWriteDenies() throws {
        try Self.withRepo { root, home, cwd in
            let wiring = root.appendingPathComponent(".claude/settings.json")
            try FileManager.default.createDirectory(
                at: wiring.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "{}".write(to: wiring, atomically: true, encoding: .utf8)
            try FileManager.default.linkItem(at: wiring, to: URL(fileURLWithPath: cwd.rawValue + "/innocent.json"))
            #expect(Self.isDeny(Self.decide("echo x > innocent.json", home: home, cwd: cwd, mode: .enforce)))
            #expect(Self.decide("echo x > other.json", home: home, cwd: cwd, mode: .enforce).decision == .allow)
        }
    }

    @Test("observe mode holds a wiring write however the path is spelled", arguments: [
        #"cp x "$HOME"/.claude/settings.json"#,
        #"cp x "${HOME}/.claude/settings.json""#,
        "cp x ~/a/../.claude/settings.json",
        "cp x ../.claude/./settings.json",
        "cp x app/.claude/settings.local.json",
        // systemd environment and drop-ins that reach rvd's unit.
        "cp x ../.config/environment.d/50-x.conf",
        "cp x ../.config/systemd/user.conf",
        "cp x ../.config/systemd/user/service.d/env.conf",
    ])
    func observeHoldsWiring(command: String) throws {
        try Self.withRepo { _, home, cwd in
            #expect(Self.isDeny(Self.decide(command, home: home, cwd: cwd, mode: .observe)), "\(command)")
        }
    }

    @Test("enforce mode denies a shell write into rvd's Core ML cache; listing it stays allowed", arguments: [
        "cp x ~/Library/Caches/rvd/com.apple.e5rt.e5bundlecache/b",
        "echo x > ../Library/Caches/rvd/planted",
        "ln -s /tmp/x ~/Library/Caches/rvd",
        "cp x ~/Library/Caches/rv-judge/com.apple.e5rt.e5bundlecache/b",
        "echo x > ../Library/Caches/rv-judge/planted",
        "ln -s /tmp/x ~/Library/Caches/rv-judge",
    ])
    func coreMLCacheWritesDeny(command: String) throws {
        try Self.withRepo { _, home, cwd in
            #expect(Self.isDeny(Self.decide(command, home: home, cwd: cwd, mode: .enforce)), "\(command)")
            #expect(Self.decide("ls ~/Library/Caches/rvd", home: home, cwd: cwd, mode: .enforce).decision == .allow)
            #expect(Self.decide("ls ~/Library/Caches/rv-judge", home: home, cwd: cwd, mode: .enforce).decision == .allow)
        }
    }

    @Test("observe mode still denies a shell write into a Core ML cache", arguments: [
        "cp x ~/Library/Caches/rv-judge/com.apple.e5rt.e5bundlecache/b",
        "ln -s /tmp/x ~/Library/Caches/rv-judge",
        "cp x ~/Library/Caches/rvd/com.apple.e5rt.e5bundlecache/b",
    ])
    func coreMLCacheWritesDenyInObserve(command: String) throws {
        try Self.withRepo { _, home, cwd in
            #expect(Self.isDeny(Self.decide(command, home: home, cwd: cwd, mode: .observe)), "\(command)")
        }
    }

    /// `~/Library/Caches` is now a proper ancestor of a wiring entry, so a
    /// mutation of the directory itself is a protected-path mutation even in
    /// observe mode; a sibling entry is not. (In enforce, out-of-repo writes
    /// already deny on other rules; `mv` and `rm -rf` of home paths are
    /// core.filesystem's either way.)
    @Test("~/Library/Caches itself is a protected ancestor; its other entries are not")
    func cachesAncestorIsProtected() throws {
        let mutation = RuleID(pack: PackID(rawValue: "builtin.action"), pattern: "protected-path-mutation")
        try Self.withRepo { _, home, cwd in
            let ancestor = Self.decide("chmod 777 ~/Library/Caches", home: home, cwd: cwd, mode: .observe).decision
            guard case .deny(let deny) = ancestor else {
                Issue.record("chmod of ~/Library/Caches: \(ancestor)")
                return
            }
            #expect(deny.ruleID == mutation)
            #expect(Self.isDeny(Self.decide("mv ~/Library/Caches /tmp/c", home: home, cwd: cwd, mode: .observe)))
            let sibling = Self.decide("chmod 700 ~/Library/Caches/rvdx", home: home, cwd: cwd, mode: .observe).decision
            if case .deny(let deny) = sibling { #expect(deny.ruleID != mutation, "\(deny.ruleID)") }
        }
    }
}
