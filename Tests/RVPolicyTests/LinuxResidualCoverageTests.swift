#if canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct LinuxResidualCoverageTests {
    @Test func processHome_emptyWhenHOMEUnset() {
        let previous = getenv("HOME").map { String(cString: $0) }
        unsetenv("HOME")
        defer {
            if let previous {
                setenv("HOME", previous, 1)
            } else {
                unsetenv("HOME")
            }
        }
        #expect(HomeDirectory.process() == nil)
    }

    @Test func rebaseRecovery_allowIsNotEligible() {
        let result = EvaluationResult(outcome: .plain, matchingView: MatchingView("git status"))
        #expect(RebaseRecovery.isEligible(result: result) == false)
    }

    @Test func shadowDisagreement_missingDecisionIsNotDisagreement() {
        #expect(ShadowDisagreement.disagrees(live: .allow, decision: nil) == false)
    }

    @Test func allowlistParse_errorResidualsAndExpiresRender() throws {
        #expect(parseAllowlistRuleID("nocolon") == nil)
        #expect(throws: AllowlistParseError.invalidRule("Core.Git:reset-hard")) {
            try AllowlistTOML.parse(
                """
                [[allow]]
                rule = "Core.Git:reset-hard"
                reason = "bad pack"
                """
            )
        }
        #expect(throws: AllowlistParseError.missingSelector) {
            try AllowlistTOML.parse(
                """
                [[allow]]
                reason = "no selector"
                """
            )
        }
        #expect(throws: AllowlistParseError.bothSelectors) {
            try AllowlistTOML.parse(
                """
                [[allow]]
                rule = "core.git:reset-hard"
                exact_command = "git reset --hard"
                reason = "both"
                """
            )
        }
        #expect(throws: AllowlistParseError.invalidDate("nope")) {
            try AllowlistTOML.parse(
                """
                [[allow]]
                rule = "core.git:reset-hard"
                reason = "bad"
                added_at = "nope"
                """
            )
        }
        #expect(throws: AllowlistParseError.invalidDate("also-nope")) {
            try AllowlistTOML.parse(
                """
                [[allow]]
                rule = "core.git:reset-hard"
                reason = "bad expire"
                expires_at = "also-nope"
                """
            )
        }
        let missingDate = try AllowlistTOML.parse(
            """
            [[allow]]
            exact_command = "rm -rf ./build"
            reason = "epoch"
            """
        )
        #expect(missingDate[0].addedAt == Date(timeIntervalSince1970: 0))

        let rendered = AllowlistTOML.render([
            AllowlistEntry(
                selector: .exactCommand(MatchingView("rm -rf ./build")),
                reason: "temp",
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
        ])
        #expect(rendered.contains("expires_at"))
        #expect(try AllowlistTOML.parse(rendered).count == 1)
    }

    @Test func allowlistStore_lockDirectoryFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allow-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = RVPolicyPaths.allowlistLockFile(inConfigDir: root)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let store = AllowlistStore(baseDirectory: root)
        #expect(throws: AllowlistStoreError.lockFailed) {
            try store.writeAll([])
        }
    }

    @Test func allowOnceStore_emptyRobotAndMissingResiduals() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allow-resid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AllowOnceStore(baseDirectory: root)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))

        await #expect(throws: AllowOnceError.emptyCommand) {
            try await store.mint(
                matchingView: "   ",
                cwd: cwd,
                ruleID: nil,
                tty: tty,
                now: now
            )
        }
        await #expect(throws: AllowOnceError.robotRefused) {
            try await store.mint(
                matchingView: "git reset --hard",
                cwd: cwd,
                ruleID: nil,
                tty: tty,
                now: now,
                robot: true
            )
        }
        #expect(await store.plantAndConsume(matchingView: "  ", cwd: cwd, now: now) == .notFound)
        #expect(await store.consume(matchingView: "git reset --hard", cwd: cwd, now: now) == .notFound)
        #expect(await store.hasGrant(matchingView: "git reset --hard", cwd: cwd, now: now) == false)

        try await store.insertGranted(matchingView: MatchingView("git reset --hard"), cwd: cwd, now: now)
        #expect(await store.hasGrant(matchingView: MatchingView("git reset --hard"), cwd: cwd, now: now))
        #expect(await store.hasGrant(matchingView: MatchingView("other"), cwd: cwd, now: now) == false)

        await #expect(throws: AllowOnceError.unknownCode) {
            try await store.redeem(code: "nope", tty: tty, now: now)
        }
        await #expect(throws: AllowOnceError.unknownCode) {
            try await store.redeem(code: "zzzzzz", tty: tty, now: now)
        }
        await #expect(throws: AllowOnceError.ttyRequired) {
            try await store.clear(
                tty: TTYCapability(stdinIsTTY: false, stdoutIsTTY: false, ci: false),
                now: now
            )
        }
    }

    @Test func allowOnceStore_skipsInvalidJSONLAndLockFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allow-jsonl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AllowOnceStore(baseDirectory: root)
        let file = RVPolicyPaths.allowOnceFile(inConfigDir: root)
        try Data("\nnot-json\n{\"schemaVersion\":2}\n".utf8).write(to: file)
        #expect(await store.list(now: Date(timeIntervalSince1970: 1)) == [])

        let lock = RVPolicyPaths.allowOnceLockFile(inConfigDir: root)
        if FileManager.default.fileExists(atPath: lock.path) {
            try FileManager.default.removeItem(at: lock)
        }
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        await #expect(throws: AllowOnceError.lockFailed) {
            try await store.insertGranted(
                matchingView: MatchingView("git reset --hard"),
                cwd: try #require(WorkingDirectory(validating: "/tmp/ws")),
                now: Date(timeIntervalSince1970: 1)
            )
        }
    }

    @Test func rulePinning_ruleIDUsesMatchingViewOrPredicate() {
        let view = MatchingView("git status")
        let fromView = RulePinning.ruleID(polarity: .allow, matchingView: view)
        #expect(fromView == RulePinning.ruleID(polarity: .allow, matchingView: view))
        #expect(fromView != RulePinning.ruleID(polarity: .allow, matchingView: MatchingView("sudo git status")))
        let predicate = PolicyPredicate.gitPush(force: .exactly(.force), branch: "main")
        let fromPredicate = RulePinning.ruleID(polarity: .block, predicate: predicate)
        #expect(fromPredicate == RulePinning.ruleID(polarity: .block, predicate: predicate))
        #expect(fromPredicate.pack.rawValue == "pin.block")
        #expect(fromView.pack.rawValue == "pin.allow")
    }
}
