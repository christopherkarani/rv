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
public enum RuntimeRequestedAction: Sendable, Equatable {
    case shell(ShellCommand)
    case http(method: String, url: String)
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
        agentDefinition: String? = nil
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
