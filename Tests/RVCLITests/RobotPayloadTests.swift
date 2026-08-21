import Foundation
import Testing
import RVDomain
import RVPresentation
import RVTheme
@testable import RVCLI

private func robotProbe() -> ThemeProbe {
    ThemeProbe(
        stdinIsTTY: false,
        stdoutIsTTY: false,
        jsonFlag: true,
        robotFlag: true,
        plainFlag: false,
        noColorFlag: false,
        ci: false,
        noColorEnv: false,
        termDumb: false
    )
}

private func trimOneNewline(_ text: String) -> String {
    text.hasSuffix("\n") ? String(text.dropLast()) : text
}

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

private func renderRobot(kind: CLIKind, result: EvaluationResult, command: String) -> CLIResult {
    CommandRun.render(
        kind: kind,
        result: result,
        command: ShellCommand(rawValue: command),
        probe: robotProbe(),
        requested: .robot
    )
}

private func object(from stdout: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
}

@Test func explainRobot_stdoutSchemaIsNotTestSchema() throws {
    let rendered = renderRobot(
        kind: .explain,
        result: denyResult(),
        command: "git reset --hard"
    )
    let json = try object(from: rendered.stdout)

    #expect(rendered.exitCode == 0)
    #expect(json["schema"] as? String == "rv.explain.v1")
    #expect(json["schema"] as? String != "rv.test.v1")
    #expect(json["decision"] as? String == "deny")
}

@Test func testRobot_stdoutKeepsStableTestSchemaAndBytes() throws {
    let allow = renderRobot(kind: .test, result: EvaluationResult(outcome: .plain), command: "git status")
    #expect(allow.exitCode == 0)
    #expect(trimOneNewline(allow.stdout) == #"{"schema":"rv.test.v1","decision":"allow"}"#)

    let deny = renderRobot(kind: .test, result: denyResult(), command: "git reset --hard")
    #expect(deny.exitCode == 1)
    #expect(
        trimOneNewline(deny.stdout)
            == #"{"schema":"rv.test.v1","decision":"deny","pack_id":"core.git","rule_id":"core.git:reset-hard","reason":"git reset --hard destroys uncommitted changes"}"#
    )
}

@Test func commandRunRobot_encodesPresentationPayloads() throws {
    let result = denyResult()
    let testOut = renderRobot(kind: .test, result: result, command: "git reset --hard")
    let encodedTest = RobotJSON.encode(testRobotPayload(from: result).fields)
    #expect(trimOneNewline(testOut.stdout) == encodedTest)

    let model = explainViewModel(
        from: result,
        command: ShellCommand(rawValue: "git reset --hard")
    )
    let explainOut = renderRobot(kind: .explain, result: result, command: "git reset --hard")
    let encodedExplain = RobotJSON.encode(explainRobotPayload(from: model).fields)
    #expect(trimOneNewline(explainOut.stdout) == encodedExplain)
}

@Test func robotJSON_encodesDoctorAndPacksFieldSets() throws {
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
    let doctorJSON = try object(from: try RobotJSON.encode(doctorRobotPayload(from: doctor)))
    let service = try #require(doctorJSON["service"] as? [String: Any])
    let packs = try #require(doctorJSON["packs"] as? [String: Any])

    #expect(doctorJSON["schema"] as? String == "rv.doctor.v1")
    #expect(Set(doctorJSON.keys) == ["schema", "service", "packs", "hosts", "config", "grade", "ok"])
    #expect(Set(service.keys) == [
        "state", "protocol", "fallback_ready", "launch_agent", "warning",
    ])
    #expect(Set(packs.keys) == ["registry", "day_one_ready", "enabled", "extras_enabled"])

    let row = PacksRobotRow(
        id: .coreFilesystem,
        name: "Core Filesystem",
        category: "core",
        description: "rm",
        enabled: false,
        safePatternCount: 0,
        destructivePatternCount: 4
    )
    let packsJSON = try object(
        from: try RobotJSON.encode(packsRobotPayload(rows: [row], enabledCount: 1, totalCount: 99))
    )
    let encodedRows = try #require(packsJSON["packs"] as? [[String: Any]])
    let encodedRow = try #require(encodedRows.first)
    #expect(packsJSON["schema"] as? String == "rv.packs.v1")
    #expect(Set(packsJSON.keys) == ["schema", "packs", "enabled_count", "total_count"])
    #expect(Set(encodedRow.keys) == [
        "id", "name", "category", "description", "enabled",
        "safe_pattern_count", "destructive_pattern_count",
    ])
}
