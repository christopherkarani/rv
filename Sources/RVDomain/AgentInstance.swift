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
    case beginRevoking
    case didDeactivate
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
