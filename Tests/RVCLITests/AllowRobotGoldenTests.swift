import CryptoKit
import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

private func decoded(_ json: String) throws -> NSArray {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSArray)
}

private func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func isolatedStore() throws -> AllowOnceStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-allow-robot-golden-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AllowOnceStore(baseDirectory: root)
}

@Test func robotDocument_allowlistList_matchesPreMigrationGolden() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
    let entries = [
        AllowlistEntry(selector: .rule(ruleID), reason: "reviewed", addedAt: now),
        AllowlistEntry(
            selector: .exactCommand(MatchingView("sudo rm -rf /opt/tmp/build")),
            reason: "safe",
            addedAt: now,
            expiresAt: now.addingTimeInterval(-1)
        ),
    ]
    let rendered = RobotDocument.allowlistList(allowlistRobotRows(from: entries, now: now)).render()
    #expect(
        rendered
            == #"[{"active":"true","reason":"reviewed","rule":"core.git:reset-hard"},{"active":"false","exact_command":"sudo rm -rf /opt/tmp/build","reason":"safe"}]"#
    )
    let preMigration = #"[{"active":"true","reason":"reviewed","rule":"core.git:reset-hard"},{"active":"false","exact_command":"sudo rm -rf \/opt\/tmp\/build","reason":"safe"}]"#
    let decodedPreMigration = try decoded(preMigration)
    #expect(try decoded(rendered) == decodedPreMigration)
}

@Test func robotDocument_allowOnceList_matchesPreMigrationGolden() async throws {
    let store = try isolatedStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
    let codeA = try await AllowOnceCLI.mint(
        command: "git reset --hard",
        cwd: "/tmp/a",
        tty: tty,
        robot: false,
        store: store,
        now: now
    )
    _ = try await AllowOnceCLI.redeem(
        code: codeA,
        tty: tty,
        robot: false,
        store: store,
        now: now
    )
    _ = try await AllowOnceCLI.mint(
        command: "git status",
        cwd: "/tmp/b",
        tty: tty,
        robot: false,
        store: store,
        now: now
    )
    let rows = await store.list(now: now)
    #expect(rows.count == 2)
    #expect(rows[0].kind == .granted)
    #expect(rows[1].kind == .pending)

    let hashA = sha256Hex(codeA.lowercased())
    let hashB = rows[1].codeHash
    #expect(hashA == rows[0].codeHash)
    let rendered = RobotDocument.allowOnceList(allowOnceRobotRows(from: rows)).render()
    #expect(
        rendered
            == #"[{"code_hash":"\#(hashA)","command_redacted":"git …","cwd":"/tmp/a","kind":"granted"},{"code_hash":"\#(hashB)","command_redacted":"git …","cwd":"/tmp/b","kind":"pending"}]"#
    )
    let preMigration = #"[{"code_hash":"\#(hashA)","command_redacted":"git …","cwd":"\/tmp\/a","kind":"granted"},{"code_hash":"\#(hashB)","command_redacted":"git …","cwd":"\/tmp\/b","kind":"pending"}]"#
    let decodedPreMigration = try decoded(preMigration)
    #expect(try decoded(rendered) == decodedPreMigration)
}

@Test func robotDocument_allowLists_emptyRenderIsBareEmptyArray() {
    #expect(RobotDocument.allowlistList([]).render() == "[]")
    #expect(RobotDocument.allowOnceList([]).render() == "[]")
}
