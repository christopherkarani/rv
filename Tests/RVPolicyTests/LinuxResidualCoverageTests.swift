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
}
