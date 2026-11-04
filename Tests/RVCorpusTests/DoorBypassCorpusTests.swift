import Testing
import RVDomain
import RVEngine

/// Deterministic-gate bypass corpus: reserved-word heads, `find -exec`,
/// `xargs`, `nohup`/`doas`, chained wrappers, inline interpreter programs,
/// and git long-option abbreviations. Door only; the pack floor alone
/// allows every deny row here.
@Suite("Door bypass corpus")
struct DoorBypassCorpusTests {
    @Test func denyRowsAreDeniedAtTheDoor() throws {
        let harness = try StressHarness.dayOne()
        let rows = try loadStressCorpus("door-bypass.json").filter { $0.expected == "deny" }
        #expect(rows.isEmpty == false)
        for row in rows {
            guard let command = row.command else { continue }
            let result = door(harness, command)
            guard case .deny = result.decision else {
                Issue.record("\(row.id) must deny, got \(describeDecision(result)): \(command)")
                continue
            }
        }
    }

    @Test func allowRowsStayAllowedAtTheDoor() throws {
        let harness = try StressHarness.dayOne()
        let rows = try loadStressCorpus("door-bypass.json").filter { $0.expected == "allow" }
        #expect(rows.isEmpty == false)
        for row in rows {
            guard let command = row.command else { continue }
            let result = door(harness, command)
            if result.decision != .allow {
                Issue.record("\(row.id) must allow, got \(describeDecision(result)): \(command)")
            }
        }
    }
}

/// Product door with a probed home so `~` deletes classify as home mutations,
/// matching the live filesystem probe.
private func door(_ harness: StressHarness, _ command: String) -> EvaluationResult {
    let context = FilesystemAnalysisContext(
        homeDirectory: HomePath(validating: "/isolated-home")
    )
    return evaluateWithSemantics(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: harness.packs,
        engine: harness.engine,
        compiled: harness.compiled,
        filesystemProbe: { _ in .probed(context) }
    )
}
