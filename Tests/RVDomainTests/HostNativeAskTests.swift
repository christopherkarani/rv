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

    @Test(arguments: [HookHost.pi, .opencode])
    func spendFirstHostsPauseOnMandatoryHuman(_ host: HookHost) {
        let verdict = HostNativeAsk.verdict(
            host: host,
            bound: .mandatoryHuman(askDeny),
            continuation: .hostNative
        )
        #expect(verdict == .ask(.hostNative))
        #expect(HostNativeAsk.capability(for: host) == .spendFirst)
    }

    @Test(arguments: [HookHost.claude, .grok, .openclaw, .hermes, .codex, .cursor])
    func denyOrTTYHostsDoNotPauseOnMandatoryHuman(_ host: HookHost) {
        let verdict = HostNativeAsk.verdict(
            host: host,
            bound: .mandatoryHuman(askDeny),
            continuation: .hostNative
        )
        #expect(verdict == .deny)
        #expect(HostNativeAsk.capability(for: host) == .denyOrTTY)
    }

    @Test func capabilityTable_piAndOpenCodeStaySpendFirst_codexAndCursorAreDenyOrTTY() {
        #expect(HostNativeAsk.capability(for: .pi) == .spendFirst)
        #expect(HostNativeAsk.capability(for: .opencode) == .spendFirst)
        #expect(HostNativeAsk.capability(for: .codex) == .denyOrTTY)
        #expect(HostNativeAsk.capability(for: .cursor) == .denyOrTTY)
        #expect(HostNativeAsk.capability(for: .claude) == .denyOrTTY)
    }

    @Test func boundHardDenyNeverPauses() {
        #expect(HostNativeAsk.verdict(host: .pi, bound: .deny(packDeny)) == .deny)
        #expect(HostNativeAsk.verdict(host: .opencode, bound: .deny(packDeny)) == .deny)
    }

    @Test func packDecisionDenyStaysDeny() {
        let denied = Decision.deny(packDeny)
        #expect(HostNativeAsk.verdict(host: .pi, decision: denied) == .deny)
        #expect(HostNativeAsk.verdict(host: .opencode, decision: denied) == .deny)
        #expect(HostNativeAsk.verdict(host: .claude, decision: denied) == .deny)
        #expect(HostNativeAsk.verdict(host: .grok, decision: denied) == .deny)
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
                == .denyOrTTY
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
}
