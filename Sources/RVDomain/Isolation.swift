/// Caller-requested isolation intent. Closed: no “contained-if-possible” boolean.
public enum RequestedIsolation: Sendable, Equatable {
    case observed
    case mediated
    case contained
}

/// Filesystem restriction a backend would have to establish. First-slice contained
/// compile uses `writesLimited`; `unrestricted` exists so observed/mediated stay honest.
public enum FilesystemContainment: Sendable, Equatable {
    case unrestricted
    case writesLimited(to: WorkingDirectory)
}

/// Network restriction. A single case documents that this slice does not promise
/// a block. Do not infer “contained ⇒ no network.”
public enum NetworkContainment: Sendable, Equatable {
    case unrestricted
}

/// Whether child processes inherit the same OS ruleset.
///
/// Contained first-slice compile always uses `inherited`. `notInherited` stays
/// representable so an insufficient set cannot be mistaken for a successful
/// contained plan.
public enum DescentContainment: Sendable, Equatable {
    case notInherited
    case inherited
}

/// Concrete restrictions a later launch would have to establish.
///
/// Production `.contained` values come from `compileIsolationPlan` or
/// `firstSliceContained`. The memberwise initializer is a `@testable` seam.
public struct IsolationGuarantees: Sendable, Equatable {
    public let filesystem: FilesystemContainment
    public let network: NetworkContainment
    public let descent: DescentContainment

    init(
        filesystem: FilesystemContainment,
        network: NetworkContainment,
        descent: DescentContainment
    ) {
        self.filesystem = filesystem
        self.network = network
        self.descent = descent
    }

    /// Write-limit + inherit only. Network stays unrestricted.
    static func firstSliceContained(workspace: WorkingDirectory) -> IsolationGuarantees {
        IsolationGuarantees(
            filesystem: .writesLimited(to: workspace),
            network: .unrestricted,
            descent: .inherited
        )
    }
}

/// Intended enforcement on an `IsolationPlan`. Not an established sandbox.
///
/// `.contained` always carries guarantees. No `stronglyIsolated`. No `contained: Bool`.
public enum EnforcementMode: Sendable, Equatable {
    case observed
    case mediated
    case contained(IsolationGuarantees)
}

/// Untrusted compile input. Empty-string workspace is unrepresentable because
/// the field is `WorkingDirectory?`, not `String`.
public struct IsolationCompileRequest: Sendable, Equatable {
    public let requested: RequestedIsolation
    public let workspace: WorkingDirectory?
    public let repositoryRoot: RepositoryRoot?

    public init(
        requested: RequestedIsolation,
        workspace: WorkingDirectory? = nil,
        repositoryRoot: RepositoryRoot? = nil
    ) {
        self.requested = requested
        self.workspace = workspace
        self.repositoryRoot = repositoryRoot
    }
}

/// Fail-closed compile error. Contained without a workspace produces no plan.
public enum IsolationCompileError: Error, Sendable, Equatable {
    /// `.contained` requires `WorkingDirectory`. `RepositoryRoot` cannot substitute.
    case containedRequiresWorkspace
}

/// Compiled isolation intent. A successful `.contained` mode is intended
/// guarantees for a later launch, not a claim that any agent is sandboxed.
///
/// Production construction is `compileIsolationPlan`. The memberwise
/// initializer is a `@testable` seam.
public struct IsolationPlan: Sendable, Equatable {
    public let requested: RequestedIsolation
    public let workspace: WorkingDirectory?
    public let repositoryRoot: RepositoryRoot?
    public let mode: EnforcementMode

    init(
        requested: RequestedIsolation,
        workspace: WorkingDirectory?,
        repositoryRoot: RepositoryRoot?,
        mode: EnforcementMode
    ) {
        self.requested = requested
        self.workspace = workspace
        self.repositoryRoot = repositoryRoot
        self.mode = mode
    }
}

/// Pure compile of isolation intent. Does not authorize, launch, or establish.
public func compileIsolationPlan(
    _ request: IsolationCompileRequest
) -> Result<IsolationPlan, IsolationCompileError> {
    switch request.requested {
    case .observed:
        return .success(
            IsolationPlan(
                requested: .observed,
                workspace: request.workspace,
                repositoryRoot: request.repositoryRoot,
                mode: .observed
            )
        )
    case .mediated:
        return .success(
            IsolationPlan(
                requested: .mediated,
                workspace: request.workspace,
                repositoryRoot: request.repositoryRoot,
                mode: .mediated
            )
        )
    case .contained:
        guard let workspace = request.workspace else {
            return .failure(.containedRequiresWorkspace)
        }
        return .success(
            IsolationPlan(
                requested: .contained,
                workspace: workspace,
                repositoryRoot: request.repositoryRoot,
                mode: .contained(IsolationGuarantees.firstSliceContained(workspace: workspace))
            )
        )
    }
}
