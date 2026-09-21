import Foundation
import Testing
import RVDomain
import RVEngine
import RVPacks

/// Agent-shaped command parse net: pin `evaluate` plus the product door.
///
/// Run: `Scripts/gate.sh --quiet RVCorpusTests --filter AgentParseStress`
///
/// Over-block = pin deny on search / docs / echo guts that are not executing
/// shell. Door unwrap-limited on unquoted / `$` interpreter payloads is
/// fail-closed never-slip: the inner program is unknown. A quoted `-c`/`-e`
/// body rv captured is known source and pack-grades like a script file.
@Suite("Agent parse stress")
struct AgentParseStressTests {
    static let requiredNearMissIDs: [String] = [
        "near.force-with-lease",
        "near.echo-quoted-reset",
        "near.echo-unquoted-reset",
        "near.rg-quoted-rm",
        "near.git-log-grep-reset",
        "near.git-grep-rm-rf",
        "near.git-log-pickaxe-reset",
        "near.tldr-reset-hard",
        "near.man-reset-hard",
        "near.find-name-rm-rf",
        "near.checkout-new-branch",
    ]

    static let truePositiveDenies: [(command: String, ruleID: String)] = [
        ("git reset --hard", "core.git:reset-hard"),
        ("git push --force", "core.git:push-force-long"),
        ("git clean -fd", "core.git:clean-force"),
        ("rm -rf /", "core.filesystem:rm-rf-root-home"),
        ("bash -c 'git reset --hard'", "core.git:reset-hard"),
    ]

    static let doorMustAllow: [String] = [
        "echo git reset --hard",
        "echo 'git reset --hard'",
        "printf '%s\\n' 'git reset --hard'",
        "tldr git reset --hard",
        "man git reset --hard",
        "git log --grep='git reset --hard'",
        "git grep -n \"rm -rf\"",
        "git log -S'git reset --hard'",
        "find . -name '*rm -rf*'",
        "git commit -m \"git reset --hard\"",
        "rg -n \"rm -rf\"",
        "python3 -c \"print('git reset --hard')\"",
        "python -c \"print('git reset --hard')\"",
        "python3 -c \"x = 1\"",
        "node -e \"console.log('git reset --hard')\"",
        "node -e \"const x = 1\"",
        "ruby -e \"puts 'git reset --hard'\"",
        "ruby -e \"x = 1\"",
        "bash -c 'git status'",
        "bash -lc 'git status --short'",
        "sh -c 'ls -la'",
        "zsh -c 'git log --oneline -5'",
        "git status",
        "git stash drop",
        "git checkout -b topic",
        "git push --force-with-lease",
        "ls -la",
    ]

    /// Door deny here is unwrap-limited never-slip: inner program unknown.
    static let doorUnwrapLimited: [String] = [
        "bash -c $CMD",
        "bash -c git status",
        "bash -c $'git status'",
        "python3 -c $CMD",
        "python3 -c \"$CMD\"",
        "python3 -c git status",
        "node -e $CMD",
    ]

    static let tokenizerMustSurvive: [String] = [
        "",
        "   ",
        "echo \"unterminated",
        "echo 'unterminated",
        "echo $(unclosed",
        "echo `unclosed",
        "git status &&",
        "git status ||",
        "; git status",
        "git status |",
        "echo 'git reset --hard' # comment",
        "git log --grep='git reset --hard' --oneline",
        "cd /tmp && git status && echo done",
        "GIT_DIR=.git git status",
        "command -v git",
        "nice git status",
        "timeout 10 git status",
        "/usr/bin/git status",
        "git -c core.pager=cat log --oneline",
        "printf '%s\n' $'line\\n'",
        "echo café git status",
        String(repeating: "a", count: 4_096),
    ]

    @Test func nearMiss_keepsRequiredParseRows() throws {
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

    @Test func pinEvaluate_agentParseCorpus_doesNotDeny() throws {
        try assertPinAllows(try loadCorpus("agent-parse-stress.json"), source: "agent-parse")
    }

    @Test func pinEvaluate_skillTableAllows_doNotDeny() throws {
        let rows = try loadCorpus("skill-table.json").filter { $0.expected == "allow" }
        try assertPinAllows(rows, source: "skill-table-allow")
    }

    @Test func door_doesNotDenyDataRoleOrQuotedQuietWrappers() throws {
        for command in Self.doorMustAllow {
            let result = try evaluateDoor(command)
            if result.decision != .allow {
                Issue.record("door over-block \(describe(result)) on \(command)")
            }
        }
    }

    @Test func door_unparseableExecutingWrappers_areUnwrapLimited() throws {
        for command in Self.doorUnwrapLimited {
            let pin = try evaluatePin(command)
            #expect(pin.decision == .allow, "pin must allow \(command), got \(describe(pin))")
            let door = try evaluateDoor(command)
            guard case .deny(let deny) = door.decision else {
                Issue.record("door must unwrap-limited-deny \(command), got \(describe(door))")
                continue
            }
            #expect(
                deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID,
                "unwrap-limited \(command)"
            )
        }
    }

    @Test func door_namedForceWithLease_isSemanticTightenNotPinOverBlock() throws {
        let command = "git push --force-with-lease origin feature"
        let pin = try evaluatePin(command)
        #expect(pin.decision == .allow, "pin must still allow, got \(describe(pin))")
        let door = try evaluateDoor(command)
        let ask = ActionPolicyEngine.Builtin.remoteBranchAsk
        #expect(door.decision == .deny(ask))
    }

    @Test func tokenizer_messyAgentCommands_doNotCrash() throws {
        for command in Self.tokenizerMustSurvive {
            let view = Normalize.matchingView(of: command)
            let pin = try evaluatePin(command)
            let door = try evaluateDoor(command)
            #expect(view.rawValue.utf8.count <= max(command.utf8.count, 1) + 64)
            _ = pin.decision
            _ = door.decision
        }
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
