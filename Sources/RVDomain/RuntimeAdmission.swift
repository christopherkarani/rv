import Foundation

/// Unguessable secret for one contained runtime.
///
/// `RuntimeSessionID` names the launch. This value proves the caller received
/// the channel RV granted to that launch. A 32-byte token is not a session id
/// and is not accepted from a short or non-hex string.
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
public struct RuntimeSessionClaim: Hashable, Sendable, Equatable {
    public let rawValue: UUID

    public init?(validating text: String) {
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
    public var consumedRequestIDs: Set<RuntimeActionRequestID>
    public var consumedFingerprints: Set<ActionFingerprint>

    public init(
        session: RuntimeSession,
        capability: RuntimeCapability,
        phase: RuntimeAdmissionPhase = .active,
        consumedRequestIDs: Set<RuntimeActionRequestID> = [],
        consumedFingerprints: Set<ActionFingerprint> = []
    ) {
        self.session = session
        self.capability = capability
        self.phase = phase
        self.consumedRequestIDs = consumedRequestIDs
        self.consumedFingerprints = consumedFingerprints
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

    public init(session: RuntimeSession, policyWorkspace: WorkingDirectory) {
        self.session = session
        self.policyWorkspace = policyWorkspace
    }
}

/// Untrusted action after a successful decode. Holding one is not authority.
public struct RuntimeActionFrame: Sendable, Equatable {
    public var version: Int
    public var requestID: RuntimeActionRequestID
    public var capability: RuntimeCapability
    public var claimedSession: RuntimeSessionClaim
    public var command: ShellCommand

    public init(
        version: Int,
        requestID: RuntimeActionRequestID,
        capability: RuntimeCapability,
        claimedSession: RuntimeSessionClaim,
        command: ShellCommand
    ) {
        self.version = version
        self.requestID = requestID
        self.capability = capability
        self.claimedSession = claimedSession
        self.command = command
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

    public init(
        session: String?,
        requestID: String?,
        fingerprint: String?,
        authorization: RuntimeAdmissionAuthorization,
        executionAttempted: Bool,
        result: String
    ) {
        self.session = session
        self.requestID = requestID
        self.fingerprint = fingerprint
        self.authorization = authorization
        self.executionAttempted = executionAttempted
        self.result = result
    }
}

public struct RuntimeAdmissionDecision: Sendable, Equatable {
    public var binding: RuntimeChannelBinding?
    public var response: RuntimeAdmissionResponse
    public var event: RuntimeAdmissionEvent
    /// Set only when the shell must perform the side effect.
    public var execute: AllowedAction?

    public init(
        binding: RuntimeChannelBinding?,
        response: RuntimeAdmissionResponse,
        event: RuntimeAdmissionEvent,
        execute: AllowedAction? = nil
    ) {
        self.binding = binding
        self.response = response
        self.event = event
        self.execute = execute
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
public enum RuntimeAdmissionGate {
    public static func submit(
        binding: inout RuntimeChannelBinding?,
        frame: Result<RuntimeActionFrame, RuntimeAdmissionDecodeError>,
        policy: EffectiveActionPolicy = .empty,
        approvalFor: (PendingAuthorization) -> Result<ApprovalDecision, AgentApprovalError>? = { _ in
            nil
        },
        propose: (RuntimeActionFrame) -> Result<ProposedAction, RuntimeAdmissionEvaluationError>
    ) -> RuntimeAdmissionDecision {
        switch authenticate(binding: binding, frame: frame) {
        case .reject(let decision):
            binding = decision.binding
            return decision
        case .accept(let accepted):
            guard var active = binding else {
                return reject(
                    binding: nil,
                    requestID: accepted.requestID.rawValue.uuidString,
                    reason: .unknownSession,
                    authorization: .rejected
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
            return decision
        }
    }

    static func authenticate(
        binding: RuntimeChannelBinding?,
        frame: Result<RuntimeActionFrame, RuntimeAdmissionDecodeError>
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
        approvalFor: (PendingAuthorization) -> Result<ApprovalDecision, AgentApprovalError>?
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
        let authorization = AgentAuthorization.decide(
            action: action,
            policy: policy
        )
        let approval: Result<ApprovalDecision, AgentApprovalError>?
        if case .pending(let pending) = authorization {
            approval = approvalFor(pending)
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
                execute: allowed
            )
        case .denied(let denied):
            return make(
                binding: binding,
                requestID: requestID,
                fingerprint: action.fingerprint.rawValue,
                authorization: .denied,
                response: .denied(denied.deny),
                result: denied.deny.ruleID.rawValue
            )
        case .awaitingApproval(let pending):
            return make(
                binding: binding,
                requestID: requestID,
                fingerprint: action.fingerprint.rawValue,
                authorization: .pending,
                response: .pending(pending.reason),
                result: pending.reason.rawValue
            )
        case .approvalFailed:
            return make(
                binding: binding,
                requestID: requestID,
                fingerprint: action.fingerprint.rawValue,
                authorization: .approvalUnavailable,
                response: .approvalUnavailable,
                result: "approvalUnavailable"
            )
        }
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
        execute: AllowedAction? = nil
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
                result: result
            ),
            execute: execute
        )
    }
}

private extension Result {
    var successValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
