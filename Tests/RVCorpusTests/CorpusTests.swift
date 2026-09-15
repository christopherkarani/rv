import Foundation
import Testing
import RVDomain
import RVEngine
import RVPacks

struct CorpusCase: Decodable, Sendable, CustomTestStringConvertible {
    var id: String
    var command: String?
    var expected: String?
    var ruleID: String?
    var reasonContains: String?
    var kind: String?
    var pinned_0_11_0: String?
    var skillClaimed: String?

    enum CodingKeys: String, CodingKey {
        case id
        case command
        case expected
        case ruleID = "rule_id"
        case reasonContains = "reason_contains"
        case kind
        case pinned_0_11_0
        case skillClaimed = "skill_claimed"
    }

    var testDescription: String { id }
}

struct CorpusFile: Decodable {
    var cases: [CorpusCase]
}

/// Day-one packs compiled once per test. Pin scoreboard is pack `evaluate`.
/// Product door is `evaluateWithSemantics` (unprobed defaults).
private struct DayOneHarness: Sendable {
    var packs: [PackSnapshot]
    var engine: ICUPatternEngine
    var compiled: CompiledPacks<ICUCompiledPattern>

    static func load() throws -> DayOneHarness {
        let packs = try PackRegistry.loadDayOne()
        let engine = ICUPatternEngine()
        let compiled = try CompiledPacks<ICUCompiledPattern>.compile(
            packs: packs,
            using: engine
        )
        return DayOneHarness(packs: packs, engine: engine, compiled: compiled)
    }

    func pin(_ command: String) -> EvaluationResult {
        evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: command),
                enabledPacks: dayOnePackIDs
            ),
            packs: packs,
            engine: engine,
            compiled: compiled
        )
    }

    func door(_ command: String) -> EvaluationResult {
        evaluateWithSemantics(
            EvaluationRequest(
                command: ShellCommand(rawValue: command),
                enabledPacks: dayOnePackIDs
            ),
            packs: packs,
            engine: engine,
            compiled: compiled
        )
    }
}

private func corpusDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("RVEngineTests/Fixtures/corpus")
}

private func loadCases(_ name: String) throws -> [CorpusCase] {
    let url = corpusDirectory().appendingPathComponent(name)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(CorpusFile.self, from: data).cases
}

private func loadDiskCoverage() throws -> [CorpusCase] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("disk-rule-coverage.json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(CorpusFile.self, from: data).cases
}

/// 0.11.0 pack `evaluate` scoreboard. JSON `expected` is the pin Decision.
private func assertPin(
    _ row: CorpusCase,
    using harness: DayOneHarness,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    guard let command = row.command, let expected = row.expected else { return }
    let result = harness.pin(command)
    switch expected {
    case "deny":
        guard case .deny(let deny) = result.decision else {
            Issue.record(
                "\(row.id): expected deny, got \(String(describing: result.decision))",
                sourceLocation: sourceLocation
            )
            return
        }
        if let ruleID = row.ruleID {
            #expect(deny.ruleID.rawValue == ruleID, "\(row.id)", sourceLocation: sourceLocation)
        }
        if let needle = row.reasonContains {
            #expect(deny.reason.contains(needle), "\(row.id)", sourceLocation: sourceLocation)
        }
        #expect(
            result.matched?.ruleID.rawValue == row.ruleID ?? result.matched?.ruleID.rawValue,
            sourceLocation: sourceLocation
        )
    case "allow":
        #expect(
            result.decision == .allow,
            "\(row.id) got \(String(describing: result.decision))",
            sourceLocation: sourceLocation
        )
        if let ruleID = row.ruleID {
            #expect(
                result.matched?.ruleID.rawValue == ruleID,
                "\(row.id)",
                sourceLocation: sourceLocation
            )
        }
    case "indeterminate":
        guard case .indeterminate = result.decision else {
            Issue.record("\(row.id): expected indeterminate", sourceLocation: sourceLocation)
            return
        }
    default:
        Issue.record("\(row.id): unknown expected \(expected)", sourceLocation: sourceLocation)
    }
}

/// Quiet-work landmines: pack walk may still see print/prose guts (RV-RR-02).
/// The product door must allow. A `builtin.action` deny here is a false block.
private let residualQuietWorkIDs: Set<String> = [
    "near.echo-quoted-reset",
    "near.lift-014-echo-ansic-reset",
    "near.rg-quoted-rm",
    "near.git-commit-rm-message",
    "near.git-commit-force-message",
    "near.git-commit-message-equals",
    "near.sudo-echo-quoted-reset",
    "near.env-echo-quoted-reset",
    "near.command-echo-quoted-reset",
    "near.python-c-print-reset",
    "near.node-e-console-reset",
]

/// Product door. Pack deny / indeterminate is the floor. A pack allow may
/// tighten only to `builtin.action`, except RV-RR-02 quiet-work ids (door allow).
private func assertDoor(
    _ row: CorpusCase,
    using harness: DayOneHarness,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let command = row.command else { return }
    let pin = harness.pin(command)
    let door = harness.door(command)
    switch pin.decision {
    case .deny(let deny):
        guard case .deny(let doorDeny) = door.decision else {
            Issue.record(
                "\(row.id): pack deny is the floor, door got \(String(describing: door.decision))",
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(
            doorDeny.ruleID == deny.ruleID,
            "\(row.id) door must keep pack rule \(deny.ruleID.rawValue)",
            sourceLocation: sourceLocation
        )
    case .indeterminate(let reason):
        #expect(
            door.decision == .indeterminate(reason),
            "\(row.id): door got \(String(describing: door.decision))",
            sourceLocation: sourceLocation
        )
    case .allow:
        if residualQuietWorkIDs.contains(row.id) {
            #expect(
                door.decision == .allow,
                "\(row.id): RV-RR-02 door must allow, got \(String(describing: door.decision))",
                sourceLocation: sourceLocation
            )
            return
        }
        switch door.decision {
        case .allow:
            break
        case .deny(let deny):
            #expect(
                deny.ruleID.pack == ActionPolicyEngine.Builtin.pack,
                "\(row.id): door tightened with \(deny.ruleID.rawValue); only builtin.action may tighten a pack allow",
                sourceLocation: sourceLocation
            )
        case .indeterminate(let reason):
            Issue.record(
                "\(row.id): door indeterminate \(reason) on pack allow",
                sourceLocation: sourceLocation
            )
        }
    }
}

private func assertPinAndDoor(
    _ row: CorpusCase,
    using harness: DayOneHarness,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    try assertPin(row, using: harness, sourceLocation: sourceLocation)
    assertDoor(row, using: harness, sourceLocation: sourceLocation)
}

@Test func corpus_skillTable() throws {
    let harness = try DayOneHarness.load()
    for row in try loadCases("skill-table.json") {
        try assertPinAndDoor(row, using: harness)
    }
}

@Test func corpus_deny() throws {
    let harness = try DayOneHarness.load()
    for row in try loadCases("deny.json") {
        try assertPinAndDoor(row, using: harness)
    }
}

@Test func corpus_nearMiss() throws {
    let harness = try DayOneHarness.load()
    let rows = try loadCases("near-miss.json")
    let ids = Set(rows.map(\.id))
    for id in residualQuietWorkIDs {
        #expect(ids.contains(id), "\(id) missing from near-miss.json")
    }
    for row in rows {
        try assertPinAndDoor(row, using: harness)
    }
}

@Test func corpus_quarantineFollowsPinned() throws {
    let harness = try DayOneHarness.load()
    let rows = try loadCases("quarantine.json")
    #expect(rows.contains { $0.id == "skill.stale.tmpdir-allow" })
    #expect(rows.contains { $0.id == "skill.stale.stash-drop-block" })
    #expect(rows.contains { $0.id == "skill.counts.34-16" })
    for row in rows where row.kind != "meta" {
        try assertPinAndDoor(row, using: harness)
        if let claimed = row.skillClaimed, let pinned = row.pinned_0_11_0,
            let expected = row.expected
        {
            #expect(expected == pinned, "\(row.id) must follow pinned, not \(claimed)")
        }
    }
}

@Test func corpus_everyPatternCompilesOnICU() throws {
    let packs = try PackRegistry.loadDayOne()
    let compiled = try CompiledPacks.compile(packs: packs, using: ICUPatternEngine())
    #expect(!compiled.quarantined.contains { $0.pattern == "reset-hard" })
    #expect(!compiled.quarantined.contains { $0.pattern == "fork-bomb" })
    let git = try #require(compiled.packs.first { $0.snapshot.id == .coreGit })
    #expect(git.destructive.contains { $0.rule.name == "reset-hard" })
    let filesystem = try #require(compiled.packs.first { $0.snapshot.id == .coreFilesystem })
    #expect(filesystem.destructive.contains { $0.rule.name == "fork-bomb" })
}

@Test func corpus_everyNonSemanticDestructiveHasTruePositive() throws {
    let semantic = Set([
        "git-alias-semantic-unverified",
        "branch-dynamic-token",
        "sed-exec-unverified",
    ])
    let packs = try PackRegistry.loadDayOne()
    var covered = Set<String>()
    for file in ["skill-table.json", "deny.json"] {
        for row in try loadCases(file) where row.expected == "deny" || row.ruleID != nil {
            if let ruleID = row.ruleID, let parsed = RuleID(rawValue: ruleID) {
                covered.insert(parsed.pattern)
            }
        }
    }
    for row in try loadDiskCoverage() where row.ruleID != nil {
        if let ruleID = row.ruleID, let parsed = RuleID(rawValue: ruleID) {
            covered.insert(parsed.pattern)
        }
    }
    for pack in packs {
        for rule in pack.destructive where !semantic.contains(rule.name) {
            #expect(covered.contains(rule.name), Comment(rawValue: "\(pack.id.rawValue):\(rule.name)"))
        }
    }
}

@Test func corpus_skillDenyResetHardExists() throws {
    let harness = try DayOneHarness.load()
    let rows = try loadCases("skill-table.json")
    #expect(rows.contains { $0.id == "skill.deny.reset-hard" })
    let pin = harness.pin("git reset --hard")
    guard case .deny(let deny) = pin.decision else {
        Issue.record("day-one deny missing")
        return
    }
    #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    let door = harness.door("git reset --hard")
    guard case .deny(let doorDeny) = door.decision else {
        Issue.record("door must keep pack deny, got \(String(describing: door.decision))")
        return
    }
    #expect(doorDeny.ruleID.rawValue == "core.git:reset-hard")
}

/// Pin allow / door deny. Fails if `door` is pack `evaluate`.
@Test func corpus_door_pythonOsSystemReset_tightensPackAllow() throws {
    let harness = try DayOneHarness.load()
    let command = #"python -c "os.system('git reset --hard')""#
    #expect(harness.pin(command).decision == .allow)
    let door = harness.door(command)
    guard case .deny(let deny) = door.decision else {
        Issue.record("door must deny executing python os.system reset, got \(door.decision)")
        return
    }
    #expect(deny.ruleID.pack == ActionPolicyEngine.Builtin.pack)
}

/// Pin allow / door unwrap-limited. Fails if `door` is pack `evaluate`.
@Test func corpus_door_bashDashCDollarCMD_isUnwrapLimited() throws {
    let harness = try DayOneHarness.load()
    let command = "bash -c $CMD"
    #expect(harness.pin(command).decision == .allow)
    let door = harness.door(command)
    guard case .deny(let deny) = door.decision else {
        Issue.record("door must deny unwrap-limited $CMD, got \(door.decision)")
        return
    }
    #expect(deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
}

/// Pin allow / door remote-branch Ask. Fails if `door` is pack `evaluate`.
@Test func corpus_door_forceWithLeaseFeature_tightensPackAllow() throws {
    let harness = try DayOneHarness.load()
    let command = "git push --force-with-lease origin feature"
    #expect(harness.pin(command).decision == .allow)
    let door = harness.door(command)
    guard case .deny(let deny) = door.decision else {
        Issue.record("door must deny force-with-lease to a named branch, got \(door.decision)")
        return
    }
    #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteBranchAsk.ruleID)
}
