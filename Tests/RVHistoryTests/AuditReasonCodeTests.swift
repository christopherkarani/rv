import Foundation
import Testing
@testable import RVHistory

/// Pins the OCSF `status_code` spelling of every denial reason. SIEM rules
/// key on these strings: a rename must break this test.
@Suite("AuditReasonCode")
struct AuditReasonCodeTests {
    static let golden: [(AuditReasonCode, String)] = [
        (.commandDeniedRule, "rv.command.denied-rule"),
        (.commandDeniedSecretPath, "rv.command.denied-secret-path"),
        (.commandDeniedJudge, "rv.command.denied-judge"),
        (.commandDeniedIndeterminate, "rv.command.denied-indeterminate"),
        (.commandObservedDeny, "rv.command.observed-deny"),
        (.commandObservedAsk, "rv.command.observed-ask"),
        (.commandObservedOther, "rv.command.observed-other"),
        (.egressDeniedPolicy, "rv.egress.denied-policy"),
        (.egressDeniedCredential, "rv.egress.denied-credential"),
        (.egressHeaderTooLarge, "rv.egress.header-too-large"),
        (.egressMalformed, "rv.egress.malformed"),
        (.egressDNSFailed, "rv.egress.dns-failed"),
        (.egressAddressFiltered, "rv.egress.address-filtered"),
        (.egressDialFailed, "rv.egress.dial-failed"),
        (.egressBinaryMismatch, "rv.egress.binary-mismatch"),
        (.egressUnattributedPeer, "rv.egress.unattributed-peer"),
        (.egressSNIMismatch, "rv.egress.sni-mismatch"),
        (.egressDeniedOther, "rv.egress.denied-other"),
        (.egressObservedDeniedPolicy, "rv.egress.observed-denied-policy"),
        (.egressObservedOther, "rv.egress.observed-other"),
        (.mcpDeniedPolicy, "rv.mcp.denied-policy"),
        (.mcpInexactNumber, "rv.mcp.inexact-number"),
        (.mcpUnservedToolName, "rv.mcp.unserved-tool-name"),
        (.mcpHidingSchema, "rv.mcp.hiding-schema"),
        (.mcpHidingUntracked, "rv.mcp.hiding-untracked"),
        (.mcpNotListedSinceRestart, "rv.mcp.not-listed-since-restart"),
        (.mcpNotApproved, "rv.mcp.not-approved"),
        (.mcpCallDeniedOther, "rv.mcp.call-denied-other"),
        (.mcpApprovalForged, "rv.mcp.approval-forged"),
        (.mcpApprovalRefused, "rv.mcp.approval-refused"),
        (.mcpSecretRefused, "rv.mcp.secret-refused"),
        (.mcpApprovalDeniedOther, "rv.mcp.approval-denied-other"),
        (.secretMalformed, "rv.secret.malformed"),
        (.secretUnknownRoute, "rv.secret.unknown-route"),
        (.secretNoPlaceholder, "rv.secret.no-placeholder"),
        (.secretUnknownPlaceholder, "rv.secret.unknown-placeholder"),
        (.secretForeignPlaceholder, "rv.secret.foreign-placeholder"),
        (.secretTooLarge, "rv.secret.too-large"),
        (.secretUnsafeValue, "rv.secret.unsafe-value"),
        (.secretEchoMethod, "rv.secret.echo-method"),
        (.secretEncodedPlaceholder, "rv.secret.encoded-placeholder"),
        (.secretSurfaceNotAllowed, "rv.secret.surface-not-allowed"),
        (.secretRepeatedPlaceholder, "rv.secret.repeated-placeholder"),
        (.secretOutsideAllowRules, "rv.secret.outside-allow-rules"),
        (.secretAmbiguousPath, "rv.secret.ambiguous-path"),
        (.secretAuditUnavailable, "rv.secret.audit-unavailable"),
        (.secretRuntimeMismatch, "rv.secret.runtime-mismatch"),
        (.secretRuntimeUnverified, "rv.secret.runtime-unverified"),
        (.secretExpired, "rv.secret.expired"),
        (.secretRefreshFailed, "rv.secret.refresh-failed"),
        (.secretAWSKeyMismatch, "rv.secret.aws-key-mismatch"),
        (.secretAWSSignedStreaming, "rv.secret.aws-signed-streaming"),
        (.secretApprovalPending, "rv.secret.approval-pending"),
        (.secretApprovalDenied, "rv.secret.approval-denied"),
        (.secretApprovalUnavailable, "rv.secret.approval-unavailable"),
        (.secretBinaryMismatch, "rv.secret.binary-mismatch"),
        (.secretAWSUnsignedPayload, "rv.secret.aws-unsigned-payload"),
        (.secretAWSCredentialsInResponse, "rv.secret.aws-credentials-in-response"),
        (.secretRequestTimeout, "rv.secret.request-timeout"),
        (.secretRefusedOther, "rv.secret.refused-other"),
        (.admissionDenied, "rv.admission.denied"),
        (.admissionRejected, "rv.admission.rejected"),
        (.agentRefused, "rv.agent.refused"),
        (.ownerRefused, "rv.owner.refused"),
        (.deniedOther, "rv.denied-other"),
    ]

    @Test func everySpellingIsPinned() {
        for (code, spelling) in Self.golden {
            #expect(code.rawValue == spelling)
        }
    }

    @Test func goldenCoversEveryCase() {
        #expect(Set(Self.golden.map(\.0)) == Set(AuditReasonCode.allCases))
        #expect(Self.golden.count == AuditReasonCode.allCases.count)
    }

    /// The documented table is the contract SIEM authors read.
    @Test func docsListEveryCode() throws {
        let docs = try String(
            contentsOf: AuditOCSFSchemaTests.repository.appendingPathComponent("docs/guides/audit-log.md"),
            encoding: .utf8)
        for code in AuditReasonCode.allCases {
            #expect(docs.contains("`\(code.rawValue)`"), "docs/guides/audit-log.md does not list \(code.rawValue)")
        }
    }

    func statusCode(_ event: AuditEvent) -> String? {
        AuditOCSF.object(event, hostName: "h")["status_code"] as? String
    }

    @Test func everyDenialInTheSamplesCarriesACode() {
        for event in AuditOCSFSamples.all where event.decision == .denied {
            #expect(statusCode(event) != nil, "\(event.kind.rawValue) denial has no status_code")
        }
    }

    @Test func nonDenialsCarryNoCode() {
        let quiet = AuditOCSFSamples.all.filter {
            $0.decision != .denied && $0.kind != .commandObserved && $0.kind != .egressObserved
        }
        #expect(quiet.isEmpty == false)
        for event in quiet {
            #expect(statusCode(event) == nil, "\(event.kind.rawValue) \(event.decision.rawValue) has a status_code")
        }
    }

    typealias E = AuditOCSFSamples

    static func mcpDeny(_ reason: String) -> AuditEvent {
        E.event(.mcpCall, .denied, "fs/write", reason: reason, source: "mcp-gateway", detail: ["policy": "deny"])
    }

    /// The gateway's own refusal reasons, in `MCPGatewayDenial.allCases`
    /// order, spelled out: they are in the hash chain, so a reworded
    /// constant must fail here.
    static let gatewayReasons: [(String, String)] = [
        ("rv policy denies fs tool write", "rv.mcp.denied-policy"),
        ("rv will not forward a number it cannot read exactly", "rv.mcp.inexact-number"),
        ("rv does not serve tools with this name", "rv.mcp.unserved-tool-name"),
        ("rv does not serve tools whose schema property names hide text", "rv.mcp.hiding-schema"),
        ("the server listed more tools than rv tracks, one of them with schema property "
            + "names that hide text, so rv does not serve its tools it does not track", "rv.mcp.hiding-untracked"),
        ("the server has not listed this tool since rv restarted it", "rv.mcp.not-listed-since-restart"),
    ]

    @Test func gatewayDenialReasonsAreUnchanged() {
        let recorded = MCPGatewayDenial.allCases.map { $0.reason(server: "fs", tool: "write") }
        #expect(recorded == Self.gatewayReasons.map(\.0))
        #expect(MCPGatewayDenial.allCases.map(\.code.rawValue) == Self.gatewayReasons.map(\.1))
    }

    @Test(arguments: Self.gatewayReasons)
    func derivesTheGatewayCode(reason: String, code: String) {
        let event = Self.mcpDeny(reason)
        #expect(AuditReasonCode(event)?.rawValue == code)
        #expect(statusCode(event) == code)
    }

    /// A server or tool name cannot make a policy denial read as another.
    @Test func policyReasonWithAFixedReasonAsToolIsStillPolicy() {
        let tool = MCPAuditVocabulary.hidingSchema
        let event = Self.mcpDeny(MCPGatewayDenial.policy.reason(server: "fs", tool: tool))
        #expect(AuditReasonCode(event) == .mcpDeniedPolicy)
    }

    static let derivations: [(AuditEvent, String)] = [
        (E.event(.commandDenied, .denied, "core.git:reset-hard", detail: ["category": "core.git"]), "rv.command.denied-rule"),
        (E.event(.commandDenied, .denied, "core.secrets:read", detail: ["category": "ssh"]), "rv.command.denied-secret-path"),
        (E.event(.commandDenied, .denied, "core.judge:laya-block", detail: ["category": "core.judge"]), "rv.command.denied-judge"),
        (E.event(.commandDenied, .denied, "core.judge:laya-review"), "rv.command.denied-judge"),
        (
            E.event(
                .commandDenied, .denied, "rv.indeterminate:selfProtection",
                detail: ["category": "rv.indeterminate", "verdict": "indeterminate"]),
            "rv.command.denied-indeterminate"
        ),
        (
            E.event(.commandObserved, .info, "rv.indeterminate:unresolvedInvocation",
                detail: ["would_be": "deny", "verdict": "indeterminate"]),
            "rv.command.observed-deny"
        ),
        (E.event(.commandObserved, .info, "core.git:reset-hard", detail: ["would_be": "deny"]), "rv.command.observed-deny"),
        (E.event(.commandObserved, .info, "core.git:reset-hard", detail: ["would_be": "ask"]), "rv.command.observed-ask"),
        (E.event(.commandObserved, .info, "core.git:reset-hard"), "rv.command.observed-other"),
        (E.event(.egressDenied, .denied, "a.example:443", reason: "denied-policy"), "rv.egress.denied-policy"),
        (E.event(.egressDenied, .denied, "a.example:443", reason: "binary-mismatch"), "rv.egress.binary-mismatch"),
        (E.event(.egressDenied, .denied, "a.example:443", reason: "dns-failed"), "rv.egress.dns-failed"),
        (E.event(.egressDenied, .denied, "a.example:443", reason: "something-new"), "rv.egress.denied-other"),
        (E.event(.egressDenied, .denied, "a.example:443"), "rv.egress.denied-other"),
        (E.event(.egressObserved, .info, "a.example:443", reason: "denied-policy"), "rv.egress.observed-denied-policy"),
        (E.event(.egressObserved, .info, "a.example:443", reason: "dial-failed"), "rv.egress.observed-other"),
        (mcpDeny("a reason rv does not know"), "rv.mcp.call-denied-other"),
        (E.event(.mcpCall, .denied, "fs/write", detail: ["policy": "deny"]), "rv.mcp.call-denied-other"),
        // A refusal recorded under `ask` (a prompt replayed after the tool
        // was hidden) keeps its own code; a declined prompt is not-approved,
        // even when its reason looks like a policy denial.
        (E.event(.mcpCall, .denied, "fs/write", reason: "rv does not serve tools whose schema property names hide text",
                 detail: ["policy": "ask"]), "rv.mcp.hiding-schema"),
        (E.event(.mcpCall, .denied, "fs/write", reason: "rv policy denies fs tool write", detail: ["policy": "ask"]),
         "rv.mcp.not-approved"),
        (E.event(.mcpCall, .denied, "fs/write", detail: ["policy": "ask"]), "rv.mcp.not-approved"),
        (E.event(.mcpCall, .denied, "fs/write"), "rv.mcp.call-denied-other"),
        (E.event(.mcpApproval, .denied, "fs/write", reason: MCPAuditVocabulary.forgedGrant), "rv.mcp.approval-forged"),
        (E.event(.mcpApproval, .denied, "fs/write", reason: "user presence not confirmed: cancelled",
                 source: MCPAuditVocabulary.approveSource), "rv.mcp.approval-refused"),
        (E.event(.mcpApproval, .denied, "fs", reason: MCPAuditVocabulary.secretRefusedAtLaunch), "rv.mcp.secret-refused"),
        (E.event(.mcpApproval, .denied, "fs", reason: MCPAuditVocabulary.secretRefusedAtRelaunch), "rv.mcp.secret-refused"),
        (E.event(.mcpApproval, .denied, "fs", reason: "new reason"), "rv.mcp.approval-denied-other"),
        (E.event(.secretMisuse, .denied, "K", detail: ["refusal": "foreignPlaceholder"]), "rv.secret.foreign-placeholder"),
        (E.event(.secretUse, .denied, "K", detail: ["refusal": "awsCredentialsInResponse"]), "rv.secret.aws-credentials-in-response"),
        (E.event(.secretMisuse, .denied, "K"), "rv.secret.refused-other"),
        (E.event(.secretUse, .denied, "K", detail: ["refusal": "notACode"]), "rv.secret.refused-other"),
        (E.event(.admission, .denied, "x", detail: ["authorization": "denied"]), "rv.admission.denied"),
        (E.event(.admission, .denied, "x", detail: ["authorization": "rejected"]), "rv.admission.rejected"),
        (E.event(.agent("finished"), .denied, "claude", reason: "refused:permit"), "rv.agent.refused"),
        (E.event(.ownerAction, .denied, "rv allow"), "rv.owner.refused"),
        (E.event(AuditEventKind(rawValue: "future.kind"), .denied, "x"), "rv.denied-other"),
    ]

    @Test(arguments: Self.derivations)
    func derivesTheCode(event: AuditEvent, code: String) {
        #expect(AuditReasonCode(event)?.rawValue == code)
        #expect(statusCode(event) == code)
    }

    /// The code is added beside what was there: `status_detail` (set for
    /// gate changes) and `unmapped.rv_reason` keep their values.
    @Test func codeIsAddedNotSubstituted() throws {
        let event = E.event(.egressDenied, .denied, "a.example:443", reason: "denied-policy")
        let object = AuditOCSF.object(event, hostName: "h")
        let unmapped = try #require(object["unmapped"] as? [String: Any])
        #expect(unmapped["rv_reason"] as? String == "denied-policy")
        #expect(object["status"] as? String == "Failure")
        #expect(object["status_id"] as? Int == 2)
    }
}
