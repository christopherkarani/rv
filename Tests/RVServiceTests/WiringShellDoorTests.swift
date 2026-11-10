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
                guardMode: mode, judge: JudgeSelection(engine: .ft, bundle: nil), store: .gather(home: home, cwd: cwd)
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
    ])
    func observeHoldsWiring(command: String) throws {
        try Self.withRepo { _, home, cwd in
            #expect(Self.isDeny(Self.decide(command, home: home, cwd: cwd, mode: .observe)), "\(command)")
        }
    }
}
