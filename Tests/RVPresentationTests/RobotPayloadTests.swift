import Foundation
import Testing
import RVDomain
import RVPresentation

private let resetHard = ShellCommand(rawValue: "git reset --hard")

private func denyResult() -> EvaluationResult {
    let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    return EvaluationResult(
        outcome: .deny(
            Deny(ruleID: rule, reason: "git reset --hard destroys uncommitted changes"),
            matched: nil
        )
    )
}

private func object(from payload: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(payload)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let readyService = DoctorServiceView(
    state: .running,
    protocolName: "rv.ipc.v1",
    serviceSemver: "1.0.0" as String?,
    label: "dev.rv.evaluate",
    fallback: .ready,
    launchAgent: .loaded
)

@Test func testRobotPayload_schemaAndKeysStayStable() throws {
    let allow = try object(from: testRobotPayload(from: EvaluationResult(outcome: .plain)))
    #expect(allow["schema"] as? String == "rv.test.v1")
    #expect(allow["decision"] as? String == "allow")
    #expect(allow["reason"] == nil)
    #expect(allow.count == 2)

    let deny = try object(from: testRobotPayload(from: denyResult()))
    #expect(deny["schema"] as? String == "rv.test.v1")
    #expect(deny["decision"] as? String == "deny")
    #expect(deny["pack_id"] as? String == "core.git")
    #expect(deny["rule_id"] as? String == "core.git:reset-hard")
    #expect(deny["reason"] as? String == "git reset --hard destroys uncommitted changes")

    let incomplete = try object(
        from: testRobotPayload(from: EvaluationResult(outcome: .indeterminate(.commandTooLarge)))
    )
    #expect(incomplete["schema"] as? String == "rv.test.v1")
    #expect(incomplete["decision"] as? String == "indeterminate")
    #expect(incomplete["reason"] as? String == incompleteEvalSentence)

    #expect(Set(deny.keys) == ["schema", "decision", "pack_id", "rule_id", "reason"])
}

@Test func explainRobotPayload_schemaIsNotTestSchema() throws {
    let model = explainViewModel(from: denyResult(), command: resetHard)
    let payload = explainRobotPayload(from: model)
    let json = try object(from: payload)

    #expect(payload.schema == "rv.explain.v1")
    #expect(payload.schema != "rv.test.v1")
    #expect(json["schema"] as? String == "rv.explain.v1")
    #expect(json["schema"] as? String != "rv.test.v1")
    #expect(json["decision"] as? String == "deny")
    #expect(json["pack_id"] as? String == "core.git")
    #expect(json["rule_id"] as? String == "core.git:reset-hard")
    #expect(json["reason"] as? String == model.fact)
}

@Test func doctorRobotPayload_fieldSetUnchanged() throws {
    let model = DoctorViewModel(
        service: readyService,
        packs: DoctorPacksView(enabled: dayOnePackIDs, registry: .ready),
        hosts: HookHost.setupSlotOrder.map { DoctorHostView(host: $0, state: .missing) },
        config: .readable
    )
    let json = try object(from: doctorRobotPayload(from: model))
    let service = try #require(json["service"] as? [String: Any])
    let packs = try #require(json["packs"] as? [String: Any])
    let hosts = try #require(json["hosts"] as? [String: Any])

    #expect(json["schema"] as? String == "rv.doctor.v1")
    #expect(json["grade"] as? String == "hook")
    #expect(json["ok"] as? Bool == true)
    #expect(json["config"] as? String == "readable")
    #expect(Set(json.keys) == ["schema", "service", "packs", "hosts", "config", "grade", "ok"])

    #expect(Set(service.keys) == [
        "state", "protocol", "service_semver", "fallback_ready", "launch_agent",
    ])
    #expect(service["state"] as? String == "running")
    #expect(service["protocol"] as? String == "rv.ipc.v1")
    #expect(service["service_semver"] as? String == "1.0.0")
    #expect(service["fallback_ready"] as? Bool == true)
    #expect(service["launch_agent"] as? String == "loaded")
    #expect(service["warning"] == nil)

    #expect(Set(packs.keys) == ["registry", "day_one_ready", "enabled", "extras_enabled"])
    #expect(packs["registry"] as? String == "ready")
    #expect(packs["day_one_ready"] as? Bool == true)
    #expect(packs["enabled"] as? [String] == dayOnePackIDs.map(\.rawValue).sorted())
    #expect(packs["extras_enabled"] as? [String] == [])

    #expect(Set(hosts.keys) == ["grok", "pi", "opencode", "claude"])
    #expect(hosts["grok"] as? String == "missing")
    #expect(hosts["pi"] as? String == "missing")
    #expect(hosts["opencode"] as? String == "missing")
    #expect(hosts["claude"] as? String == "missing")
}

@Test func packsRobotPayload_fieldSetUnchanged() throws {
    let row = PacksRobotRow(
        id: .coreGit,
        name: "Core Git",
        category: "core",
        description: "git destruction",
        enabled: true,
        safePatternCount: 1,
        destructivePatternCount: 2
    )
    let json = try object(from: packsRobotPayload(rows: [row], enabledCount: 2, totalCount: 99))
    let packs = try #require(json["packs"] as? [[String: Any]])
    let encodedRow = try #require(packs.first)

    #expect(json["schema"] as? String == "rv.packs.v1")
    #expect(json["enabled_count"] as? Int == 2)
    #expect(json["total_count"] as? Int == 99)
    #expect(Set(json.keys) == ["schema", "packs", "enabled_count", "total_count"])
    #expect(Set(encodedRow.keys) == [
        "id", "name", "category", "description", "enabled",
        "safe_pattern_count", "destructive_pattern_count",
    ])
    #expect(encodedRow["id"] as? String == "core.git")
    #expect(encodedRow["safe_pattern_count"] as? Int == 1)
    #expect(encodedRow["destructive_pattern_count"] as? Int == 2)
}
