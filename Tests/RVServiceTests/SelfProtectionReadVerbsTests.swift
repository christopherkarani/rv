import Foundation
import RVDomain
import RVHooks
import RVPolicy
@testable import RVService
import Testing

/// B2 / S3: rv's read-only verbs are free of the judge; write verbs are
/// not; and every safer command a self-protection stop offers evaluates to
/// allow in the same mode.
struct SelfProtectionReadVerbsTests {
    @Test(arguments: [
        "rv", "rv status", "rv doctor", "rv doctor --json", "rv blocks", "rv log --all --rule core.git:reset-hard",
        "rv log -n 20 --host claude", "rv why a7c-835", "rv explain \"git reset --hard\"", "rv box list",
        "rv service status", "rv policy status --json", "rv uninstall --help", "rv secrets set --help",
        "rv --help", "rv help secrets", "rv --version",
    ])
    func readOnlyVerbs_enterTheSafeLane(_ command: String) {
        #expect(SafeCommandLane.isSafe(command), "\(command)")
    }

    @Test(arguments: [
        "rv uninstall", "rv secrets set K", "rv secrets remove K", "rv setup --observe", "rv host mode claude observe",
        "rv allow-once abc123", "rv doctor --fix", "rv log --clear", "rv box claude", "rv box list --rm",
        "rv secrets set K --help --force", "rv a b c --help", "rv doctor; rv uninstall", "rv why $(rv uninstall)",
        "/tmp/rv doctor", "rv service restart", "rv policy apply",
    ])
    func writeVerbsAndOtherFlags_stayOut(_ command: String) {
        #expect(SafeCommandLane.isSafe(command) == false, "\(command)")
    }

    /// Acceptance: the safer command each stop offers is allowed, in the
    /// mode that stopped it.
    @Test(arguments: ["enforce", "observe"], [
        ("rv uninstall", "rv uninstall --help"),
        ("rv secrets set STRIPE_KEY", "rv secrets set --help"),
        ("rv host mode claude observe", "rv host mode --help"),
        ("rv setup --observe", "rv setup --help"),
    ])
    func saferCommand_evaluatesToAllowInTheSameMode(_ mode: String, _ pair: (String, String)) async throws {
        let (home, cwd) = try Self.fixture(mode: mode)
        let stopped = await Self.peek(pair.0, home: home, cwd: cwd)
        #expect(stopped.decision == .indeterminate(.selfProtection), "\(pair.0) in \(mode)")
        let text = try #require(hostDenyText(from: stopped, command: ShellCommand(rawValue: pair.0)))
        #expect(text.contains("\nsafer   \(pair.1)\n"))
        let safer = await Self.peek(pair.1, home: home, cwd: cwd)
        #expect(safer.decision == .allow, "\(pair.1) in \(mode)")
    }

    /// S3: the rv config read stop points at `rv secrets list`, which is
    /// allowed.
    @Test(arguments: ["enforce", "observe"])
    func secretsList_isAllowed(_ mode: String) async throws {
        let (home, cwd) = try Self.fixture(mode: mode)
        let rule = try #require(RuleID(rawValue: "core.secrets:home-rv-config"))
        #expect(builtinStopAdvice(rule)?.saferCommand == "rv secrets list")
        #expect(await Self.peek("rv secrets list", home: home, cwd: cwd).decision == .allow)
    }

    private static func fixture(mode: String) throws -> (HomeDirectory, WorkingDirectory) {
        let root = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: root.path))
        let config = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#"{"guard":{"mode":"\#(mode)"}}"#.utf8).write(to: config.appendingPathComponent("config.json"))
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (home, try #require(WorkingDirectory(validating: work.path)))
    }

    private static func peek(_ command: String, home: HomeDirectory, cwd: WorkingDirectory) async -> EvaluationResult {
        await GatedEvaluate().peek(
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
            cwd: cwd, home: home, grants: EphemeralAllowOnceTable(),
            now: Date(timeIntervalSince1970: 1_700_000_000), allowlist: { .empty })
    }
}
