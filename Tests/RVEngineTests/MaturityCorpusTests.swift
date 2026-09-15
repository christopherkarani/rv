import Testing
import RVDomain
@testable import RVEngine

/// Never-slip vs quiet work at the product door (`evaluateWithSemantics`).
/// Pin pack `evaluate` is a different scoreboard (RV-RR-02).
@Suite("Maturity corpus")
struct MaturityCorpusTests {
    struct DenyRow: Sendable, CustomTestStringConvertible {
        var command: String
        var ruleID: RuleID
        var testDescription: String { "\(command) → \(ruleID.rawValue)" }
    }

    struct AllowRow: Sendable, CustomTestStringConvertible {
        var command: String
        var testDescription: String { command }
    }

    static let denyRows: [DenyRow] = [
        .init(
            command: "git reset --hard",
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard")
        ),
        .init(
            command: "bash -c 'git reset --hard'",
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard")
        ),
        .init(
            command: "sudo env sh -c 'git reset --hard'",
            ruleID: RuleID(pack: .coreGit, pattern: "reset-hard")
        ),
        .init(
            command: "bash -c $CMD",
            ruleID: ActionPolicyEngine.Builtin.unwrapLimited.ruleID
        ),
        .init(
            command: "cat ~/.ssh/id_rsa",
            ruleID: RuleID(pack: .coreSecrets, pattern: "id-rsa")
        ),
    ]

    static let allowRows: [AllowRow] = [
        .init(command: "echo 'git reset --hard'"),
        .init(command: "git checkout -b topic"),
    ]

    @Test(arguments: denyRows)
    func door_deniesNeverSlip(_ row: DenyRow) throws {
        let result = try runDoor(row.command)
        guard case .deny(let deny) = result.decision else {
            Issue.record("never-slip must deny \(row.command), got \(result.decision)")
            return
        }
        #expect(deny.ruleID == row.ruleID)
    }

    @Test(arguments: allowRows)
    func door_allowsQuietWork(_ row: AllowRow) throws {
        let result = try runDoor(row.command)
        #expect(result.decision == .allow)
    }

    @Test func door_pythonOsSystemReset_denies() throws {
        let result = try runDoor(#"python -c "os.system('git reset --hard')""#)
        guard case .deny = result.decision else {
            Issue.record("python os.system reset --hard must deny, got \(result.decision)")
            return
        }
        #expect(result.analysis.gitAction == .reset(mode: .hard, target: nil))
        #expect(result.analysis.wrappers == [.python])
    }

    @Test func door_pythonPrintReset_allows() throws {
        // RV-RR-02: pack walk may still see print guts; door must allow.
        let result = try runDoor(#"python -c "print('git reset --hard')""#)
        #expect(result.decision == .allow)
    }

    @Test func door_forceWithLeaseFeature_isAskNotNeverSlip() throws {
        // Dual-view: pin `evaluate` / `near.force-with-lease` still allows (landmine).
        // Today's product door Ask-maps-to-deny (`remoteBranchAsk`) — not never-slip.
        let result = try runDoor("git push --force-with-lease origin feature")
        let ask = ActionPolicyEngine.Builtin.remoteBranchAsk
        #expect(result.decision == .deny(ask))
        #expect(result.boundReview == .mandatoryHuman(ask))
    }
}

private func runDoor(
    _ command: String,
    gitContext: GitAnalysisContext = .empty,
    filesystemProbe: (UnwrapOutcome) -> FilesystemAnalysisWorld = { _ in .unprobed },
    policy: EffectiveActionPolicy = .empty
) throws -> EvaluationResult {
    let packs = [
        PackSnapshot(
            id: .coreFilesystem,
            name: "fs",
            description: "fs",
            keywords: ["rm"],
            safe: [],
            destructive: [
                DestructiveRule(
                    name: "rm-rf-general",
                    pattern: #"rm\s+-rf"#,
                    severity: .high,
                    reason: "rm -rf is destructive"
                ),
            ]
        ),
        PackSnapshot(
            id: .coreGit,
            name: "git",
            description: "git",
            keywords: ["git"],
            safe: [NamedPattern(name: "checkout-new-branch", pattern: #"git\s+checkout\s+-b\s+"#)],
            destructive: [
                DestructiveRule(
                    name: "reset-hard",
                    pattern: #"git\s+reset\s+--hard"#,
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes"
                ),
            ]
        ),
    ]
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    return evaluateWithSemantics(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: packs,
        patterns: engine,
        compiled: compiled,
        gitContext: gitContext,
        filesystemProbe: filesystemProbe,
        policy: policy
    )
}
