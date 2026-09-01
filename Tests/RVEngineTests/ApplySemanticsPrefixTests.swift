import Testing
import RVDomain
@testable import RVEngine

@Suite("ApplySemantics prefix wrappers")
struct ApplySemanticsPrefixTests {
    @Test func timeoutReset_matchesDirectDecision() throws {
        let directCommand = "git reset --hard"
        let wrappedCommand = "timeout 1 git reset --hard"
        let directPack = try runSemanticsPack(directCommand)
        let wrappedPack = try runSemanticsPack(wrappedCommand)
        let direct = applySemantics(
            pack: directPack,
            command: ShellCommand(rawValue: directCommand)
        )
        let wrapped = applySemantics(
            pack: wrappedPack,
            command: ShellCommand(rawValue: wrappedCommand)
        )
        #expect(direct.decision == wrapped.decision)
        guard case .deny = direct.decision else {
            Issue.record("direct reset --hard must deny")
            return
        }
        #expect(wrapped.analysis.innermost == direct.analysis.innermost)
        #expect(wrapped.analysis.wrappers == [.timeout])
    }

    @Test func niceReset_matchesDirectDecision() throws {
        let directCommand = "git reset --hard"
        let wrappedCommand = "nice git reset --hard"
        let directPack = try runSemanticsPack(directCommand)
        let wrappedPack = try runSemanticsPack(wrappedCommand)
        let direct = applySemantics(
            pack: directPack,
            command: ShellCommand(rawValue: directCommand)
        )
        let wrapped = applySemantics(
            pack: wrappedPack,
            command: ShellCommand(rawValue: wrappedCommand)
        )
        #expect(direct.decision == wrapped.decision)
        guard case .deny = direct.decision else {
            Issue.record("direct reset --hard must deny")
            return
        }
        #expect(wrapped.analysis.innermost == direct.analysis.innermost)
        #expect(wrapped.analysis.wrappers == [.nice])
    }

    @Test func miseExecReset_matchesDirectDecision() throws {
        let directCommand = "git reset --hard"
        let wrappedCommand = "mise exec -c 'git reset --hard'"
        let directPack = try runSemanticsPack(directCommand)
        let wrappedPack = try runSemanticsPack(wrappedCommand)
        let direct = applySemantics(
            pack: directPack,
            command: ShellCommand(rawValue: directCommand)
        )
        let wrapped = applySemantics(
            pack: wrappedPack,
            command: ShellCommand(rawValue: wrappedCommand)
        )
        #expect(direct.decision == wrapped.decision)
        guard case .deny = direct.decision else {
            Issue.record("direct reset --hard must deny")
            return
        }
        #expect(wrapped.analysis.innermost == direct.analysis.innermost)
        #expect(wrapped.analysis.wrappers == [.mise])
    }

    @Test func sshForceWithLease_isDeniedBySemantics() throws {
        let command = "ssh h 'git push --force-with-lease origin main'"
        let pack = try runSemanticsPack(command)
        #expect(pack.decision == .allow)
        let composed = applySemantics(
            pack: pack,
            command: ShellCommand(rawValue: command),
            gitContext: GitAnalysisContext(isSharedBranch: true)
        )
        guard case .deny(let deny) = composed.decision else {
            Issue.record("ssh force-with-lease to main must deny, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID)
        #expect(composed.analysis.gitAction != nil)
        #expect(composed.analysis.wrappers == [.ssh])
    }

    @Test func sshReset_matchesDirectDecision() throws {
        let directCommand = "git reset --hard"
        let wrappedCommand = "ssh example 'git reset --hard'"
        let directPack = try runSemanticsPack(directCommand)
        let wrappedPack = try runSemanticsPack(wrappedCommand)
        let direct = applySemantics(
            pack: directPack,
            command: ShellCommand(rawValue: directCommand)
        )
        let wrapped = applySemantics(
            pack: wrappedPack,
            command: ShellCommand(rawValue: wrappedCommand)
        )
        #expect(direct.decision == wrapped.decision)
        guard case .deny = direct.decision else {
            Issue.record("direct reset --hard must deny")
            return
        }
        #expect(wrapped.analysis.innermost == direct.analysis.innermost)
        #expect(wrapped.analysis.wrappers == [.ssh])
    }
}

private func runSemanticsPack(_ command: String) throws -> EvaluationResult {
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
    return evaluate(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: packs,
        patterns: engine,
        compiled: compiled
    )
}
