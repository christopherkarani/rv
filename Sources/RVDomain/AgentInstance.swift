import Foundation

/// Recorded executable facts for one launch. Evidence only; policy decides
/// which facts a launch requires. Absent facts were not established.
public struct ExecutableEvidence: Hashable, Sendable, Equatable, Codable {
    public let canonicalPath: String?
    public let deviceID: UInt64?
    public let inode: UInt64?
    public let contentDigestSHA256: String?
    public let signingTeamID: String?
    public let codeIdentifier: String?
    public let codeRequirement: String?
    public let interpreterCanonicalPath: String?
    public let scriptDigestSHA256: String?
    public let pid: Int32?
    public let processStartTime: Date?

    public init(
        canonicalPath: String? = nil,
        deviceID: UInt64? = nil,
        inode: UInt64? = nil,
        contentDigestSHA256: String? = nil,
        signingTeamID: String? = nil,
        codeIdentifier: String? = nil,
        codeRequirement: String? = nil,
        interpreterCanonicalPath: String? = nil,
        scriptDigestSHA256: String? = nil,
        pid: Int32? = nil,
        processStartTime: Date? = nil
    ) {
        self.canonicalPath = canonicalPath
        self.deviceID = deviceID
        self.inode = inode
        self.contentDigestSHA256 = contentDigestSHA256
        self.signingTeamID = signingTeamID
        self.codeIdentifier = codeIdentifier
        self.codeRequirement = codeRequirement
        self.interpreterCanonicalPath = interpreterCanonicalPath
        self.scriptDigestSHA256 = scriptDigestSHA256
        self.pid = pid
        self.processStartTime = processStartTime
    }

    /// No evidence established. Pairs with `ExecutableAssurance.unattested`.
    public static let none = ExecutableEvidence()
}

/// Stored lifecycle state of one instance record. Forward-only; a finished
/// instance never becomes active again. A new execution mints a new
/// instance instead.
public enum AgentInstanceStatus: String, Hashable, Sendable, Equatable, Codable {
    case establishing
    case active
    case finished

    public func transition(_ event: AgentInstanceStatusEvent) -> AgentInstanceStatus? {
        switch (self, event) {
        case (.establishing, .becameActive):
            .active
        case (.active, .didFinish), (.establishing, .didFinish):
            .finished
        default:
            nil
        }
    }
}

/// Legal moves on `AgentInstanceStatus`. Anything else is refused.
public enum AgentInstanceStatusEvent: Hashable, Sendable, Equatable {
    case becameActive
    case didFinish
}

/// Authorization validity of one instance. Pure transitions only; the
/// authoritative live lookup lands in PR3. Nothing transitions back to
/// `active`: recovery means minting a fresh instance, never relabeling.
public enum AgentInstanceValidity: String, Hashable, Sendable, Equatable, Codable {
    case active
    case revoking
    case inactive
    case unknown

    public func transition(_ event: AgentInstanceValidityEvent) -> AgentInstanceValidity? {
        switch (self, event) {
        case (.inactive, .didEstablish):
            .active
        case (.active, .beginRevoking):
            .revoking
        case (.active, .didDeactivate), (.revoking, .didDeactivate), (.unknown, .didDeactivate):
            .inactive
        default:
            nil
        }
    }
}

/// Legal moves on `AgentInstanceValidity`. Anything else is refused.
public enum AgentInstanceValidityEvent: Hashable, Sendable, Equatable {
    case didEstablish
    case beginRevoking
    case didDeactivate
}

/// Pure AgentInstance lifecycle ledger. No clock, filesystem, or lock reads.
///
/// The registry copies one `Record` of explicit values out from under its
/// lock and decides here; every validity edge — activation, revoke claim,
/// revoke finish — routes through `transition(_:)`, so the decisions are
/// total over their inputs and testable without a registry. The ledger
/// returns the next validity to commit; journaling and generation stay
/// with the caller.
public enum AgentInstanceLedger: Sendable {
    /// Decision inputs for one live record. Values only; the ledger never
    /// observes a lock.
    public struct Record: Hashable, Sendable, Equatable {
        public let validity: AgentInstanceValidity
        public let finished: Bool
        public let teardownClaimed: Bool

        public init(validity: AgentInstanceValidity, finished: Bool, teardownClaimed: Bool) {
            self.validity = validity
            self.finished = finished
            self.teardownClaimed = teardownClaimed
        }
    }

    /// Activation decision. Total over (`Record`, `bindingMatches`).
    public enum Activation: Hashable, Sendable, Equatable {
        /// Journal `.established`, then commit `next`. Fail-closed: a
        /// journal failure refuses without touching live state.
        case establish(next: AgentInstanceValidity)
        /// Already usable: return the live context, journal nothing.
        case alreadyActive
        /// Refuse: return nil, journal nothing, touch nothing.
        case refuse
    }

    public static func decideActivate(
        _ record: Record,
        bindingMatches: Bool
    ) -> Activation {
        guard bindingMatches, record.finished == false, record.teardownClaimed == false else {
            return .refuse
        }
        if record.validity == .active {
            return .alreadyActive
        }
        guard let next = record.validity.transition(.didEstablish) else {
            return .refuse
        }
        return .establish(next: next)
    }

    /// Revoke-claim decision. Total over `Record`.
    public enum RevokeClaim: Hashable, Sendable, Equatable {
        /// Move to `next`, claim teardown, journal `.revoking`.
        case beginRevoking(next: AgentInstanceValidity)
        /// The instance never became active: claim teardown and finish
        /// without a `.revoking` edge or journal line. Totality-wise this
        /// also covers any other non-active validity; only `.active`
        /// carries a revoking edge.
        case neverActive
        /// Teardown is already claimed: this revoke runs nothing.
        case refuse
    }

    public static func decideRevokeClaim(_ record: Record) -> RevokeClaim {
        guard record.teardownClaimed == false else {
            return .refuse
        }
        guard let next = record.validity.transition(.beginRevoking) else {
            return .neverActive
        }
        return .beginRevoking(next: next)
    }

    /// Revoke-finish decision. Total over `Record`.
    public enum RevokeFinish: Hashable, Sendable, Equatable {
        /// Move to `next` via the `.didDeactivate` edge.
        case deactivate(next: AgentInstanceValidity)
        /// Never-active record: already `.inactive`, so there is no
        /// `.didDeactivate` edge to take. Still finishes and still
        /// advances the generation exactly like a deactivation.
        case confirmInactive
        /// Already finished: no-op.
        case alreadyFinished
    }

    public static func decideRevokeFinish(_ record: Record) -> RevokeFinish {
        guard record.finished == false else {
            return .alreadyFinished
        }
        guard let next = record.validity.transition(.didDeactivate) else {
            return .confirmInactive
        }
        return .deactivate(next: next)
    }
}

/// Parent link plus the authority snapshot RV granted the child.
///
/// Domain foundation only: narrowing is enforced where the child record is
/// created. Delegation is never credential copying; this record carries an
/// authority snapshot, and the child instance carries no parent credential.
public struct AgentDelegation: Hashable, Sendable, Equatable, Codable {
    public let parentInstanceID: AgentInstanceID
    public let delegatedAuthority: AgentAuthority

    public init(parentInstanceID: AgentInstanceID, delegatedAuthority: AgentAuthority) {
        self.parentInstanceID = parentInstanceID
        self.delegatedAuthority = delegatedAuthority
    }
}

/// One concrete execution of an Agent Definition: the security principal.
///
/// Immutable after establishment. A material change (restart, different
/// executable, definition, workspace, or process group) mints a new
/// instance instead of mutating this one.
///
/// This record carries no `RuntimeCapability`: a capability is a credential
/// issued to an already-established instance, never part of its identity.
///
/// Not `Codable`: it binds `RuntimeSessionID`, `WorkspaceSessionID`, and
/// `RuntimeChildIdentity`, which predate `Codable`. Later PRs add explicit
/// persistence/audit codecs without changing those existing types.
public struct AgentInstance: Hashable, Sendable, Equatable {
    public let id: AgentInstanceID
    public let owner: OwnerPrincipal
    public let definitionID: AgentDefinitionID
    public let definitionRevision: AgentDefinitionRevision
    public let workspaceSessionID: WorkspaceSessionID
    public let runtimeSessionID: RuntimeSessionID
    public let executableEvidence: ExecutableEvidence
    public let assurance: ExecutableAssurance
    public let groupLeader: RuntimeChildIdentity
    public let workloadProcess: RuntimeChildIdentity?
    public let parent: AgentDelegation?
    public let effectiveAuthority: AgentAuthority
    public let delegableAuthority: AgentAuthority
    public let mintedAt: Date

    public init(
        id: AgentInstanceID,
        owner: OwnerPrincipal,
        definitionID: AgentDefinitionID,
        definitionRevision: AgentDefinitionRevision,
        workspaceSessionID: WorkspaceSessionID,
        runtimeSessionID: RuntimeSessionID,
        executableEvidence: ExecutableEvidence,
        assurance: ExecutableAssurance,
        groupLeader: RuntimeChildIdentity,
        workloadProcess: RuntimeChildIdentity?,
        parent: AgentDelegation?,
        effectiveAuthority: AgentAuthority,
        delegableAuthority: AgentAuthority,
        mintedAt: Date
    ) {
        self.id = id
        self.owner = owner
        self.definitionID = definitionID
        self.definitionRevision = definitionRevision
        self.workspaceSessionID = workspaceSessionID
        self.runtimeSessionID = runtimeSessionID
        self.executableEvidence = executableEvidence
        self.assurance = assurance
        self.groupLeader = groupLeader
        self.workloadProcess = workloadProcess
        self.parent = parent
        self.effectiveAuthority = effectiveAuthority
        self.delegableAuthority = delegableAuthority
        self.mintedAt = mintedAt
    }

    /// Creates the record for a delegated child of this instance, or nil
    /// when `authority` widens beyond this instance's delegable authority.
    /// Equal authority is accepted; authority only narrows.
    ///
    /// The child always mints a fresh instance ID, binds the caller-supplied
    /// fresh runtime session, keeps an explicit parent reference with its own
    /// authority snapshot, and inherits owner, definition, and workspace from
    /// the parent. No parent credential material is copied: the child carries
    /// none.
    public func makeDelegatedChild(
        authority: AgentAuthority,
        runtimeSessionID: RuntimeSessionID,
        executableEvidence: ExecutableEvidence,
        assurance: ExecutableAssurance,
        groupLeader: RuntimeChildIdentity,
        workloadProcess: RuntimeChildIdentity?,
        mintedAt: Date
    ) -> AgentInstance? {
        guard delegableAuthority.contains(authority) else {
            return nil
        }
        return AgentInstance(
            id: AgentInstanceID(),
            owner: owner,
            definitionID: definitionID,
            definitionRevision: definitionRevision,
            workspaceSessionID: workspaceSessionID,
            runtimeSessionID: runtimeSessionID,
            executableEvidence: executableEvidence,
            assurance: assurance,
            groupLeader: groupLeader,
            workloadProcess: workloadProcess,
            parent: AgentDelegation(parentInstanceID: id, delegatedAuthority: authority),
            effectiveAuthority: authority,
            delegableAuthority: authority,
            mintedAt: mintedAt
        )
    }
}

/// Trusted principal context for admission and policy evaluation.
///
/// PR3 wires this shape into `RuntimeAdmissionSubject`; here it pairs the
/// established instance with its evaluated validity. Only `active`
/// validity is usable; every other state fails closed.
///
/// Step 8 (F3): this context proves AGENT PRINCIPAL authority. A
/// `RuntimeCapability` proves channel authority only. Sensitive mediated
/// operations require this context (via `submitIdentityRequired`) plus
/// the channel capability where applicable — never the capability alone.
public struct AuthenticatedAgentContext: Hashable, Sendable, Equatable {
    public let instance: AgentInstance
    public let validity: AgentInstanceValidity

    public init(instance: AgentInstance, validity: AgentInstanceValidity) {
        self.instance = instance
        self.validity = validity
    }

    public var isUsable: Bool {
        validity == .active
    }
}
