import Foundation
import Testing
import RVDomain

@Suite("HostNativeAsk")
struct HostNativeAskTests {
    private let askDeny = Deny(
        ruleID: RuleID(pack: PackID(rawValue: "builtin.action"), pattern: "remote-branch-mutation"),
        reason: "Remote branch mutation requires a human."
    )
    private let packDeny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes"
    )

    @Test func leftoverAskIsNeverAPermit() {
        #expect(HostNativeAsk.leftoverAskIsPermit("ask") == false)
        #expect(HostNativeAsk.leftoverAskIsPermit("allow") == false)
        #expect(HostNativeAsk.leftoverAskDeny.ruleID.rawValue == "builtin.action:leftover-ask")
    }

    @Test func leftoverAskDecisionDecodesAsDenyNotAllow() throws {
        let data = Data(#"{"decision":"ask"}"#.utf8)
        let decoded = try JSONDecoder().decode(Decision.self, from: data)
        #expect(decoded == .deny(HostNativeAsk.leftoverAskDeny))
        #expect(decoded != .allow)
    }

    @Test(arguments: [HookHost.pi, .opencode, .claude, .hermes])
    func spendFirstHostsPauseOnMandatoryHuman(_ host: HookHost) throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git push --force origin topic")
        )
        let verdict = HostNativeAsk.verdict(
            host: host,
            result: result,
            cwd: cwd,
            bound: .mandatoryHuman(askDeny),
            continuation: .hostNative
        )
        #expect(verdict == .ask(.hostNative))
        #expect(HostNativeAsk.capability(for: host) == .spendFirst)
    }

    @Test(arguments: [HookHost.grok, .openclaw, .codex, .cursor])
    func denyOrTTYHostsDoNotPauseOnMandatoryHuman(_ host: HookHost) throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git push --force origin topic")
        )
        let verdict = HostNativeAsk.verdict(
            host: host,
            result: result,
            cwd: cwd,
            bound: .mandatoryHuman(askDeny),
            continuation: .hostNative
        )
        #expect(verdict == .deny)
        #expect(HostNativeAsk.capability(for: host) == .denyOrTTY)
    }

    @Test func capabilityTable_spendFirstAndDenyOrTTYHosts() {
        #expect(HostNativeAsk.capability(for: .pi) == .spendFirst)
        #expect(HostNativeAsk.capability(for: .opencode) == .spendFirst)
        #expect(HostNativeAsk.capability(for: .claude) == .spendFirst)
        #expect(HostNativeAsk.capability(for: .hermes) == .spendFirst)
        #expect(HostNativeAsk.capability(for: .codex) == .denyOrTTY)
        #expect(HostNativeAsk.capability(for: .cursor) == .denyOrTTY)
        #expect(HostNativeAsk.capability(for: .grok) == .denyOrTTY)
    }

    @Test func packDecisionDenyStaysDeny() {
        let denied = Decision.deny(packDeny)
        let verdict: PackDoorVerdict = HostNativeAsk.verdict(denied)
        #expect(verdict == .deny)
    }

    @Test func packDecisionAllowIsAllow() {
        let verdict: PackDoorVerdict = HostNativeAsk.verdict(.allow)
        #expect(verdict == .allow)
    }

    @Test func packDecisionIndeterminateIsDeny() {
        let verdict: PackDoorVerdict = HostNativeAsk.verdict(.indeterminate(.commandTooLarge))
        #expect(verdict == .deny)
    }

    @Test func hostNativeBridgeSpendsOnPiAndOpenCodeAllowOnce() {
        let bridge = HostNativeApprovalBridge()
        #expect(
            bridge.resolve(host: .pi, continuation: .hostNative, decision: .allowOnce)
                == .spendThenAllow
        )
        #expect(
            bridge.resolve(host: .opencode, continuation: .hostNative, decision: .allowOnce)
                == .spendThenAllow
        )
        #expect(
            bridge.resolve(host: .claude, continuation: .hostNative, decision: .allowOnce)
                == .spendThenAllow
        )
        #expect(
            bridge.resolve(host: .hermes, continuation: .hostNative, decision: .allowOnce)
                == .spendThenAllow
        )
        #expect(
            bridge.resolve(host: .grok, continuation: .hostNative, decision: .allowOnce)
                == .denyOrTTY
        )
        #expect(
            bridge.resolve(host: .codex, continuation: .hostNative, decision: .allowOnce)
                == .denyOrTTY
        )
        #expect(
            bridge.resolve(host: .cursor, continuation: .hostNative, decision: .allowOnce)
                == .denyOrTTY
        )
        #expect(
            bridge.resolve(host: .pi, continuation: .hostNative, decision: .deny) == .deny
        )
        #expect(
            bridge.resolve(host: .opencode, continuation: .hostNative, decision: .deny) == .deny
        )
    }

    @Test func doorVerdict_unlockablePackDenyAsksOnSpendFirst() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(
            HostNativeAsk.verdict(
                host: .pi,
                result: result,
                cwd: cwd,
                bound: .deny(packDeny)
            ) == .ask(.hostNative)
        )
        #expect(
            HostNativeAsk.verdict(
                host: .opencode,
                result: result,
                cwd: cwd,
                bound: .deny(packDeny)
            ) == .ask(.hostNative)
        )
        #expect(
            HostNativeAsk.verdict(
                host: .claude,
                result: result,
                cwd: cwd,
                bound: .deny(packDeny)
            ) == .ask(.hostNative)
        )
        #expect(
            HostNativeAsk.verdict(
                host: .hermes,
                result: result,
                cwd: cwd,
                bound: .deny(packDeny)
            ) == .ask(.hostNative)
        )
        #expect(
            HostNativeAsk.verdict(
                host: .grok,
                result: result,
                cwd: cwd,
                bound: .deny(packDeny)
            ) == .deny
        )
        #expect(
            HostNativeAsk.verdict(
                host: .codex,
                result: result,
                cwd: cwd,
                bound: .deny(packDeny)
            ) == .deny
        )
        #expect(
            HostNativeAsk.verdict(
                host: .cursor,
                result: result,
                cwd: cwd,
                bound: .deny(packDeny)
            ) == .deny
        )
    }

    @Test func doorVerdict_missingCwdNeverAsks() {
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(
            HostNativeAsk.verdict(
                host: .pi,
                result: result,
                cwd: nil,
                bound: .deny(packDeny)
            ) == .deny
        )
        #expect(
            HostNativeAsk.verdict(
                host: .pi,
                result: result,
                cwd: nil,
                bound: .mandatoryHuman(askDeny)
            ) == .deny
        )
    }

    @Test func doorVerdict_emptyMatchingViewNeverAsks() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let packResult = EvaluationResult(outcome: .deny(packDeny, matched: nil))
        #expect(
            HostNativeAsk.verdict(
                host: .pi,
                result: packResult,
                cwd: cwd,
                bound: .deny(packDeny)
            ) == .deny
        )
        let humanResult = EvaluationResult(outcome: .plain)
        #expect(
            HostNativeAsk.verdict(
                host: .pi,
                result: humanResult,
                cwd: cwd,
                bound: .mandatoryHuman(askDeny)
            ) == .deny
        )
    }

    @Test func doorVerdict_secretPathNeverAsks() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let secret = Deny(
            ruleID: RuleID(pack: .coreSecrets, pattern: "aws-credentials"),
            reason: "secret path"
        )
        let result = EvaluationResult(
            outcome: .deny(secret, matched: nil),
            matchingView: MatchingView("cat ~/.aws/credentials")
        )
        #expect(
            HostNativeAsk.verdict(
                host: .pi,
                result: result,
                cwd: cwd,
                bound: .deny(secret)
            ) == .deny
        )
    }

    @Test func doorVerdict_builtinHardDenyNeverAsks() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let leftover = HostNativeAsk.leftoverAskDeny
        let result = EvaluationResult(
            outcome: .deny(leftover, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(
            HostNativeAsk.verdict(
                host: .pi,
                result: result,
                cwd: cwd,
                bound: .deny(leftover)
            ) == .deny
        )
    }

    @Test func doorVerdict_mandatoryHumanAsksWhenSpendable() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git push --force origin topic")
        )
        #expect(
            HostNativeAsk.verdict(
                host: .pi,
                result: result,
                cwd: cwd,
                bound: .mandatoryHuman(askDeny)
            ) == .ask(.hostNative)
        )
        #expect(
            HostNativeAsk.verdict(
                host: .claude,
                result: result,
                cwd: cwd,
                bound: .mandatoryHuman(askDeny)
            ) == .ask(.hostNative)
        )
        #expect(
            HostNativeAsk.verdict(
                host: .hermes,
                result: result,
                cwd: cwd,
                bound: .mandatoryHuman(askDeny)
            ) == .ask(.hostNative)
        )
    }

    @Test func doorVerdict_boundAllowOnPackDenyNeverAsks() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(
            HostNativeAsk.verdict(
                host: .pi,
                result: result,
                cwd: cwd,
                bound: .allow
            ) == .deny
        )
    }

    @Test func hookBound_hardPolicyCases_projectDirectly() {
        #expect(HostNativeAsk.hookBound(.hardAllow) == .allow)
        #expect(HostNativeAsk.hookBound(.hardDeny(packDeny)) == .deny(packDeny))
        #expect(
            HostNativeAsk.hookBound(.mandatoryHuman(askDeny))
                == .mandatoryHuman(askDeny)
        )
        #expect(
            HostNativeAsk.hookBound(.reviewEligible(fallback: askDeny)) == .allow
        )
    }

    @Test func hookBound_emptyEffectsPackAllow_isAllow() {
        let action = HostNativeAskFixtures.emptyEffects(command: "git status")
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git status")
        )

        #expect(
            HostNativeAsk.hookBound(
                result: result,
                action: action,
                context: HostNativeAskFixtures.privateContext
            ) == .allow
        )
    }

    @Test func hookBound_emptyEffectsPackDeny_staysDeny() {
        let action = HostNativeAskFixtures.emptyEffects(command: "git reset --hard")
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )

        #expect(
            HostNativeAsk.hookBound(
                result: result,
                action: action,
                context: HostNativeAskFixtures.privateContext
            ) == .deny(packDeny)
        )
    }

    @Test func hookBound_remoteMutationOnPrivateBranch_requiresHuman() {
        let action = HostNativeAskFixtures.remoteMutation(branchName: "topic")
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git push --force origin topic")
        )

        #expect(
            HostNativeAsk.hookBound(
                result: result,
                action: action,
                context: HostNativeAskFixtures.privateContext
            ) == .mandatoryHuman(ActionPolicyEngine.Builtin.remoteBranchAsk)
        )
    }

    @Test func hookBound_remoteMutationOnSharedContext_isHardDeny() {
        let action = HostNativeAskFixtures.remoteMutation(branchName: "topic")
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git push --force origin topic")
        )

        #expect(
            HostNativeAsk.hookBound(
                result: result,
                action: action,
                context: HostNativeAskFixtures.sharedContext
            ) == .deny(ActionPolicyEngine.Builtin.remoteSharedBranch)
        )
    }

    @Test func hookBound_workingTreeDiscard_isDenied() {
        let action = HostNativeAskFixtures.workingTreeDiscard(command: "git checkout -- file.swift")
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git checkout -- file.swift")
        )

        #expect(
            HostNativeAsk.hookBound(
                result: result,
                action: action,
                context: HostNativeAskFixtures.privateContext
            ) == .deny(ActionPolicyEngine.Builtin.workingTreeDiscard)
        )
    }
}

private enum HostNativeAskFixtures {
    static let privateContext = ReviewContext(
        repository: RepositoryReviewContext(isSharedBranch: false)
    )
    static let sharedContext = ReviewContext(
        repository: RepositoryReviewContext(isSharedBranch: true)
    )

    static func emptyEffects(command: String) -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:host-native-ask"),
                scope: ActionScope(
                    workingDirectory: WorkingDirectory(validating: "/tmp/rv")
                ),
                supportingCommand: ShellCommand(rawValue: command)
            )
        )
    }

    static func remoteMutation(branchName: String) -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:remote-mutation:\(branchName)"),
                effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                resources: ActionResources(remoteName: "origin", branchName: branchName),
                scope: ActionScope(
                    workingDirectory: WorkingDirectory(validating: "/tmp/rv")
                ),
                supportingCommand: ShellCommand(
                    rawValue: "git push --force origin \(branchName)"
                )
            )
        )
    }

    static func workingTreeDiscard(command: String) -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "shell:working-tree-discard"),
                effects: ActionEffects(kinds: [.workingTreeDiscard]),
                scope: ActionScope(
                    workingDirectory: WorkingDirectory(validating: "/tmp/rv")
                ),
                supportingCommand: ShellCommand(rawValue: command)
            )
        )
    }
}
