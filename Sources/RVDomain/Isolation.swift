/// Caller-requested isolation intent. Closed: no “contained-if-possible” boolean.
public enum RequestedIsolation: Sendable, Equatable {
    case observed
    case mediated
    case contained
}

/// Filesystem restriction a backend would have to establish.
/// `unrestricted` exists so observed and mediated plans stay honest.
/// `workspaceScoped` is read and write of that directory only. It is not an
/// ambient read with a write fence.
public enum FilesystemContainment: Sendable, Equatable {
    case unrestricted
    case workspaceScoped(WorkingDirectory)
}

/// Network restriction. Contained plans use `denied`, including loopback,
/// DNS, and Unix sockets. `unrestricted` is not a contained plan.
public enum NetworkContainment: Sendable, Equatable {
    case unrestricted
    case denied
}

/// Signals and other host-process interaction. Contained plans deny signals
/// to processes outside the sandbox. Descendants in that sandbox can still
/// signal each other.
public enum ProcessContainment: Sendable, Equatable {
    case unrestricted
    case hostSignalsDenied
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
/// Production `.contained` values come from `compileIsolationPlan`,
/// `compileContainedIsolation`, `compileContainedPlan`, or
/// `firstSliceContained`. The memberwise initializer is fileprivate so
/// other Domain files cannot mint
/// “contained but unrestricted.”
public struct IsolationGuarantees: Sendable, Equatable {
    public let filesystem: FilesystemContainment
    public let network: NetworkContainment
    public let process: ProcessContainment
    public let descent: DescentContainment

    fileprivate init(
        filesystem: FilesystemContainment,
        network: NetworkContainment,
        process: ProcessContainment,
        descent: DescentContainment
    ) {
        self.filesystem = filesystem
        self.network = network
        self.process = process
        self.descent = descent
    }

    /// Workspace read/write, no network, no signals to processes outside the
    /// sandbox, children inherit. A backend that cannot establish every field
    /// must refuse the launch.
    static func firstSliceContained(workspace: WorkingDirectory) -> IsolationGuarantees {
        IsolationGuarantees(
            filesystem: .workspaceScoped(workspace),
            network: .denied,
            process: .hostSignalsDenied,
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
    /// `compileContainedIsolation` was asked for `.observed` or `.mediated`.
    case notContainedRequest
}

/// Compiled isolation intent. A successful `.contained` mode is intended
/// guarantees for a later launch, not a claim that any agent is sandboxed.
///
/// Production construction is `compileIsolationPlan` or
/// `ContainedPlan.isolationPlan()`. The memberwise initializer is
/// fileprivate so requested and mode cannot diverge outside this file.
public struct IsolationPlan: Sendable, Equatable {
    public let requested: RequestedIsolation
    public let workspace: WorkingDirectory?
    public let repositoryRoot: RepositoryRoot?
    public let mode: EnforcementMode

    fileprivate init(
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

/// Compiled contained plan. Spawn and executable compile take this value.
/// `IsolationBackends.apply` still takes `plan`.
///
/// Production construction is `compileContainedIsolation` or
/// `IsolationPlan.containedIsolation()`. The memberwise initializer is
/// fileprivate so a contained value cannot carry an observed mode.
public struct ContainedIsolation: Sendable, Equatable {
    public let workspace: WorkingDirectory
    public let repositoryRoot: RepositoryRoot?
    public let guarantees: IsolationGuarantees

    public var plan: IsolationPlan {
        IsolationPlan(
            requested: .contained,
            workspace: workspace,
            repositoryRoot: repositoryRoot,
            mode: .contained(guarantees)
        )
    }

    fileprivate init(
        workspace: WorkingDirectory,
        repositoryRoot: RepositoryRoot?,
        guarantees: IsolationGuarantees
    ) {
        self.workspace = workspace
        self.repositoryRoot = repositoryRoot
        self.guarantees = guarantees
    }
}

public enum ContainedIsolationError: Error, Sendable, Equatable {
    case notContained
    case missingWorkspace
    case guaranteesMismatch
}

extension IsolationPlan {
    /// Narrows a compiled plan to the contained spawn door.
    /// Observed, mediated, a missing workspace, and guarantees other than
    /// the first-slice write limit fail closed.
    public func containedIsolation() -> Result<ContainedIsolation, ContainedIsolationError> {
        switch requested {
        case .observed, .mediated:
            return .failure(.notContained)
        case .contained:
            break
        }
        guard let workspace else {
            return .failure(.missingWorkspace)
        }
        switch mode {
        case .observed, .mediated:
            return .failure(.notContained)
        case .contained(let guarantees):
            guard isFirstSliceContained(guarantees, limitingWritesTo: workspace) else {
                return .failure(.guaranteesMismatch)
            }
            return .success(
                ContainedIsolation(
                    workspace: workspace,
                    repositoryRoot: repositoryRoot,
                    guarantees: guarantees
                )
            )
        }
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
            makeContainedIsolation(
                workspace: workspace,
                repositoryRoot: request.repositoryRoot
            ).plan
        )
    }
}

/// Contained spawn compile. Observed and mediated requests fail with
/// `notContainedRequest`. Contained without a workspace stays
/// `containedRequiresWorkspace`.
public func compileContainedIsolation(
    _ request: IsolationCompileRequest
) -> Result<ContainedIsolation, IsolationCompileError> {
    switch request.requested {
    case .observed, .mediated:
        return .failure(.notContainedRequest)
    case .contained:
        guard let workspace = request.workspace else {
            return .failure(.containedRequiresWorkspace)
        }
        return .success(
            makeContainedIsolation(
                workspace: workspace,
                repositoryRoot: request.repositoryRoot
            )
        )
    }
}

private func makeContainedIsolation(
    workspace: WorkingDirectory,
    repositoryRoot: RepositoryRoot?
) -> ContainedIsolation {
    ContainedIsolation(
        workspace: workspace,
        repositoryRoot: repositoryRoot,
        guarantees: IsolationGuarantees.firstSliceContained(workspace: workspace)
    )
}

private func isFirstSliceContained(
    _ guarantees: IsolationGuarantees,
    limitingWritesTo workspace: WorkingDirectory
) -> Bool {
    guarantees == IsolationGuarantees.firstSliceContained(workspace: workspace)
}

/// Isolation intent for the contained spawn doors. Workspace is required.
/// Guarantees are the first-slice contained set. Observed and mediated
/// plans are not this type.
public struct ContainedPlan: Sendable, Equatable {
    public let workspace: WorkingDirectory
    public let repositoryRoot: RepositoryRoot?
    public let guarantees: IsolationGuarantees

    public init(workspace: WorkingDirectory, repositoryRoot: RepositoryRoot? = nil) {
        self.workspace = workspace
        self.repositoryRoot = repositoryRoot
        self.guarantees = IsolationGuarantees.firstSliceContained(workspace: workspace)
    }

    /// `IsolationPlan` for `IsolationBackends.apply`. Contained doors convert only at that call.
    public func isolationPlan() -> IsolationPlan {
        IsolationPlan(
            requested: .contained,
            workspace: workspace,
            repositoryRoot: repositoryRoot,
            mode: .contained(guarantees)
        )
    }
}

/// Pure compile of a contained plan. Does not authorize, launch, or establish.
public func compileContainedPlan(
    workspace: WorkingDirectory,
    repositoryRoot: RepositoryRoot? = nil
) -> ContainedPlan {
    ContainedPlan(workspace: workspace, repositoryRoot: repositoryRoot)
}
