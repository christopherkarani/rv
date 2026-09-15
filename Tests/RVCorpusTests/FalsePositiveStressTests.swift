import Foundation
import Testing
import RVDomain
import RVEngine
import RVPacks

/// Pin `evaluate` over-block net: a deny here is a false-positive block.
///
/// Run:
/// `tools/gate.sh --quiet RVCorpusTests --filter FalsePositiveStress`
///
/// Product door (`evaluateWithSemantics`) may tighten a pack allow (Ask / shared
/// branch). That is not a pin false positive. Data-role never-slip rows must
/// still allow on the door.
@Suite("False-positive stress")
struct FalsePositiveStressTests {
    /// Landmine commands from `.grok/skills/swift-evaluate-parity/references/landmines.md`.
    static let landmineCommands: [String] = [
        "git push --force-with-lease",
        "git push --force-with-lease --force-if-includes",
        "git push origin feature--force",
        "git push origin feature-f",
        "git push origin main && echo done --force",
        "git commit -m \"git push --force\"",
        "git restore . --staged",
        "git restore file.txt --staged",
        "echo \"git reset --hard\"",
        "rg -n \"rm -rf\"",
        "git checkout -b",
    ]

    static let requiredNearMissIDs: [String] = [
        "near.force-with-lease",
        "near.force-with-lease-if-includes",
        "near.branch-name-force",
        "near.branch-name-f",
        "near.later-segment-force",
        "near.git-commit-force-message",
        "near.restore-dot-staged",
        "near.restore-file-staged",
        "near.echo-quoted-reset",
        "near.rg-quoted-rm",
        "near.checkout-new-branch",
        "near.git-log-grep-reset",
        "near.git-grep-rm-rf",
    ]

    static let truePositiveDenies: [(command: String, ruleID: String)] = [
        ("git reset --hard", "core.git:reset-hard"),
        ("git push --force", "core.git:push-force-long"),
        ("git clean -fd", "core.git:clean-force"),
        ("rm -rf /", "core.filesystem:rm-rf-root-home"),
    ]

    static let doorMustAllow: [String] = [
        "echo 'git reset --hard'",
        "echo \"rm -rf /\"",
        "printf '%s\\n' 'git reset --hard'",
        "git commit -m \"git reset --hard\"",
        "git commit -m \"git push --force\"",
        "rg -n \"rm -rf\"",
        "git log --grep='git reset --hard'",
        "git grep -n \"rm -rf\"",
        "python3 -c \"print('git reset --hard')\"",
        "python -c \"print('git reset --hard')\"",
        "node -e \"console.log('git reset --hard')\"",
        "ruby -e \"puts 'git reset --hard'\"",
        "git checkout -b topic",
        "git status",
        "git stash drop",
        "git restore . --staged",
        "git push --force-with-lease",
        "git push origin feature--force",
        "git push origin feature-f",
        "ls -la",
    ]

    /// Door may tighten these pack allows. Not a pin over-block.
    static let doorMayTighten: Set<String> = [
        "git push --force-with-lease origin feature",
        "git push --force-with-lease=origin/main",
    ]

    @Test func nearMiss_keepsRequiredLandmineRows() throws {
        let ids = Set(try loadCorpus("near-miss.json").compactMap(\.id))
        for id in Self.requiredNearMissIDs {
            #expect(ids.contains(id), "near-miss.json lost required landmine \(id)")
        }
    }

    @Test func pinEvaluate_truePositivesStillDeny() throws {
        for row in Self.truePositiveDenies {
            let result = try evaluatePin(row.command)
            guard case .deny(let deny) = result.decision else {
                Issue.record("true-positive must deny \(row.command), got \(describe(result))")
                continue
            }
            #expect(deny.ruleID.rawValue == row.ruleID, "\(row.command)")
        }
    }

    @Test func pinEvaluate_nearMissCorpus_doesNotDeny() throws {
        try assertPinAllows(try loadCorpus("near-miss.json"), source: "near-miss")
    }

    @Test func pinEvaluate_skillTableAllows_doNotDeny() throws {
        let rows = try loadCorpus("skill-table.json").filter { $0.expected == "allow" }
        try assertPinAllows(rows, source: "skill-table-allow")
    }

    @Test func pinEvaluate_stressCorpus_doesNotDeny() throws {
        try assertPinAllows(try loadCorpus("false-positive-stress.json"), source: "stress")
    }

    @Test func pinEvaluate_landmineDataRoleVariants_doNotDeny() throws {
        var seen = Set<String>()
        for seed in Self.landmineCommands {
            for command in dataRoleVariants(of: seed) where seen.insert(command).inserted {
                let result = try evaluatePin(command)
                if result.decision != .allow {
                    Issue.record(
                        "over-block \(describe(result)) on landmine variant: \(command)"
                    )
                }
            }
        }
    }

    @Test func pinEvaluate_skillAllowDataRoleVariants_doNotDeny() throws {
        let seeds = try loadCorpus("skill-table.json")
            .filter { $0.expected == "allow" }
            .compactMap(\.command)
        var seen = Set<String>()
        var overBlocks = 0
        for seed in seeds {
            for command in dataRoleVariants(of: seed) where seen.insert(command).inserted {
                let result = try evaluatePin(command)
                if result.decision != .allow {
                    overBlocks += 1
                    Issue.record(
                        "over-block \(describe(result)) on skill-allow variant: \(command)"
                    )
                }
            }
        }
        #expect(overBlocks == 0)
    }

    @Test func door_doesNotDenyDataRoleOrQuietLocal() throws {
        for command in Self.doorMustAllow {
            let result = try evaluateDoor(command)
            if result.decision != .allow {
                Issue.record("door over-block \(describe(result)) on \(command)")
            }
        }
    }

    @Test func door_namedForceWithLease_isSemanticTightenNotPinOverBlock() throws {
        let pin = try evaluatePin("git push --force-with-lease origin feature")
        #expect(pin.decision == .allow, "pin must still allow, got \(describe(pin))")
        let door = try evaluateDoor("git push --force-with-lease origin feature")
        let ask = ActionPolicyEngine.Builtin.remoteBranchAsk
        #expect(door.decision == .deny(ask))
        #expect(Self.doorMayTighten.contains("git push --force-with-lease origin feature"))
    }
}

private func assertPinAllows(_ rows: [CorpusCase], source: String) throws {
    for row in rows {
        guard let command = row.command, row.expected == "allow" || row.expected == nil else {
            continue
        }
        let result = try evaluatePin(command)
        if result.decision != .allow {
            Issue.record("\(source) \(row.id) over-block \(describe(result))")
            continue
        }
        if let ruleID = row.ruleID {
            #expect(result.matched?.ruleID.rawValue == ruleID, "\(source) \(row.id)")
        }
    }
}

private func dataRoleVariants(of command: String) -> [String] {
    var variants = [
        command,
        " \(command) ",
        "\t\(command)",
    ]
    guard command.contains("'") == false else { return variants }
    variants.append("echo '\(command)'")
    variants.append("printf '%s\\n' '\(command)'")
    if command.hasPrefix("git commit") == false {
        variants.append("git commit -m '\(command)'")
    }
    if command.hasPrefix("rg ") == false {
        variants.append("rg -n '\(command)'")
    }
    if command.contains("print(") == false, command.contains("console.log") == false {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        variants.append("python3 -c \"print('\(escaped)')\"")
    }
    return variants
}

private func evaluatePin(_ command: String) throws -> EvaluationResult {
    let packs = try PackRegistry.loadDayOne()
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    return evaluate(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: packs,
        engine: engine,
        compiled: compiled
    )
}

private func evaluateDoor(_ command: String) throws -> EvaluationResult {
    let packs = try PackRegistry.loadDayOne()
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    return evaluateWithSemantics(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: packs,
        engine: engine,
        compiled: compiled
    )
}

private func describe(_ result: EvaluationResult) -> String {
    switch result.decision {
    case .allow:
        if let ruleID = result.matched?.ruleID.rawValue {
            return "allow+\(ruleID)"
        }
        return "allow"
    case .deny(let deny):
        return "deny \(deny.ruleID.rawValue)"
    case .indeterminate(let reason):
        return "indeterminate \(reason.rawValue)"
    }
}

private func loadCorpus(_ name: String) throws -> [CorpusCase] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("RVEngineTests/Fixtures/corpus")
        .appendingPathComponent(name)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(CorpusFile.self, from: data).cases
}
