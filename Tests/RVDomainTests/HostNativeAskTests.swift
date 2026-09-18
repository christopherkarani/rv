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

    /// Exhaustive: a new `HookHost` must pick pause and fallbacks here.
    @Test(arguments: HookHost.allCases)
    func profileTable_coversEveryHost(_ host: HookHost) {
        let profile = HostNativeAsk.profile(for: host)
        switch host {
        case .pi, .opencode, .claude, .hermes, .openclaw:
            #expect(profile.pause == .spendFirst)
        case .grok:
            #expect(profile.pause == .noPause)
        case .codex, .cursor:
            #expect(profile.pause == .leftoverAskForbidden)
        }
        #expect(profile.grayAreaIfNoPause == .allow)
        #expect(profile.unlockableIfNoPause == .deny)
    }

    @Test(arguments: HookHost.allCases)
    func mandatoryHumanFollowsPauseProfile(_ host: HookHost) throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git push --force origin topic"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(askDeny)
        )
        let profile = HostNativeAsk.profile(for: host)
        let verdict = HostNativeAsk.hostAskVerdict(
            host: host,
            result: result,
            cwd: cwd,
            continuation: .hostNative
        )
        switch profile.pause {
        case .spendFirst:
            #expect(verdict == .ask(.hostNative))
        case .noPause, .leftoverAskForbidden:
            #expect(verdict == profile.grayAreaIfNoPause.verdict)
            #expect(verdict != .ask(.hostNative))
        }
    }

    @Test func packDecisionDenyStaysDeny() {
        let denied = Decision.deny(packDeny)
        let verdict = HostNativeAsk.packDoorVerdict(for: denied)
        #expect(verdict == .deny)
    }

    @Test func packDecisionAllowIsAllow() {
        let verdict = HostNativeAsk.packDoorVerdict(for: .allow)
        #expect(verdict == .allow)
    }

    @Test func packDecisionIndeterminateIsDeny() {
        let verdict = HostNativeAsk.packDoorVerdict(for: .indeterminate(.commandTooLarge))
        #expect(verdict == .deny)
    }

    @Test(arguments: HookHost.allCases)
    func hostNativeBridgeAllowOnceFollowsPauseProfile(_ host: HookHost) {
        let bridge = HostNativeApprovalBridge()
        let resolution = bridge.resolve(
            host: host,
            continuation: .hostNative,
            decision: .allowOnce
        )
        switch HostNativeAsk.profile(for: host).pause {
        case .spendFirst:
            #expect(resolution == .spendThenAllow)
        case .noPause, .leftoverAskForbidden:
            #expect(resolution == .denyOrTTY)
        }
    }

    @Test(arguments: zip(
        [HookHost.claude, .hermes, .claude, .hermes],
        [ApprovalDecision.deny, .deny, .createRule, .createRule]
    ))
    func hostNativeBridgeDenyAndCreateRuleStayDeny(_ host: HookHost, _ decision: ApprovalDecision) {
        let bridge = HostNativeApprovalBridge()
        #expect(
            bridge.resolve(host: host, continuation: .hostNative, decision: decision) == .deny
        )
    }

    @Test(arguments: HookHost.allCases)
    func unlockablePackDenyFollowsPauseProfile(_ host: HookHost) throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        let profile = HostNativeAsk.profile(for: host)
        let verdict = HostNativeAsk.hostAskVerdict(
            host: host,
            result: result,
            cwd: cwd
        )
        switch profile.pause {
        case .spendFirst:
            #expect(verdict == .ask(.hostNative))
        case .noPause, .leftoverAskForbidden:
            #expect(verdict == profile.unlockableIfNoPause.verdict)
        }
    }

    @Test func doorVerdict_missingCwdNeverAsks() {
        let result = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard")
        )
        #expect(
            HostNativeAsk.hostAskVerdict(
                host: .pi,
                result: result,
                cwd: nil
            ) == .deny
        )
        let human = EvaluationResult(
            outcome: .deny(packDeny, matched: nil),
            matchingView: MatchingView("git reset --hard"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(askDeny)
        )
        #expect(
            HostNativeAsk.hostAskVerdict(
                host: .pi,
                result: human,
                cwd: nil
            ) == .deny
        )
    }

    @Test func doorVerdict_emptyMatchingViewNeverAsks() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let packResult = EvaluationResult(outcome: .deny(packDeny, matched: nil))
        #expect(
            HostNativeAsk.hostAskVerdict(
                host: .pi,
                result: packResult,
                cwd: cwd
            ) == .deny
        )
        let humanResult = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView(""),
            analysis: .unknown,
            boundReview: .mandatoryHuman(askDeny)
        )
        #expect(
            HostNativeAsk.hostAskVerdict(
                host: .pi,
                result: humanResult,
                cwd: cwd
            ) == .deny
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
            HostNativeAsk.hostAskVerdict(
                host: .pi,
                result: result,
                cwd: cwd
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
            HostNativeAsk.hostAskVerdict(
                host: .pi,
                result: result,
                cwd: cwd
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
            HostNativeAsk.hostAskVerdict(
                host: .pi,
                result: result,
                cwd: cwd
            ) == .deny
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
            HostNativeAsk.hostAskVerdict(
                host: .pi,
                result: result,
                cwd: cwd
            ) == .deny
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
