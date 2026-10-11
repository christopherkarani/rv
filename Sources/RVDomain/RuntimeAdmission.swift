import Foundation

/// Unguessable secret for one contained runtime.
///
/// `RuntimeSessionID` names the launch. This value proves the caller received
/// the channel RV granted to that launch. A 32-byte token is not a session id
/// and is not accepted from a short or non-hex string.
///
/// Step 8 (F3): a capability proves CHANNEL authority only. It never proves
/// agent principal authority — that is `AuthenticatedAgentContext`. Sensitive
/// operations require both where applicable; a capability alone must never
/// become Secrets/MCP authority.
public struct RuntimeCapability: Hashable, Sendable, Equatable {
    public let rawValue: String

    public init() {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        rawValue = bytes.map { String(format: "%02x", $0) }.joined()
    }

    public init?(validating rawValue: String) {
        let hex = rawValue.lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        self.rawValue = hex
    }

    public func matches(_ other: RuntimeCapability) -> Bool {
        let left = Array(rawValue.utf8)
        let right = Array(other.rawValue.utf8)
        guard left.count == right.count, left.count == 64 else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

/// One admission attempt inside a runtime session.
///
/// The contained agent picks this id. RV remembers it after the request is
/// authenticated so the same bytes cannot perform the side effect twice.
public struct RuntimeActionRequestID: Hashable, Sendable, Equatable {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public init?(validating text: String) {
        guard let rawValue = UUID(uuidString: text) else { return nil }
        self.rawValue = rawValue
    }
}

/// Session id echoed by an untrusted request.
///
/// This is not `RuntimeSessionID`. Parsing one does not mint a runtime and
/// does not authenticate the caller.
package struct RuntimeSessionClaim: Hashable, Sendable, Equatable {
    package let rawValue: UUID

    package init?(validating text: String) {
        guard let rawValue = UUID(uuidString: text) else { return nil }
        self.rawValue = rawValue
    }
}

/// Whether RV still accepts actions for a channel it created.
public enum RuntimeAdmissionPhase: Sendable, Equatable {
    case active
    case finished
}

/// RV-held binding between one launch and the secret granted on its channel.
///
/// Workspace, host, and backend come from the session RV recorded. They are
/// not fields the agent may supply.
public struct RuntimeChannelBinding: Sendable, Equatable {
    public var session: RuntimeSession
    public let capability: RuntimeCapability
    public var phase: RuntimeAdmissionPhase
    package var consumedRequestIDs: Set<RuntimeActionRequestID>
    public var consumedFingerprints: Set<ActionFingerprint>
    /// Agent Instance this channel is bound to, set once at establishment.
    /// Nil is a pre-establishment or legacy channel: capability, session, and
    /// replay checks still apply, and no principal check runs. A set binding
    /// requires the caller to present the matching live trusted context.
    public var agentInstanceID: AgentInstanceID?

    public init(
        session: RuntimeSession,
        capability: RuntimeCapability,
        phase: RuntimeAdmissionPhase = .active,
        consumedRequestIDs: Set<RuntimeActionRequestID> = [],
        consumedFingerprints: Set<ActionFingerprint> = [],
        agentInstanceID: AgentInstanceID? = nil
    ) {
        self.session = session
        self.capability = capability
        self.phase = phase
        self.consumedRequestIDs = consumedRequestIDs
        self.consumedFingerprints = consumedFingerprints
        self.agentInstanceID = agentInstanceID
    }

    public func finished() -> RuntimeChannelBinding {
        var copy = self
        copy.phase = .finished
        return copy
    }
}

/// Facts RV uses to normalize an admitted command.
///
/// `policyWorkspace` is the launch plan's workspace. A request payload cannot
/// replace it.
public struct RuntimeAdmissionSubject: Sendable, Equatable {
    public var session: RuntimeSession
    public var policyWorkspace: WorkingDirectory
    /// Trusted principal context resolved by RV from live registry state.
    /// Request payloads carry no principal fields, so nothing the agent sends
    /// can replace this. Nil on pre-establishment and legacy channels.
    public var agent: AuthenticatedAgentContext?

    public init(
        session: RuntimeSession,
        policyWorkspace: WorkingDirectory,
        agent: AuthenticatedAgentContext? = nil
    ) {
        self.session = session
        self.policyWorkspace = policyWorkspace
        self.agent = agent
    }
}

/// Polled by name lookup while `getaddrinfo` runs on another thread.
///
/// The session loop sets this around normalize. A stuck resolver then cannot
/// keep the contained process group alive after the leader exits.
public enum RuntimeAdmissionStop {
    @TaskLocal public static var shouldStop: @Sendable () -> Bool = { false }
}

/// What the agent asked for. This is not a canonical HTTP action and not a permit.
///
/// MCP dispatch never normalizes to a `ProposedAction`: the dispatch layer
/// routes `.mcp` to `ScopedInvoker` after `submitMCP` admits it. Any
/// `ProposedAction`-shaped normalize that receives `.mcp` fails closed.
public enum RuntimeRequestedAction: Sendable, Equatable {
    case shell(ShellCommand)
    case http(method: String, url: String)
    case mcp(dispatch: MCPDispatchAction)
}

/// Untrusted action after a successful decode. Holding one is not authority.
public struct RuntimeActionFrame: Sendable, Equatable {
    public var version: Int
    public var requestID: RuntimeActionRequestID
    public var capability: RuntimeCapability
    package var claimedSession: RuntimeSessionClaim
    public var action: RuntimeRequestedAction

    package init(
        version: Int,
        requestID: RuntimeActionRequestID,
        capability: RuntimeCapability,
        claimedSession: RuntimeSessionClaim,
        action: RuntimeRequestedAction
    ) {
        self.version = version
        self.requestID = requestID
        self.capability = capability
        self.claimedSession = claimedSession
        self.action = action
    }
}

public enum RuntimeAdmissionDecodeError: Error, Sendable, Equatable {
    case malformed
    case oversized
}

public enum RuntimeAdmissionRejection: String, Sendable, Equatable, Codable {
    case unknownSession
    case inactiveSession
    case invalidCapability
    case impersonation
    case malformed
    case replay
    case channelClosed
    /// Step 8 (F3): an identity-required operation arrived without a live
    /// authenticated principal — the binding names no instance, or no
    /// trusted context was presented. Never downgrades to capability-only.
    case principalRequired
}

public enum RuntimeAdmissionEvaluationError: Error, Sendable, Equatable {
    case failed
}

public enum RuntimeAdmissionExecutorError: String, Error, Sendable, Equatable {
    case unavailable
    case compileFailed
    case spawnFailed
    case notEstablished
    case cancelled
}

/// Wire outcome. Policy denial, ask, evaluation failure, and executor failure
/// are different cases. None of the failure cases is an executed action.
public enum RuntimeAdmissionResponse: Sendable, Equatable {
    case executed(exitStatus: Int32)
    case denied(Deny)
    case pending(ApprovalReason)
    case rejected(RuntimeAdmissionRejection)
    case evaluationFailed
    case approvalUnavailable
    case executorFailed(RuntimeAdmissionExecutorError)
    case http(HTTPExecutionReceipt)
    case httpFailed(HTTPOpenFailure)
    case mcp(MCPExecutionReceipt)
    case mcpFailed(MCPDispatchFailure)
}

/// One executed MCP tool call. Mirrors `HTTPExecutionReceipt`: the attempted
/// address plus the bounded tool-result bytes.
public struct MCPExecutionReceipt: Sendable, Equatable {
    /// Attempted tool address literal. Labels only; parsing may have failed.
    public var address: String
    /// Tool result bytes. Bounded by the response cap; oversized bodies
    /// fail as `.responseTooLarge` instead of truncating.
    public var body: Data

    public init(address: String, body: Data) {
        self.address = address
        self.body = body
    }
}

/// Closed MCP dispatch failure vocabulary. Mirrors `HTTPOpenFailure`:
/// labels only, never envelopes, values, or causes. Transport and auth
/// failures collapse to `.internalError`, whose correlation id is the only
/// caller-visible linkage to the server-side cause and audit row.
public enum MCPDispatchFailure: Sendable, Equatable {
    case unknownTool
    case crossResource
    case invalidArguments
    case elicitationTimeout
    case elicitationUnavailable
    case elicitationDeclined
    case credentialFailed
    case auditFailed
    /// Defensive only: admission short-circuits `block` verdicts, so an
    /// admitted call reaches this only if the verdict moved mid-flight.
    case policyDenied
    case internalError(correlationID: String)
    case responseTooLarge
    case cancelled

    /// Wire reason label. The correlation id rides its own key, never here.
    public var reasonLabel: String {
        switch self {
        case .unknownTool:
            return "unknownTool"
        case .crossResource:
            return "crossResource"
        case .invalidArguments:
            return "invalidArguments"
        case .elicitationTimeout:
            return "elicitationTimeout"
        case .elicitationUnavailable:
            return "elicitationUnavailable"
        case .elicitationDeclined:
            return "elicitationDeclined"
        case .credentialFailed:
            return "credentialFailed"
        case .auditFailed:
            return "auditFailed"
        case .policyDenied:
            return "policyDenied"
        case .internalError:
            return "internalError"
        case .responseTooLarge:
            return "responseTooLarge"
        case .cancelled:
            return "cancelled"
        }
    }
}

public enum RuntimeAdmissionAuthorization: String, Sendable, Equatable, Codable {
    case allowed
    case pending
    case denied
    case rejected
    case evaluationFailed
    case approvalUnavailable
    case executorFailed
}

/// Structured evidence for one admission attempt. Not the denial ledger.
public struct RuntimeAdmissionEvent: Sendable, Equatable, Codable {
    public var session: String?
    public var requestID: String?
    public var fingerprint: String?
    public var authorization: RuntimeAdmissionAuthorization
    public var executionAttempted: Bool
    public var result: String
    /// Present for an HTTP attempt. The query string is not stored.
    public var httpMethod: String?
    public var httpDestination: String?
    public var httpAddress: String?
    public var httpQueryPresent: Bool?
    public var httpStatus: Int?
    /// Parent workspace RV recorded for this runtime. The agent does not supply it.
    public var workspace: String?
    /// Agent Instance this attempt was attributed to: the trusted context's
    /// instance when one was presented, else the RV-held channel binding.
    /// Descriptive only; possessing it grants nothing.
    public var agentInstance: String?
    /// Agent Definition of the presented trusted context, when any.
    public var agentDefinition: String?
    /// Present for an MCP attempt. The attempted tool address literal:
    /// labels only, never arguments or values. Set even when the literal
    /// failed parsing, mirroring `httpDestination`.
    public var mcpAddress: String?
    /// Present for an MCP attempt whose address parsed: the connection
    /// segment, mirroring `httpAddress`. Nil for unparseable literals.
    public var mcpConnection: String?

    public init(
        session: String?,
        requestID: String?,
        fingerprint: String?,
        authorization: RuntimeAdmissionAuthorization,
        executionAttempted: Bool,
        result: String,
        httpMethod: String? = nil,
        httpDestination: String? = nil,
        httpAddress: String? = nil,
        httpQueryPresent: Bool? = nil,
        httpStatus: Int? = nil,
        workspace: String? = nil,
        agentInstance: String? = nil,
        agentDefinition: String? = nil,
        mcpAddress: String? = nil,
        mcpConnection: String? = nil
    ) {
        self.session = session
        self.requestID = requestID
        self.fingerprint = fingerprint
        self.authorization = authorization
        self.executionAttempted = executionAttempted
        self.result = result
        self.httpMethod = httpMethod
        self.httpDestination = httpDestination
        self.httpAddress = httpAddress
        self.httpQueryPresent = httpQueryPresent
        self.httpStatus = httpStatus
        self.workspace = workspace
        self.agentInstance = agentInstance
        self.agentDefinition = agentDefinition
        self.mcpAddress = mcpAddress
        self.mcpConnection = mcpConnection
    }
}

public struct RuntimeAdmissionDecision: Sendable, Equatable {
    public var binding: RuntimeChannelBinding?
    public var response: RuntimeAdmissionResponse
    public var event: RuntimeAdmissionEvent
    /// Set only when the shell must perform the side effect.
    public var execute: AllowedAction?
    /// The host parked this ASK for a human decision: the answer arrives
    /// later, asynchronously. Callers must NOT write `response` now — it is
    /// the pre-park pending projection, already superseded. Set only by the
    /// host session layer, never by the gate.
    public var responseDeferred: Bool

    public init(
        binding: RuntimeChannelBinding?,
        response: RuntimeAdmissionResponse,
        event: RuntimeAdmissionEvent,
        execute: AllowedAction? = nil,
        responseDeferred: Bool = false
    ) {
        self.binding = binding
        self.response = response
        self.event = event
        self.execute = execute
        self.responseDeferred = responseDeferred
    }
}

/// MCP admission decision. Mirrors `RuntimeAdmissionDecision`, but the
/// invoke payload is the admitted dispatch action: MCP never becomes a
/// `ProposedAction`, so there is no `AllowedAction` to execute.
public struct RuntimeMCPAdmissionDecision: Sendable, Equatable {
    public var binding: RuntimeChannelBinding?
    public var response: RuntimeAdmissionResponse
    public var event: RuntimeAdmissionEvent
    /// Set only when the dispatch layer must invoke the tool.
    public var invoke: MCPDispatchAction?

    public init(
        binding: RuntimeChannelBinding?,
        response: RuntimeAdmissionResponse,
        event: RuntimeAdmissionEvent,
        invoke: MCPDispatchAction? = nil
    ) {
        self.binding = binding
        self.response = response
        self.event = event
        self.invoke = invoke
    }
}

enum RuntimeAdmissionAuthentication: Sendable, Equatable {
    case reject(RuntimeAdmissionDecision)
    case accept(RuntimeActionFrame)
}

/// Fail-closed admission gate.
///
/// Calls `AgentAuthorization.decide` and `AgentAuthorization.step`. It does
/// not call `HookAuthorization` or `PolicyGate`, and it does not treat a
/// session id as a credential.
///
/// Step 8 (F3): `submitLegacy` is the LEGACY capability-only door. A binding
/// with `agentInstanceID == nil` authenticates on channel facts alone and
/// must never mediate sensitive operations — future Secrets/MCP layers
/// must call `submitIdentityRequired`, which refuses principal-less
/// channels instead of silently downgrading to capability-only.
public enum RuntimeAdmissionGate {
    /// Identity-required privileged admission (Step 8 F3).
    ///
    /// Sensitive mediated operations enter here, never via `submitLegacy`. The
    /// channel must name an instance (`binding.agentInstanceID != nil`)
    /// and the caller must present the freshly resolved trusted context
    /// for it; otherwise the request is rejected with `.principalRequired`
    /// before any proposal, policy evaluation, or action execution. No
    /// downgrade to capability-only ever happens.
    ///
    /// Liveness, binding match (exact instance, runtime/session, workspace),
    /// capability match, and replay protection are enforced by the shared
    /// authentication below, fed by the existing Step 7 principal
    /// resolution (`AgentInstanceRegistry.context(forBinding:)`). Nothing
    /// here performs its own principal lookup.
    public static func submitIdentityRequired(
        binding: inout RuntimeChannelBinding?,
        frame: Result<RuntimeActionFrame, RuntimeAdmissionDecodeError>,
        policy: EffectiveActionPolicy = .empty,
        approvalFor: (RuntimeActionRequestID, PendingAuthorization) -> Result<
            ApprovalDecision, AgentApprovalError
        >? = { _, _ in
            nil
        },
        agentContext: AuthenticatedAgentContext? = nil,
        propose: (RuntimeActionFrame) -> Result<ProposedAction, RuntimeAdmissionEvaluationError>
    ) -> RuntimeAdmissionDecision {
        // No channel at all keeps the existing unknown-session rejection.
        // A channel that names no principal — or a named principal with
        // no presented context — is the principal-less case: reject here,
        // before any proposal or policy work, never downgrading.
        // Liveness/validity of a PRESENTED context is enforced downstream
        // by the shared authentication (inactive → .inactiveSession),
        // keeping the precise rejection reason; the pre-guard only needs
        // presence because absence is the downgrade case.
        guard binding != nil else {
            return submitLegacy(
                binding: &binding,
                frame: frame,
                policy: policy,
                approvalFor: approvalFor,
                agentContext: agentContext,
                propose: propose
            )
        }
        if binding?.agentInstanceID == nil || agentContext == nil {
            let requestID = frame.successValue?.requestID.rawValue.uuidString
            // Step 8 (F3 re-review): attribute to the channel/binding only.
            // A presented context the binding does not name is smuggled, not
            // trusted — stamping it into audit fields would misattribute the
            // rejection to a principal that never authenticated.
            return stamp(
                reject(
                    binding: binding,
                    requestID: requestID,
                    reason: .principalRequired,
                    authorization: .rejected
                ),
                agentContext: nil
            )
        }
        return submitLegacy(
            binding: &binding,
            frame: frame,
            policy: policy,
            approvalFor: approvalFor,
            agentContext: agentContext,
            propose: propose
        )
    }

    // MARK: - Broker mediation (T5)

    /// Broker entries admitted for one identity-required mediation.
    ///
    /// Pure selection shared by the preparation path (which refs to
    /// resolve through `SecretBroker`) and staging (which resolved
    /// values to inject). An entry whose agent filter is non-empty and
    /// does not contain `agent` is skipped — filtered entries never
    /// resolve on a tag mismatch, mirroring credential and keychain
    /// selection — and an entry whose ref fails validation fails closed
    /// (skipped here; staging audits the drop). Order-preserving; the
    /// broker deduplicates refs itself. `agent` must be a
    /// definition-derived tag or nil (legacy: filtered entries never
    /// match), never a wire tag or caller-provided name.
    public static func admittedBrokerEntries(
        entries: [RuntimeResourceProfile.BrokerEntry],
        agent: String?
    ) -> [(entry: RuntimeResourceProfile.BrokerEntry, ref: SecretRef)] {
        var admitted: [(entry: RuntimeResourceProfile.BrokerEntry, ref: SecretRef)] = []
        admitted.reserveCapacity(entries.count)
        for entry in entries {
            if let filter = entry.agents, filter.isEmpty == false {
                guard let agent, filter.contains(agent) else { continue }
            }
            guard let ref = entry.ref else { continue }
            admitted.append((entry, ref))
        }
        return admitted
    }

    // MARK: - MCP mediation (E1-E)

    /// Identity-required MCP admission.
    ///
    /// Sensitive mediated operation: the `submitIdentityRequired` pre-guard
    /// runs first (principal-less channels reject with `.principalRequired`
    /// and never downgrade), then the shared `authenticate` (capability,
    /// session, binding match, liveness, request replay), then the MCP
    /// policy gate. A `block` verdict denies before any invoke — no
    /// elicitation park, no secret touch, no transport. `approve` and
    /// `require_approval` admit (elicitation runs inside the invoker), as
    /// does an unparseable address, so the invoker audits the raw literal
    /// and answers `.unknownTool`. Admission burns the request id and the
    /// `mcp:<address>:<digest>:<idempotencyKey>` fingerprint exactly like
    /// the shell/http arms, so a repeated idempotency key replays.
    ///
    /// `verdict` resolves the policy for one parsed address; it receives
    /// the presented principal so production can key policy by Agent
    /// Definition. Like `submitLegacy`, the admitted placeholder response
    /// (`.executed(-1)`, result `"authorized"`) is never written: the
    /// dispatch layer overwrites it with the invoke outcome.
    public static func submitMCP(
        binding: inout RuntimeChannelBinding?,
        frame: Result<RuntimeActionFrame, RuntimeAdmissionDecodeError>,
        verdict: (AuthenticatedAgentContext?, MCPToolAddress) -> PolicyAction,
        agentContext: AuthenticatedAgentContext? = nil
    ) -> RuntimeMCPAdmissionDecision {
        guard binding != nil else {
            let requestID = frame.successValue?.requestID.rawValue.uuidString
            return stampMCP(
                rejectMCP(
                    binding: nil,
                    requestID: requestID,
                    reason: .unknownSession,
                    authorization: .rejected
                ),
                agentContext: agentContext
            )
        }
        if binding?.agentInstanceID == nil || agentContext == nil {
            let requestID = frame.successValue?.requestID.rawValue.uuidString
            return stampMCP(
                rejectMCP(
                    binding: binding,
                    requestID: requestID,
                    reason: .principalRequired,
                    authorization: .rejected
                ),
                agentContext: nil
            )
        }
        switch authenticate(binding: binding, frame: frame, agentContext: agentContext) {
        case .reject(let decision):
            binding = decision.binding
            return stampMCP(convertMCP(decision), agentContext: agentContext)
        case .accept(let accepted):
            guard var active = binding else {
                let requestID = accepted.requestID.rawValue.uuidString
                return stampMCP(
                    rejectMCP(
                        binding: nil,
                        requestID: requestID,
                        reason: .unknownSession,
                        authorization: .rejected
                    ),
                    agentContext: agentContext
                )
            }
            let requestID = accepted.requestID.rawValue.uuidString
            active.consumedRequestIDs.insert(accepted.requestID)
            guard case .mcp(let dispatch) = accepted.action else {
                binding = active
                return stampMCP(
                    makeMCP(
                        binding: active,
                        requestID: requestID,
                        fingerprint: nil,
                        dispatch: nil,
                        authorization: .evaluationFailed,
                        response: .evaluationFailed,
                        result: "evaluationFailed"
                    ),
                    agentContext: agentContext
                )
            }
            let fingerprint = ActionFingerprint(
                rawValue: "mcp:\(dispatch.address):\(dispatch.argsDigest):\(dispatch.idempotencyKey)"
            )
            // The policy gate precedes the fingerprint burn: a denied call
            // burns no fingerprint, so it can run after the verdict
            // changes — mirroring shell/http, where deny precedes the
            // execute burn.
            if let parsed = try? MCPToolAddress.parse(dispatch.address),
                verdict(agentContext, parsed) == .block
            {
                binding = active
                let deny = Deny(
                    ruleID: RuleID(pack: PackID(rawValue: "core.mcp"), pattern: "tool-blocked"),
                    reason: "mcp tool policy blocked this tool"
                )
                return stampMCP(
                    makeMCP(
                        binding: active,
                        requestID: requestID,
                        fingerprint: fingerprint.rawValue,
                        dispatch: dispatch,
                        authorization: .denied,
                        response: .denied(deny),
                        result: deny.ruleID.rawValue
                    ),
                    agentContext: agentContext
                )
            }
            if active.consumedFingerprints.contains(fingerprint) {
                binding = active
                return stampMCP(
                    rejectMCP(
                        binding: active,
                        requestID: requestID,
                        reason: .replay,
                        authorization: .rejected,
                        fingerprint: fingerprint.rawValue,
                        dispatch: dispatch
                    ),
                    agentContext: agentContext
                )
            }
            active.consumedFingerprints.insert(fingerprint)
            binding = active
            return stampMCP(
                makeMCP(
                    binding: active,
                    requestID: requestID,
                    fingerprint: fingerprint.rawValue,
                    dispatch: dispatch,
                    authorization: .allowed,
                    response: .executed(exitStatus: -1),
                    result: "authorized",
                    invoke: dispatch
                ),
                agentContext: agentContext
            )
        }
    }

    public static func submitLegacy(
        binding: inout RuntimeChannelBinding?,
        frame: Result<RuntimeActionFrame, RuntimeAdmissionDecodeError>,
        policy: EffectiveActionPolicy = .empty,
        approvalFor: (RuntimeActionRequestID, PendingAuthorization) -> Result<
            ApprovalDecision, AgentApprovalError
        >? = { _, _ in
            nil
        },
        agentContext: AuthenticatedAgentContext? = nil,
        propose: (RuntimeActionFrame) -> Result<ProposedAction, RuntimeAdmissionEvaluationError>
    ) -> RuntimeAdmissionDecision {
        switch authenticate(binding: binding, frame: frame, agentContext: agentContext) {
        case .reject(let decision):
            binding = decision.binding
            return stamp(decision, agentContext: agentContext)
        case .accept(let accepted):
            guard var active = binding else {
                return stamp(
                    reject(
                        binding: nil,
                        requestID: accepted.requestID.rawValue.uuidString,
                        reason: .unknownSession,
                        authorization: .rejected
                    ),
                    agentContext: agentContext
                )
            }
            let decision = authorize(
                binding: &active,
                frame: accepted,
                proposal: propose(accepted),
                policy: policy,
                approvalFor: approvalFor
            )
            binding = decision.binding
            return stamp(decision, agentContext: agentContext)
        }
    }

    static func authenticate(
        binding: RuntimeChannelBinding?,
        frame: Result<RuntimeActionFrame, RuntimeAdmissionDecodeError>,
        agentContext: AuthenticatedAgentContext? = nil
    ) -> RuntimeAdmissionAuthentication {
        guard let binding else {
            let requestID = frame.successValue?.requestID.rawValue.uuidString
            return .reject(
                reject(
                    binding: nil,
                    requestID: requestID,
                    reason: .unknownSession,
                    authorization: .rejected
                )
            )
        }
        guard binding.phase == .active else {
            let requestID = frame.successValue?.requestID.rawValue.uuidString
            return .reject(
                reject(
                    binding: binding,
                    requestID: requestID,
                    reason: .inactiveSession,
                    authorization: .rejected
                )
            )
        }
        let decoded: RuntimeActionFrame
        switch frame {
        case .failure:
            return .reject(
                reject(
                    binding: binding,
                    requestID: nil,
                    reason: .malformed,
                    authorization: .rejected
                )
            )
        case .success(let value):
            decoded = value
        }
        let requestID = decoded.requestID.rawValue.uuidString
        guard decoded.version == RuntimeAdmissionCodec.version else {
            return .reject(
                reject(
                    binding: binding,
                    requestID: requestID,
                    reason: .malformed,
                    authorization: .rejected
                )
            )
        }
        guard binding.capability.matches(decoded.capability) else {
            return .reject(
                reject(
                    binding: binding,
                    requestID: requestID,
                    reason: .invalidCapability,
                    authorization: .rejected
                )
            )
        }
        guard decoded.claimedSession.rawValue == binding.session.id.rawValue else {
            return .reject(
                reject(
                    binding: binding,
                    requestID: requestID,
                    reason: .impersonation,
                    authorization: .rejected
                )
            )
        }
        if let bound = binding.agentInstanceID {
            guard let context = agentContext else {
                return .reject(
                    reject(
                        binding: binding,
                        requestID: requestID,
                        reason: .principalRequired,
                        authorization: .rejected
                    )
                )
            }
            guard context.validity == .active else {
                return .reject(
                    reject(
                        binding: binding,
                        requestID: requestID,
                        reason: .inactiveSession,
                        authorization: .rejected
                    )
                )
            }
            guard context.instance.id == bound,
                context.instance.runtimeSessionID == binding.session.id,
                context.instance.workspaceSessionID == binding.session.workspaceSessionID
            else {
                return .reject(
                    reject(
                        binding: binding,
                        requestID: requestID,
                        reason: .impersonation,
                        authorization: .rejected
                    )
                )
            }
        }
        if binding.consumedRequestIDs.contains(decoded.requestID) {
            return .reject(
                reject(
                    binding: binding,
                    requestID: requestID,
                    reason: .replay,
                    authorization: .rejected
                )
            )
        }
        return .accept(decoded)
    }

    static func authorize(
        binding: inout RuntimeChannelBinding,
        frame: RuntimeActionFrame,
        proposal: Result<ProposedAction, RuntimeAdmissionEvaluationError>,
        policy: EffectiveActionPolicy,
        approvalFor: (RuntimeActionRequestID, PendingAuthorization) -> Result<
            ApprovalDecision, AgentApprovalError
        >?
    ) -> RuntimeAdmissionDecision {
        let requestID = frame.requestID.rawValue.uuidString
        binding.consumedRequestIDs.insert(frame.requestID)
        let action: ProposedAction
        switch proposal {
        case .failure:
            return make(
                binding: binding,
                requestID: requestID,
                fingerprint: nil,
                authorization: .evaluationFailed,
                response: .evaluationFailed,
                result: "evaluationFailed"
            )
        case .success(let proposed):
            action = proposed
        }
        let http = httpAudit(of: action)
        let authorization = AgentAuthorization.decide(
            action: action,
            policy: policy
        )
        let approval: Result<ApprovalDecision, AgentApprovalError>?
        if case .pending(let pending) = authorization {
            approval = approvalFor(frame.requestID, pending)
        } else {
            approval = nil
        }
        switch AgentAuthorization.step(authorization, approval: approval) {
        case .execute(let allowed):
            if binding.consumedFingerprints.contains(allowed.action.fingerprint) {
                return reject(
                    binding: binding,
                    requestID: requestID,
                    reason: .replay,
                    authorization: .rejected,
                    fingerprint: allowed.action.fingerprint.rawValue
                )
            }
            binding.consumedFingerprints.insert(allowed.action.fingerprint)
            return make(
                binding: binding,
                requestID: requestID,
                fingerprint: allowed.action.fingerprint.rawValue,
                authorization: .allowed,
                response: .executed(exitStatus: -1),
                result: "authorized",
                execute: allowed,
                http: http
            )
        case .denied(let denied):
            return make(
                binding: binding,
                requestID: requestID,
                fingerprint: action.fingerprint.rawValue,
                authorization: .denied,
                response: .denied(denied.deny),
                result: denied.deny.ruleID.rawValue,
                http: http
            )
        case .awaitingApproval(let pending):
            return make(
                binding: binding,
                requestID: requestID,
                fingerprint: action.fingerprint.rawValue,
                authorization: .pending,
                response: .pending(pending.reason.ledgerReason),
                result: pending.reason.ledgerReason.rawValue,
                http: http
            )
        case .approvalFailed:
            return make(
                binding: binding,
                requestID: requestID,
                fingerprint: action.fingerprint.rawValue,
                authorization: .approvalUnavailable,
                response: .approvalUnavailable,
                result: "approvalUnavailable",
                http: http
            )
        }
    }

    private static func httpAudit(of action: ProposedAction) -> HTTPAuditStamp? {
        guard case .http(let http) = action else { return nil }
        return HTTPAuditStamp(
            method: http.method.rawValue,
            destination: http.destination.auditedResource,
            address: http.destination.address?.presentation,
            queryPresent: http.destination.query != nil
        )
    }

    /// Converts an authentication rejection to the MCP decision shape.
    /// Authentication rejections never carry `execute`, so dropping it is
    /// lossless; the event converts field-for-field.
    private static func convertMCP(
        _ decision: RuntimeAdmissionDecision
    ) -> RuntimeMCPAdmissionDecision {
        RuntimeMCPAdmissionDecision(
            binding: decision.binding,
            response: decision.response,
            event: decision.event,
            invoke: nil
        )
    }

    private static func rejectMCP(
        binding: RuntimeChannelBinding?,
        requestID: String?,
        reason: RuntimeAdmissionRejection,
        authorization: RuntimeAdmissionAuthorization,
        fingerprint: String? = nil,
        dispatch: MCPDispatchAction? = nil
    ) -> RuntimeMCPAdmissionDecision {
        makeMCP(
            binding: binding,
            requestID: requestID,
            fingerprint: fingerprint,
            dispatch: dispatch,
            authorization: authorization,
            response: .rejected(reason),
            result: reason.rawValue
        )
    }

    private static func makeMCP(
        binding: RuntimeChannelBinding?,
        requestID: String?,
        fingerprint: String?,
        dispatch: MCPDispatchAction?,
        authorization: RuntimeAdmissionAuthorization,
        response: RuntimeAdmissionResponse,
        result: String,
        invoke: MCPDispatchAction? = nil
    ) -> RuntimeMCPAdmissionDecision {
        let parsed = dispatch.flatMap { try? MCPToolAddress.parse($0.address) }
        return RuntimeMCPAdmissionDecision(
            binding: binding,
            response: response,
            event: RuntimeAdmissionEvent(
                session: binding?.session.id.rawValue.uuidString,
                requestID: requestID,
                fingerprint: fingerprint,
                authorization: authorization,
                executionAttempted: false,
                result: result,
                workspace: binding?.session.workspaceSessionID.rawValue.uuidString,
                mcpAddress: dispatch?.address,
                mcpConnection: parsed?.connection
            ),
            invoke: invoke
        )
    }

    /// Principal attribution for one MCP decision. Mirrors `stamp`: the
    /// presented context only when the RV-held binding names that same
    /// instance, else the binding's instance with no definition.
    private static func stampMCP(
        _ decision: RuntimeMCPAdmissionDecision,
        agentContext: AuthenticatedAgentContext?
    ) -> RuntimeMCPAdmissionDecision {
        var stamped = decision
        let verified = agentContext.flatMap { context in
            decision.binding?.agentInstanceID == context.instance.id ? context : nil
        }
        stamped.event.agentInstance =
            verified?.instance.id.rawValue.uuidString
            ?? decision.binding?.agentInstanceID?.rawValue.uuidString
        stamped.event.agentDefinition = verified?.instance.definitionID.rawValue
        return stamped
    }

    /// Attributes the attempt to the presented principal only when the
    /// RV-held binding names that same instance (verified identity: the
    /// context matched the channel). A presented context the binding does
    /// not name is smuggled, not trusted — stamping it would misattribute
    /// an impersonation rejection to a principal that never authenticated.
    /// Unverified attempts stamp the binding's instance with no definition.
    /// Request bytes name no principal either way. Legacy channels stamp nils.
    private static func stamp(
        _ decision: RuntimeAdmissionDecision,
        agentContext: AuthenticatedAgentContext?
    ) -> RuntimeAdmissionDecision {
        var stamped = decision
        let verified = agentContext.flatMap { context in
            decision.binding?.agentInstanceID == context.instance.id ? context : nil
        }
        stamped.event.agentInstance =
            verified?.instance.id.rawValue.uuidString
            ?? decision.binding?.agentInstanceID?.rawValue.uuidString
        stamped.event.agentDefinition = verified?.instance.definitionID.rawValue
        return stamped
    }

    private static func reject(
        binding: RuntimeChannelBinding?,
        requestID: String?,
        reason: RuntimeAdmissionRejection,
        authorization: RuntimeAdmissionAuthorization,
        fingerprint: String? = nil
    ) -> RuntimeAdmissionDecision {
        make(
            binding: binding,
            requestID: requestID,
            fingerprint: fingerprint,
            authorization: authorization,
            response: .rejected(reason),
            result: reason.rawValue
        )
    }

    private static func make(
        binding: RuntimeChannelBinding?,
        requestID: String?,
        fingerprint: String?,
        authorization: RuntimeAdmissionAuthorization,
        response: RuntimeAdmissionResponse,
        result: String,
        execute: AllowedAction? = nil,
        http: HTTPAuditStamp? = nil
    ) -> RuntimeAdmissionDecision {
        RuntimeAdmissionDecision(
            binding: binding,
            response: response,
            event: RuntimeAdmissionEvent(
                session: binding?.session.id.rawValue.uuidString,
                requestID: requestID,
                fingerprint: fingerprint,
                authorization: authorization,
                executionAttempted: false,
                result: result,
                httpMethod: http?.method,
                httpDestination: http?.destination,
                httpAddress: http?.address,
                httpQueryPresent: http?.queryPresent,
                workspace: binding?.session.workspaceSessionID.rawValue.uuidString
            ),
            execute: execute
        )
    }
}

private struct HTTPAuditStamp {
    var method: String
    var destination: String
    var address: String?
    var queryPresent: Bool
}

private extension Result {
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}

// MARK: - MCP dispatch action (T0a codec, moved by E1-E)

// `RuntimeRequestedAction` holds this type, so it lives in RVDomain: the
// T0a definition in `ScopedInvoker.swift` moved here verbatim when E1-E
// added the `.mcp` case (a downstream module cannot own an upstream case
// payload). The v2 document codec below is untouched by the move.

/// MCP dispatch action with a versioned codec (T0a mediation shape).
///
/// T0a adds a new action case only for MCP dispatch, with codec v1→v2
/// versioning defined in this ticket. v1 carries `{version, address,
/// argsDigest}`; v2 adds the `idempotencyKey`. Migration fills a missing key
/// deterministically from the digest; rollback drops it. Unknown versions and
/// unknown fields fail closed.
public struct MCPDispatchAction: Hashable, Sendable, Equatable {
    /// Canonical tool address literal.
    public var address: String
    /// FNV-1a hex digest of the validated arguments text (dedupe key, not a
    /// security boundary: non-cryptographic by design, documented here).
    public var argsDigest: String
    /// Idempotency key binding elicitation and retry to one execution.
    public var idempotencyKey: String
    /// Raw arguments JSON object text, carried by the admission frame.
    /// E1-E addition: the T0a v2 document has no arguments member, so the
    /// dispatch codec ignores this field (decode fills `""`, encode omits
    /// it) and the v2 wire shape stays byte-identical. Dispatch passes it
    /// to the invoker, which schema-validates it; digest-only actions
    /// (`""`) fail there as invalid arguments, never silently.
    public var argumentsJSON: String

    /// Current codec version.
    public static let currentVersion = 2

    /// Assembles one dispatch action from validated parts.
    public init(address: String, argsDigest: String, idempotencyKey: String, argumentsJSON: String = "") {
        self.address = address
        self.argsDigest = argsDigest
        self.idempotencyKey = idempotencyKey
        self.argumentsJSON = argumentsJSON
    }
}

/// Typed dispatch-codec failures. Labels only; payloads never echo.
public enum MCPDispatchCodecError: Error, Hashable, Sendable, Equatable {
    /// The version is not 1 or 2.
    case unsupportedVersion(Int)
    /// The JSON shape is wrong or a required field is missing.
    case malformed
    /// An unknown field is present.
    case unknownField(String)
}

/// 64-bit FNV-1a hex digest. Deterministic dedupe key for dispatch actions
/// and idempotency binding. Explicitly NOT cryptographic: it detects
/// accidental change, never malice.
public enum MCPDispatchDigest {
    /// Digests UTF-8 text to 16 lowercase hex characters.
    public static func hex(of text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

/// Versioned JSON codec for `MCPDispatchAction`.
public enum MCPDispatchCodec {
    /// Encodes the v2 document: `{version:2, address, argsDigest, idempotencyKey}`.
    public static func encode(_ action: MCPDispatchAction) -> String? {
        let document: [String: Any] = [
            "version": MCPDispatchAction.currentVersion,
            "address": action.address,
            "argsDigest": action.argsDigest,
            "idempotencyKey": action.idempotencyKey,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    /// Decodes a v1 or v2 document. v1 migrates: the missing idempotency key
    /// fills deterministically as `migrated-<argsDigest>`.
    public static func decode(_ text: String) throws(MCPDispatchCodecError) -> MCPDispatchAction {
        guard let data = text.data(using: .utf8),
            let top = try? JSONSerialization.jsonObject(with: data),
            let object = top as? [String: Any]
        else {
            throw MCPDispatchCodecError.malformed
        }
        let known: Set<String> = ["version", "address", "argsDigest", "idempotencyKey"]
        for key in object.keys where known.contains(key) == false {
            throw MCPDispatchCodecError.unknownField(key)
        }
        guard let version = object["version"] as? Int else {
            throw MCPDispatchCodecError.malformed
        }
        guard version == 1 || version == 2 else {
            throw MCPDispatchCodecError.unsupportedVersion(version)
        }
        guard let address = object["address"] as? String, address.isEmpty == false,
            let digest = object["argsDigest"] as? String, digest.isEmpty == false
        else {
            throw MCPDispatchCodecError.malformed
        }
        if version == 2 {
            guard let key = object["idempotencyKey"] as? String, key.isEmpty == false else {
                throw MCPDispatchCodecError.malformed
            }
            return MCPDispatchAction(address: address, argsDigest: digest, idempotencyKey: key)
        }
        return MCPDispatchAction(address: address, argsDigest: digest, idempotencyKey: "migrated-\(digest)")
    }

    /// Rolls a v2 action back to its v1 document (key dropped).
    public static func rollbackToV1(_ action: MCPDispatchAction) -> String? {
        let document: [String: Any] = [
            "version": 1,
            "address": action.address,
            "argsDigest": action.argsDigest,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }
}

// MARK: - MCP admission wire limits

/// Admission wire caps for MCP frames. Mirrors `HTTPEgressLimits` and the
/// shell arm's `AgentRequestLimits`: every untrusted MCP field is bounded
/// before parsing. The arguments cap matches the invoker's
/// `MCPToolArguments.maximumBytes`, so admission never rejects a call the
/// invoker would accept (parity pinned by test).
public enum MCPDispatchWireLimits {
    /// Largest attempted address literal. A valid literal fits in 521
    /// bytes; unparseable literals fail downstream, but never oversized.
    public static let maxAddressUTF8Bytes = 1_024
    /// Largest arguments text. Parity with the invoker cap, pinned by test.
    public static let maxArgumentsUTF8Bytes = 8_192
    /// Largest idempotency key (UUIDs and migrated keys fit easily).
    public static let maxIdempotencyKeyUTF8Bytes = 256
}
