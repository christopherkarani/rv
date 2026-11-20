import Foundation
import RVDomain

/// The stable, enumerated reason a denial happened, for SIEM rules to key
/// on. The OCSF export carries it as `status_code` on every `denied` event
/// and on every observe- or audit-mode would-be denial; other events carry
/// none.
///
/// The raw values are a published contract: never rename one. A new reason
/// is a new case. `AuditReasonCodeTests` pins every spelling, and the
/// `*-other` fallbacks keep a denial whose recorded reason rv does not know
/// (an older or newer writer) coded rather than silent.
///
/// Derived on export from what the event already records (`kind`,
/// `decision`, `reason`, `detail`, `source`); `audit.jsonl` is unchanged.
public enum AuditReasonCode: String, Sendable, CaseIterable {
    // MARK: Hook gate (`command.denied`, `command.observed`)

    /// A pack or built-in rule denied the command; `subject` names the rule.
    case commandDeniedRule = "rv.command.denied-rule"
    /// The command touched a secret path (`detail.category`).
    case commandDeniedSecretPath = "rv.command.denied-secret-path"
    /// The Laya judge blocked or held the command.
    case commandDeniedJudge = "rv.command.denied-judge"
    /// Observe mode let a command run that enforcement would have denied.
    case commandObservedDeny = "rv.command.observed-deny"
    /// Observe mode let a command run that enforcement would have asked about.
    case commandObservedAsk = "rv.command.observed-ask"
    /// An observed row with no recorded `would_be` (written before rv kept it).
    case commandObservedOther = "rv.command.observed-other"

    // MARK: Egress proxy (`egress.denied`, `egress.observed`)

    /// Not on the runtime's egress allowlist.
    case egressDeniedPolicy = "rv.egress.denied-policy"
    /// Missing, malformed or unknown proxy credential.
    case egressDeniedCredential = "rv.egress.denied-credential"
    case egressHeaderTooLarge = "rv.egress.header-too-large"
    case egressMalformed = "rv.egress.malformed"
    case egressDNSFailed = "rv.egress.dns-failed"
    /// Resolved only to addresses the dial filter refuses (private, loopback).
    case egressAddressFiltered = "rv.egress.address-filtered"
    case egressDialFailed = "rv.egress.dial-failed"
    /// The runtime binary is not admitted, or its pin no longer matches.
    case egressBinaryMismatch = "rv.egress.binary-mismatch"
    /// Binary-scoped policy on a proxy with no runtime to attribute the peer to.
    case egressUnattributedPeer = "rv.egress.unattributed-peer"
    /// The TLS ClientHello named a different server than the CONNECT target.
    case egressSNIMismatch = "rv.egress.sni-mismatch"
    case egressDeniedOther = "rv.egress.denied-other"
    /// Audit mode let a request past the allowlist that enforcement would have refused.
    case egressObservedDeniedPolicy = "rv.egress.observed-denied-policy"
    case egressObservedOther = "rv.egress.observed-other"

    // MARK: MCP gateway (`mcp.call`, `mcp.approval`)

    /// The tool's policy is `deny`.
    case mcpDeniedPolicy = "rv.mcp.denied-policy"
    /// An argument rule reads a number rv could not parse exactly.
    case mcpInexactNumber = "rv.mcp.inexact-number"
    /// A tool name rv never lists, so never serves.
    case mcpUnservedToolName = "rv.mcp.unserved-tool-name"
    /// The tool's schema property names hide text from a client.
    case mcpHidingSchema = "rv.mcp.hiding-schema"
    /// An untracked tool of a server that listed one with a hiding schema.
    case mcpHidingUntracked = "rv.mcp.hiding-untracked"
    /// The server has not listed the tool since rv restarted it.
    case mcpNotListedSinceRestart = "rv.mcp.not-listed-since-restart"
    /// An `ask` call the user declined, or that rv did not run after asking.
    case mcpNotApproved = "rv.mcp.not-approved"
    case mcpCallDeniedOther = "rv.mcp.call-denied-other"
    /// An approval grant not signed by rv.
    case mcpApprovalForged = "rv.mcp.approval-forged"
    /// `rv mcp approve` refused: presence not confirmed, code not checked,
    /// or the approval changed before it was signed.
    case mcpApprovalRefused = "rv.mcp.approval-refused"
    /// A server's secret was refused at launch or relaunch.
    case mcpSecretRefused = "rv.mcp.secret-refused"
    case mcpApprovalDeniedOther = "rv.mcp.approval-denied-other"

    // MARK: Secret gateway (`secret.use`, `secret.misuse`): one per refusal

    case secretMalformed = "rv.secret.malformed"
    case secretUnknownRoute = "rv.secret.unknown-route"
    case secretNoPlaceholder = "rv.secret.no-placeholder"
    case secretUnknownPlaceholder = "rv.secret.unknown-placeholder"
    case secretForeignPlaceholder = "rv.secret.foreign-placeholder"
    case secretTooLarge = "rv.secret.too-large"
    case secretUnsafeValue = "rv.secret.unsafe-value"
    case secretEchoMethod = "rv.secret.echo-method"
    case secretEncodedPlaceholder = "rv.secret.encoded-placeholder"
    case secretSurfaceNotAllowed = "rv.secret.surface-not-allowed"
    case secretRepeatedPlaceholder = "rv.secret.repeated-placeholder"
    case secretOutsideAllowRules = "rv.secret.outside-allow-rules"
    case secretAmbiguousPath = "rv.secret.ambiguous-path"
    case secretAuditUnavailable = "rv.secret.audit-unavailable"
    case secretRuntimeMismatch = "rv.secret.runtime-mismatch"
    case secretRuntimeUnverified = "rv.secret.runtime-unverified"
    case secretExpired = "rv.secret.expired"
    case secretRefreshFailed = "rv.secret.refresh-failed"
    case secretAWSKeyMismatch = "rv.secret.aws-key-mismatch"
    case secretAWSSignedStreaming = "rv.secret.aws-signed-streaming"
    case secretApprovalPending = "rv.secret.approval-pending"
    case secretApprovalDenied = "rv.secret.approval-denied"
    case secretApprovalUnavailable = "rv.secret.approval-unavailable"
    case secretBinaryMismatch = "rv.secret.binary-mismatch"
    case secretAWSUnsignedPayload = "rv.secret.aws-unsigned-payload"
    case secretAWSCredentialsInResponse = "rv.secret.aws-credentials-in-response"
    case secretRequestTimeout = "rv.secret.request-timeout"
    /// Refused with no recorded refusal, or one rv does not know.
    case secretRefusedOther = "rv.secret.refused-other"

    // MARK: Runtimes, agents, owner

    /// A runtime action the admission service denied.
    case admissionDenied = "rv.admission.denied"
    /// A runtime action rejected before review (malformed or unverifiable).
    case admissionRejected = "rv.admission.rejected"
    /// An agent instance refused (`agent.*`).
    case agentRefused = "rv.agent.refused"
    /// Owner authentication did not pass (`owner.action`).
    case ownerRefused = "rv.owner.refused"
    /// A denial of a kind with no reason codes of its own.
    case deniedOther = "rv.denied-other"

    /// The code for `event`, or nil when it is neither a denial nor a
    /// would-be denial.
    public init?(_ event: AuditEvent) {
        if event.kind == .commandObserved {
            self = Self.observedCommand(event.detail["would_be"])
            return
        }
        if event.kind == .egressObserved {
            self = event.reason == Self.egressDeniedPolicy.egressReason ? .egressObservedDeniedPolicy : .egressObservedOther
            return
        }
        guard event.decision == .denied else { return nil }
        self = Self.denial(event)
    }

    private static func denial(_ event: AuditEvent) -> AuditReasonCode {
        switch event.kind {
        case .commandDenied: return command(event)
        case .egressDenied: return event.reason.flatMap(egress(reason:)) ?? .egressDeniedOther
        case .mcpCall: return mcpCall(policy: event.detail["policy"], reason: event.reason)
        case .mcpApproval: return mcpApproval(event)
        case .secretUse, .secretMisuse: return event.detail["refusal"].flatMap(secret(refusal:)) ?? .secretRefusedOther
        case .admission: return event.detail["authorization"] == "rejected" ? .admissionRejected : .admissionDenied
        case .ownerAction: return .ownerRefused
        default: return event.kind.matches("agent") ? .agentRefused : .deniedOther
        }
    }

    private static func command(_ event: AuditEvent) -> AuditReasonCode {
        if let category = event.detail["category"], SecretPathCategory(rawValue: category) != nil {
            return .commandDeniedSecretPath
        }
        if JudgeRule.allCases.contains(where: { $0.ruleID.rawValue == event.subject }) {
            return .commandDeniedJudge
        }
        return .commandDeniedRule
    }

    private static func observedCommand(_ wouldBe: String?) -> AuditReasonCode {
        switch wouldBe {
        case "deny": .commandObservedDeny
        case "ask": .commandObservedAsk
        default: .commandObservedOther
        }
    }

    /// The gateway records its own refusals under policy `deny` whatever
    /// the tool's policy is, so the reason, not the policy, says which.
    private static func mcpCall(policy: String?, reason: String?) -> AuditReasonCode {
        if let denial = reason.flatMap(MCPGatewayDenial.init(recorded:)), denial != .policy || policy == "deny" {
            return denial.code
        }
        return policy == "ask" ? .mcpNotApproved : .mcpCallDeniedOther
    }

    private static func mcpApproval(_ event: AuditEvent) -> AuditReasonCode {
        if event.source == MCPAuditVocabulary.approveSource { return .mcpApprovalRefused }
        switch event.reason {
        case MCPAuditVocabulary.forgedGrant: return .mcpApprovalForged
        case MCPAuditVocabulary.secretRefusedAtLaunch, MCPAuditVocabulary.secretRefusedAtRelaunch:
            return .mcpSecretRefused
        default: return .mcpApprovalDeniedOther
        }
    }

    /// The egress proxy's recorded reason (`EgressDenialReason` raw value)
    /// this code stands for; nil for codes that are not egress denials.
    public var egressReason: String? {
        let prefix = "rv.egress."
        guard rawValue.hasPrefix(prefix), self != .egressDeniedOther,
            self != .egressObservedDeniedPolicy, self != .egressObservedOther
        else { return nil }
        return String(rawValue.dropFirst(prefix.count))
    }

    /// The code for an egress proxy reason (`EgressDenialReason` raw
    /// value), or nil when rv does not know it.
    public static func egress(reason: String) -> AuditReasonCode? {
        allCases.first { $0.egressReason == reason }
    }

    /// The code for a secret gateway refusal (`GatewayRefusal.code`), or
    /// nil when rv does not know it.
    public static func secret(refusal: String) -> AuditReasonCode? {
        secretRefusals[refusal]
    }

    private static let secretRefusals: [String: AuditReasonCode] = [
        "malformed": .secretMalformed,
        "unknownRoute": .secretUnknownRoute,
        "noPlaceholder": .secretNoPlaceholder,
        "unknownPlaceholder": .secretUnknownPlaceholder,
        "foreignPlaceholder": .secretForeignPlaceholder,
        "tooLarge": .secretTooLarge,
        "unsafeValue": .secretUnsafeValue,
        "echoMethod": .secretEchoMethod,
        "encodedPlaceholder": .secretEncodedPlaceholder,
        "surfaceNotAllowed": .secretSurfaceNotAllowed,
        "repeatedPlaceholder": .secretRepeatedPlaceholder,
        "outsideAllowRules": .secretOutsideAllowRules,
        "ambiguousPath": .secretAmbiguousPath,
        "auditUnavailable": .secretAuditUnavailable,
        "runtimeMismatch": .secretRuntimeMismatch,
        "runtimeUnverified": .secretRuntimeUnverified,
        "expired": .secretExpired,
        "refreshFailed": .secretRefreshFailed,
        "awsKeyMismatch": .secretAWSKeyMismatch,
        "awsSignedStreaming": .secretAWSSignedStreaming,
        "approvalPending": .secretApprovalPending,
        "approvalDenied": .secretApprovalDenied,
        "approvalUnavailable": .secretApprovalUnavailable,
        "binaryMismatch": .secretBinaryMismatch,
        "awsUnsignedPayload": .secretAWSUnsignedPayload,
        "awsCredentialsInResponse": .secretAWSCredentialsInResponse,
        "requestTimeout": .secretRequestTimeout,
    ]
}

/// The MCP reasons and source `AuditReasonCode` tells apart. Writers use
/// these constants, so a reworded reason cannot silently move its events
/// to an `*-other` code.
public enum MCPAuditVocabulary {
    public static let approveSource = "rv mcp approve"
    public static let forgedGrant = "forged grant rejected"
    public static let secretRefusedAtLaunch = "secret refused at launch"
    public static let secretRefusedAtRelaunch = "secret refused at relaunch"

    /// `mcp.call` refusals by the gateway itself (`MCPGatewayDenial`).
    /// A policy denial's reason is this prefix, the server, " tool ", the tool.
    public static let policyDeniedPrefix = "rv policy denies "
    public static let inexactNumber = "rv will not forward a number it cannot read exactly"
    public static let unservedToolName = "rv does not serve tools with this name"
    public static let hidingSchema = "rv does not serve tools whose schema property names hide text"
    public static let hidingUntracked = "the server listed more tools than rv tracks, one of them with schema property "
        + "names that hide text, so rv does not serve its tools it does not track"
    public static let notListedSinceRestart = "the server has not listed this tool since rv restarted it"
}

/// Why the MCP gateway refused a call on its own. The record says policy
/// `deny` whatever the tool's policy is. The gateway records its own
/// refusals only through this type, so each has a reason code: a new case
/// does not compile until `code` names one.
public enum MCPGatewayDenial: CaseIterable, Sendable {
    case policy, inexactNumber, unservedToolName, hidingSchema, hidingUntracked, notListedSinceRestart

    /// The recorded reason. Only `policy` names the server and the tool.
    public func reason(server: String, tool: String) -> String {
        switch self {
        case .policy: MCPAuditVocabulary.policyDeniedPrefix + "\(server) tool \(tool)"
        case .inexactNumber: MCPAuditVocabulary.inexactNumber
        case .unservedToolName: MCPAuditVocabulary.unservedToolName
        case .hidingSchema: MCPAuditVocabulary.hidingSchema
        case .hidingUntracked: MCPAuditVocabulary.hidingUntracked
        case .notListedSinceRestart: MCPAuditVocabulary.notListedSinceRestart
        }
    }

    public var code: AuditReasonCode {
        switch self {
        case .policy: .mcpDeniedPolicy
        case .inexactNumber: .mcpInexactNumber
        case .unservedToolName: .mcpUnservedToolName
        case .hidingSchema: .mcpHidingSchema
        case .hidingUntracked: .mcpHidingUntracked
        case .notListedSinceRestart: .mcpNotListedSinceRestart
        }
    }

    /// The denial a recorded reason stands for, or nil when it is none of
    /// them. Fixed reasons match exactly, and none starts with the policy
    /// prefix, so a server or tool name cannot pose as one.
    public init?(recorded reason: String) {
        if reason.hasPrefix(MCPAuditVocabulary.policyDeniedPrefix) {
            self = .policy
            return
        }
        guard let match = Self.allCases.first(where: { $0 != .policy && $0.reason(server: "", tool: "") == reason })
        else { return nil }
        self = match
    }
}
