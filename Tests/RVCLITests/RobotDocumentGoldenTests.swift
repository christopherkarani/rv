import Foundation
import Testing
import RVDomain
import RVPresentation
@testable import RVCLI

private func denyResult() -> EvaluationResult {
    EvaluationResult(
        outcome: .deny(
            Deny(
                ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
                reason: "git reset --hard destroys uncommitted changes"
            ),
            matched: nil
        )
    )
}

private func decoded(_ json: String) throws -> NSDictionary {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
}

@Test func robotDocument_testAllow_matchesPreMigrationGolden() throws {
    let golden = #"{"schema":"rv.test.v1","decision":"allow"}"#
    let rendered = RobotDocument.test(testRobotPayload(from: EvaluationResult(outcome: .plain))).render()
    #expect(rendered == #"{"decision":"allow","schema":"rv.test.v1"}"#)
    let decodedGolden = try decoded(golden)
    #expect(try decoded(rendered) == decodedGolden)
}

@Test func robotDocument_testDeny_matchesPreMigrationGolden() throws {
    let golden = #"{"schema":"rv.test.v1","decision":"deny","pack_id":"core.git","rule_id":"core.git:reset-hard","reason":"git reset --hard destroys uncommitted changes"}"#
    let rendered = RobotDocument.test(testRobotPayload(from: denyResult())).render()
    #expect(
        rendered
            == #"{"decision":"deny","pack_id":"core.git","reason":"git reset --hard destroys uncommitted changes","rule_id":"core.git:reset-hard","schema":"rv.test.v1"}"#
    )
    let decodedGolden = try decoded(golden)
    #expect(try decoded(rendered) == decodedGolden)
}

@Test func robotDocument_explainDeny_matchesPreMigrationGolden() throws {
    let model = explainViewModel(
        from: denyResult(),
        command: ShellCommand(rawValue: "git reset --hard")
    )
    let golden = #"{"schema":"rv.explain.v1","decision":"deny","pack_id":"core.git","rule_id":"core.git:reset-hard","reason":"git reset --hard destroys uncommitted changes","next_action":"run it in Terminal, or rv allow-once"}"#
    let rendered = RobotDocument.explain(explainRobotPayload(from: model)).render()
    #expect(
        rendered
            == #"{"decision":"deny","next_action":"run it in Terminal, or rv allow-once","pack_id":"core.git","reason":"git reset --hard destroys uncommitted changes","rule_id":"core.git:reset-hard","schema":"rv.explain.v1"}"#
    )
    let decodedGolden = try decoded(golden)
    #expect(try decoded(rendered) == decodedGolden)
}

@Test func robotDocument_doctor_keepsExactBytes() {
    let doctor = DoctorViewModel(
        service: DoctorServiceView(
            state: .down,
            protocolName: "rv.ipc.v1",
            serviceSemver: nil,
            label: "dev.rv.evaluate",
            fallback: .unavailable,
            launchAgent: .missing,
            warning: "service reported an error"
        ),
        packs: DoctorPacksView(enabled: [.coreGit], registry: .broken),
        hosts: [DoctorHostView(host: .pi, state: .wired)],
        config: .unreadable
    )
    #expect(
        RobotDocument.doctor(doctorRobotPayload(from: doctor)).render()
            == #"{"config":"unreadable","grade":"hook","hosts":{"pi":"wired"},"ok":false,"packs":{"day_one_ready":false,"enabled":["core.git"],"extras_enabled":[],"registry":"broken"},"schema":"rv.doctor.v1","service":{"fallback_ready":false,"launch_agent":"missing","protocol":"rv.ipc.v1","state":"down","warning":"service reported an error"}}"#
    )
}

@Test func robotDocument_packsList_keepsExactBytes() {
    let row = PacksRobotRow(
        id: .coreFilesystem,
        name: "Core Filesystem",
        category: "core",
        description: "rm",
        enabled: false,
        safePatternCount: 0,
        destructivePatternCount: 4
    )
    #expect(
        RobotDocument.packsList(packsRobotPayload(rows: [row], enabledCount: 1, totalCount: 99)).render()
            == #"{"enabled_count":1,"packs":[{"category":"core","description":"rm","destructive_pattern_count":4,"enabled":false,"id":"core.filesystem","name":"Core Filesystem","safe_pattern_count":0}],"schema":"rv.packs.v1","total_count":99}"#
    )
}

@Test func robotDocument_packsInfo_keepsExactBytes() {
    let row = PacksRobotRow(
        id: .coreFilesystem,
        name: "Core Filesystem",
        category: "core",
        description: "rm",
        enabled: false,
        safePatternCount: 0,
        destructivePatternCount: 4
    )
    #expect(
        RobotDocument.packsInfo(row).render()
            == #"{"category":"core","description":"rm","destructive_pattern_count":4,"enabled":false,"id":"core.filesystem","name":"Core Filesystem","safe_pattern_count":0}"#
    )
}
