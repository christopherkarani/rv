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
        #expect(HostNativeAsk.leftoverAskIsPermit == false)
        #expect(HostNativeAsk.leftoverAskDeny.ruleID.rawValue == "builtin.action:leftover-ask")
    }

    @Test func leftoverAskDecisionDecodesAsDenyNotAllow() throws {
        let data = Data(#"{"decision":"ask"}"#.utf8)
        let decoded = try JSONDecoder().decode(Decision.self, from: data)
        #expect(decoded == .deny(HostNativeAsk.leftoverAskDeny))
        #expect(decoded != .allow)
    }

    /// Exhaustive: a new `HookHost` must land in the capability table.
    /// Capability is routing only — no row manufactures ALLOW.
    @Test(arguments: HookHost.allCases)
    func capabilityTable_coversEveryHost(_ host: HookHost) {
        let capability = HostApprovalCapability.capability(for: host)
        #expect(capability.route == .rvOperatorUI)
        #expect(capability.nativeAskAuthoritative == false)
        #expect(capability.canBlockForHuman == false)
    }

    @Test(arguments: HookHost.allCases)
    func mandatoryHumanAsksEveryHost(_ host: HookHost) throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git push --force origin topic"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(askDeny)
        )
        let verdict = HookAuthorization.project(result: result, cwd: cwd).verdict
        // Step 8B: caller-selected host can never convert ASK to ALLOW,
        // and ASK no longer depends on host at all.
        #expect(verdict != .allow, "\(host)")
        #expect(verdict == .ask, "\(host)")
    }

    @Test func packDecisionDenyAsksWhenUnlockable() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(HookAuthorization.project(result: result, cwd: cwd).verdict == .ask)
    }

    @Test func packDecisionAllowIsAllow() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git status")
        )
        #expect(HookAuthorization.project(result: result, cwd: cwd).verdict == .allow)
    }

    @Test func packDecisionIndeterminateIsDeny() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .indeterminate(.commandTooLarge),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(HookAuthorization.project(result: result, cwd: cwd).verdict == .deny)
    }

    @Test(arguments: HookHost.allCases)
    func unlockablePackDenyAsksEveryHost(_ host: HookHost) throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        let verdict = HookAuthorization.project(result: result, cwd: cwd).verdict
        #expect(verdict == .ask, "\(host)")
        #expect(verdict != .allow, "\(host)")
    }

    @Test func doorVerdict_missingCwdNeverAsks() {
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(
            HookAuthorization.project(
                result: result,
                cwd: nil
            ).verdict == .deny
        )
        let human = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(askDeny)
        )
        #expect(
            HookAuthorization.project(
                result: human,
                cwd: nil
            ).verdict == .deny
        )
    }

    @Test func doorVerdict_emptyMatchingViewNeverAsks() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let packResult = EvaluationResult(outcome: .deny(packDeny, matched: nil))
        #expect(
            HookAuthorization.project(
                result: packResult,
                cwd: cwd
            ).verdict == .deny
        )
        let humanResult = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView(""),
            analysis: .unknown,
            boundReview: .mandatoryHuman(askDeny)
        )
        #expect(
            HookAuthorization.project(
                result: humanResult,
                cwd: cwd
            ).verdict == .deny
        )
    }

    @Test func doorVerdict_unwrapLimitedPackDenyNeverAsks() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("bash -c git reset --hard"),
            analysis: .unwrapLimited.wrapping([.bash])
        )
        #expect(
            HookAuthorization.project(
                result: result,
                cwd: cwd
            ).verdict == .deny
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
            HookAuthorization.project(
                result: result,
                cwd: cwd
            ).verdict == .deny
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
            HookAuthorization.project(
                result: result,
                cwd: cwd
            ).verdict == .deny
        )
    }

    @Test func doorVerdict_boundAllowOnPackDenyNeverAsks() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard"),
            analysis: .unknown,
            boundReview: .allow
        )
        #expect(
            HookAuthorization.project(
                result: result,
                cwd: cwd
            ).verdict == .deny
        )
    }

    @Test func packProjected_usesBoundReviewWhenPresent() {
        #expect(
            BoundReview.packProjected(
                from: EvaluationResult(
                    outcome: .plain,
                    matchingView: MatchingView("git push --force origin topic"),
                    analysis: .unknown,
                    boundReview: .mandatoryHuman(askDeny)
                )
            ) == .mandatoryHuman(askDeny)
        )
    }

    @Test func packProjected_packDenyWithoutBindStaysDeny() {
        #expect(
            BoundReview.packProjected(
                from: EvaluationResult(
                    outcome: .deny(packDeny, matched: nil),
                    matchingView: MatchingView("git reset --hard")
                )
            ) == .deny(packDeny)
        )
    }

    @Test func packProjected_packAllowWithoutBindStaysAllow() {
        #expect(
            BoundReview.packProjected(
                from: EvaluationResult(
                    outcome: .plain,
                    matchingView: MatchingView("git status")
                )
            ) == .allow
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
        repository: RepositoryReviewContext(currentBranch: "feature")
    )
    static let sharedContext = ReviewContext(
        repository: RepositoryReviewContext(currentBranch: "main")
    )

    static func emptyEffects(command: String) -> ProposedAction {
        .shell(
            ShellAction.effectOnly(
                EffectShell(
                    fingerprint: ActionFingerprint(rawValue: "shell:host-native-ask"),
                    scope: ActionScope(
                        workingDirectory: WorkingDirectory(validating: "/tmp/rv")
                    ),
                    supportingCommand: ShellCommand(rawValue: command)
                )
            )
        )
    }

    static func remoteMutation(branchName: String) -> ProposedAction {
        .shell(
            ShellAction.effectOnly(
                EffectShell(
                    fingerprint: ActionFingerprint(rawValue: "shell:remote-mutation:\(branchName)"),
                    effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                    resources: .git(
                        remote: RemoteName("origin"),
                        ref: .branch(BranchName(branchName))
                    ),
                    scope: ActionScope(
                        workingDirectory: WorkingDirectory(validating: "/tmp/rv")
                    ),
                    supportingCommand: ShellCommand(
                        rawValue: "git push --force origin \(branchName)"
                    )
                )
            )
        )
    }

    static func workingTreeDiscard(command: String) -> ProposedAction {
        .shell(
            ShellAction.effectOnly(
                EffectShell(
                    fingerprint: ActionFingerprint(rawValue: "shell:working-tree-discard"),
                    effects: ActionEffects(kinds: [.workingTreeDiscard]),
                    scope: ActionScope(
                        workingDirectory: WorkingDirectory(validating: "/tmp/rv")
                    ),
                    supportingCommand: ShellCommand(rawValue: command)
                )
            )
        )
    }
}
