/// The one spelling of every rule ID minted under `ActionPolicyEngine.Builtin.pack`.
/// Raw values are the persisted/wire patterns; do not change them.
public enum BuiltinRule: String, CaseIterable, Sendable {
    case workingTreeDiscard = "working-tree-discard"
    case remoteSharedBranchMutation = "remote-shared-branch-mutation"
    case remoteBranchMutation = "remote-branch-mutation"
    case localBranchCreate = "local-branch-create"
    case protectedPathMutation = "protected-path-mutation"
    case inRepoWrite = "in-repo-write"
    case outOfRepoWrite = "out-of-repo-write"
    case outOfRepoRead = "out-of-repo-read"
    case unresolvedPath = "unresolved-path"
    case uncovered = "uncovered"
    case secretRequestApproval = "secret-request-approval"
    case packIncomplete = "pack-incomplete"
    case unwrapLimited = "unwrap-limited"
    case publicHTTPSGet = "public-https-get"
    case forbiddenHTTPDestination = "forbidden-http-destination"
    case leftoverAsk = "leftover-ask"
    case typedRulesInvalid = "typed-rules-invalid"

    static let pack = PackID(rawValue: "builtin.action")

    public var ruleID: RuleID { RuleID(pack: Self.pack, pattern: rawValue) }

    /// Nil for rule IDs of other packs or unknown patterns.
    public init?(_ id: RuleID) {
        guard id.pack == Self.pack else { return nil }
        self.init(rawValue: id.pattern)
    }
}

/// The one spelling of the Laya judge's rule IDs (`PackID.coreJudge`).
public enum JudgeRule: String, CaseIterable, Sendable {
    case block = "laya-block"
    case review = "laya-review"

    public var ruleID: RuleID { RuleID(pack: .coreJudge, pattern: rawValue) }

    public init?(_ id: RuleID) {
        guard id.pack == .coreJudge else { return nil }
        self.init(rawValue: id.pattern)
    }
}
