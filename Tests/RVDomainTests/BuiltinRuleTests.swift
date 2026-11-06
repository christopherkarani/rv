import Testing
@testable import RVDomain

struct BuiltinRuleTests {
    @Test(arguments: BuiltinRule.allCases)
    func ruleID_roundTripsThroughCatalog(rule: BuiltinRule) {
        #expect(rule.ruleID.pack == ActionPolicyEngine.Builtin.pack)
        #expect(rule.ruleID.pattern == rule.rawValue)
        #expect(BuiltinRule(rule.ruleID) == rule)
    }

    @Test func builtinDenies_mapToCatalogCases() {
        let denies: [Deny] = [
            ActionPolicyEngine.Builtin.workingTreeDiscard,
            ActionPolicyEngine.Builtin.remoteSharedBranch,
            ActionPolicyEngine.Builtin.remoteBranchAsk,
            ActionPolicyEngine.Builtin.protectedPath,
            ActionPolicyEngine.Builtin.outsideRepository,
            ActionPolicyEngine.Builtin.unresolvedFilesystem,
            ActionPolicyEngine.Builtin.uncovered,
            ActionPolicyEngine.Builtin.secretRequestApproval,
            ActionPolicyEngine.Builtin.packIncomplete,
            ActionPolicyEngine.Builtin.unwrapLimited,
            ActionPolicyEngine.Builtin.forbiddenHTTPDestination,
            HostNativeAsk.leftoverAskDeny,
        ]
        for deny in denies {
            #expect(BuiltinRule(deny.ruleID) != nil, "\(deny.ruleID.rawValue)")
        }
    }

    @Test func spellings_areByteIdentical() {
        let expected: [BuiltinRule: String] = [
            .workingTreeDiscard: "working-tree-discard",
            .remoteSharedBranchMutation: "remote-shared-branch-mutation",
            .remoteBranchMutation: "remote-branch-mutation",
            .localBranchCreate: "local-branch-create",
            .protectedPathMutation: "protected-path-mutation",
            .inRepoWrite: "in-repo-write",
            .outOfRepoWrite: "out-of-repo-write",
            .outOfRepoRead: "out-of-repo-read",
            .unresolvedPath: "unresolved-path",
            .uncovered: "uncovered",
            .secretRequestApproval: "secret-request-approval",
            .packIncomplete: "pack-incomplete",
            .unwrapLimited: "unwrap-limited",
            .publicHTTPSGet: "public-https-get",
            .forbiddenHTTPDestination: "forbidden-http-destination",
            .leftoverAsk: "leftover-ask",
            .typedRulesInvalid: "typed-rules-invalid",
        ]
        #expect(expected.count == BuiltinRule.allCases.count)
        for (rule, spelling) in expected { #expect(rule.rawValue == spelling) }
    }

    @Test func otherPacks_doNotParse() {
        let foreign = RuleID(pack: .coreGit, pattern: BuiltinRule.uncovered.rawValue)
        #expect(BuiltinRule(foreign) == nil)
        #expect(BuiltinRule(RuleID(pack: ActionPolicyEngine.Builtin.pack, pattern: "nope")) == nil)
    }

    @Test(arguments: JudgeRule.allCases)
    func judgeRule_roundTrips(rule: JudgeRule) {
        #expect(rule.ruleID.pack == .coreJudge)
        #expect(JudgeRule(rule.ruleID) == rule)
    }

    @Test func judgeRule_spellings() {
        #expect(JudgeRule.block.ruleID.pattern == "laya-block")
        #expect(JudgeRule.review.ruleID.pattern == "laya-review")
        #expect(JudgeRule(RuleID(pack: .coreGit, pattern: "laya-block")) == nil)
    }
}
