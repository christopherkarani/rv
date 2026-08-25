import Foundation
import Testing
import RVDomain
@testable import RVPolicy
@testable import RVCLI

private func decoded(_ json: String) throws -> NSArray {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSArray)
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
    let rows = allowlistRobotRows(from: entries, now: now)
    #expect(rows.map(\.active) == [true, false])
    #expect(rows[0].selector == .rule(ruleID))
    #expect(rows[1].selector == .exactCommand(MatchingView("sudo rm -rf /opt/tmp/build")))

    let rendered = RobotDocument.allowlistList(rows).render()
    #expect(
        rendered
            == #"[{"active":"true","reason":"reviewed","rule":"core.git:reset-hard"},{"active":"false","exact_command":"sudo rm -rf /opt/tmp/build","reason":"safe"}]"#
    )
    let preMigration = #"[{"active":"true","reason":"reviewed","rule":"core.git:reset-hard"},{"active":"false","exact_command":"sudo rm -rf \/opt\/tmp\/build","reason":"safe"}]"#
    let decodedPreMigration = try decoded(preMigration)
    #expect(try decoded(rendered) == decodedPreMigration)
}

@Test func robotDocument_allowOnceList_matchesPreMigrationGolden() throws {
    let hashA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let hashB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    let listRows = [
        AllowOnceListRow(
            kind: .granted,
            codeHash: hashA,
            commandRedacted: "git …",
            cwd: wd("/tmp/a"),
            createdAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 2)
        ),
        AllowOnceListRow(
            kind: .pending,
            codeHash: hashB,
            commandRedacted: "git …",
            cwd: wd("/tmp/b"),
            createdAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 2)
        ),
    ]
    let rows = allowOnceRobotRows(from: listRows)
    #expect(rows.map(\.kind) == [.granted, .pending])
    let rendered = RobotDocument.allowOnceList(rows).render()
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

@Test func allowlistRobotRow_selectorIsExclusiveAndActiveIsJSONString() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let ruleID = try #require(RuleID(rawValue: "core.git:reset-hard"))
    let rows = allowlistRobotRows(
        from: [
            AllowlistEntry(selector: .rule(ruleID), reason: "reviewed", addedAt: now),
            AllowlistEntry(
                selector: .exactCommand(MatchingView("echo hi")),
                reason: "safe",
                addedAt: now
            ),
        ],
        now: now
    )
    let objects = try decoded(RobotDocument.allowlistList(rows).render())
    let ruleRow = try #require(objects[0] as? NSDictionary)
    let exactRow = try #require(objects[1] as? NSDictionary)
    #expect(ruleRow["rule"] as? String == "core.git:reset-hard")
    #expect(ruleRow["exact_command"] == nil)
    #expect(ruleRow["active"] as? String == "true")
    #expect(exactRow["exact_command"] as? String == "echo hi")
    #expect(exactRow["rule"] == nil)
}
