import Testing
import RVDomain

/// Step 8 F1: caller-selected `HookHost` is metadata/routing, never human
/// authority. A `mandatoryHuman` ASK must never become quiet ALLOW because
/// of the supplied host or pause profile.
@Suite("Step 8 F1 HookHost adversarial")
struct HookHostAdversarialTests {
    private let askDeny = Deny(
        ruleID: RuleID(pack: PackID(rawValue: "builtin.action"), pattern: "remote-branch-mutation"),
        reason: "Remote branch mutation requires a human."
    )

    private func mandatoryHumanResult() -> EvaluationResult {
        EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView("git push --force origin topic"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(askDeny)
        )
    }

    /// Step 8B: `project` takes no host at all, so caller-selected
    /// `HookHost` cannot influence the verdict by construction. ASK stays ASK.
    @Test func mandatoryHuman_asksHostFree() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let verdict = HookAuthorization.project(result: mandatoryHumanResult(), cwd: cwd).verdict
        #expect(verdict != .allow)
        #expect(verdict == .ask)
    }

    /// Capability rows are routing only: no row manufactures ALLOW, so a
    /// spoofed host selects at worst a different fail-closed route.
    @Test(arguments: HookHost.allCases)
    func capabilityClaim_neverManufacturesAllow(_ host: HookHost) {
        let capability = HostApprovalCapability.capability(for: host)
        #expect(capability.nativeAskAuthoritative == false)
        #expect(capability.canBlockForHuman == false)
        #expect(capability.route == .rvOperatorUI)
    }

    /// Incomplete evaluation with a human review attached still denies.
    @Test func mandatoryHuman_indeterminate_denies() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let incomplete = EvaluationResult(
            outcome: .indeterminate(.commandTooLarge),
            matchingView: MatchingView("git push --force origin topic"),
            analysis: .unknown,
            boundReview: .mandatoryHuman(askDeny)
        )
        let verdict = HookAuthorization.project(result: incomplete, cwd: cwd).verdict
        #expect(verdict != .allow)
        #expect(verdict == .deny)
    }

    /// Missing cwd or an empty matching view fails closed.
    @Test func mandatoryHuman_missingContext_denies() throws {
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        #expect(
            HookAuthorization.project(result: mandatoryHumanResult(), cwd: nil).verdict == .deny
        )
        let empty = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView(""),
            analysis: .unknown,
            boundReview: .mandatoryHuman(askDeny)
        )
        #expect(HookAuthorization.project(result: empty, cwd: cwd).verdict == .deny)
    }

    /// Unknown host strings never resolve to a profile: no quiet-allow alias.
    @Test(arguments: ["evil", "", "GROK", " grok", "grok ", "grok\0", "pi;rm", "claude-code"])
    func unknownHost_resolvesToNoProfile(_ raw: String) {
        #expect(HookHost(rawValue: raw) == nil)
    }

    /// The closed host family round-trips exactly; nothing else parses.
    @Test(arguments: HookHost.allCases)
    func knownHosts_roundTrip(_ host: HookHost) {
        #expect(HookHost(rawValue: host.rawValue) == host)
    }

    /// Malformed agent tags are rejected before they can select anything.
    @Test(arguments: ["", "a/b", "a b", "a;b", "a:b", String(repeating: "a", count: 33)])
    func malformedAgentTag_isRejected(_ tag: String) {
        #expect(AgentTagValidator.isValid(tag) == false)
    }

    @Test(arguments: ["agent-A", "agent-B", "opencode", "a", String(repeating: "a", count: 32)])
    func wellFormedAgentTag_isAccepted(_ tag: String) {
        #expect(AgentTagValidator.isValid(tag))
    }
}
