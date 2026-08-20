import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct AllowlistTests {
    @Test func reasonRequired() throws {
        #expect(throws: AllowlistParseError.missingReason) {
            try AllowlistTOML.parse(
                """
                [[allow]]
                rule = "core.git:reset-hard"
                """
            )
        }
        #expect(throws: AllowlistParseError.emptyReason) {
            try AllowlistTOML.parse(
                """
                [[allow]]
                rule = "core.git:reset-hard"
                reason = "   "
                """
            )
        }
    }

    @Test func ruleAndExactMatch() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = try AllowlistTOML.parse(
            """
            [[allow]]
            rule = "core.git/reset-hard"
            reason = "CI cleanup"
            added_at = "2026-01-08T12:00:00Z"

            [[allow]]
            exact_command = "rm -rf ./build"
            reason = "build dir"
            added_at = "2026-01-08T12:00:00Z"
            """
        )
        let snap = AllowlistSnapshot(entries: entries)
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        #expect(snap.matches(ruleID: ruleID, matchingView: "git reset --hard", now: now))
        #expect(snap.matches(ruleID: nil, matchingView: "rm -rf ./build", now: now))
        #expect(snap.matches(ruleID: nil, matchingView: "git status", now: now) == false)
    }

    @Test func expiredRowIgnored() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = try AllowlistTOML.parse(
            """
            [[allow]]
            rule = "core.git:reset-hard"
            reason = "old"
            added_at = "2020-01-01T00:00:00Z"
            expires_at = "2020-01-02T00:00:00Z"
            """
        )
        let snap = AllowlistSnapshot(entries: entries)
        let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
        #expect(snap.matches(ruleID: ruleID, matchingView: "git reset --hard", now: now) == false)
    }

    @Test func projectFileInert() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allowlist-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let projectAllow = project.appendingPathComponent(".rv/allowlist.toml")
        try FileManager.default.createDirectory(
            at: projectAllow.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [[allow]]
        rule = "core.git:reset-hard"
        reason = "should not grant"
        """.write(to: projectAllow, atomically: true, encoding: .utf8)
        let userStore = AllowlistStore(baseDirectory: root.appendingPathComponent("config"))
        let snap = userStore.loadUserSnapshot(workspacePath: project.path, now: Date())
        #expect(snap.entries.isEmpty)
    }

    @Test func symlinkIntoWorkspaceIgnored() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allowlist-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("ws", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let target = workspace.appendingPathComponent("poison.toml")
        try """
        [[allow]]
        rule = "core.git:reset-hard"
        reason = "poison"
        """.write(to: target, atomically: true, encoding: .utf8)
        let link = RVPolicyPaths.allowlistFile(inConfigDir: config)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = AllowlistStore(baseDirectory: config)
        let snap = store.loadUserSnapshot(workspacePath: workspace.path, now: Date())
        #expect(snap.entries.isEmpty)
        #expect(store.loadForValidate(workspacePath: workspace.path) == .symlinkIntoWorkspace)
    }

    @Test func invalidTOMLFailsOpenOnLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allowlist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "not toml {{{".write(
            to: RVPolicyPaths.allowlistFile(inConfigDir: root),
            atomically: true,
            encoding: .utf8
        )
        let snap = AllowlistStore(baseDirectory: root)
            .loadUserSnapshot(workspacePath: nil, now: Date())
        #expect(snap.entries.isEmpty)
    }
}
