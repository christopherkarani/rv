import Testing
@testable import RVDomain

/// Isolation compile edges this suite encodes before / with production code:
/// 1. `.contained` + nil workspace → `.failure(.containedRequiresWorkspace)`
/// 2. `.contained` + `RepositoryRoot` only (workspace nil) → same failure
/// 3. `.observed` + workspace `/repo` → `.observed`, workspace recorded, not `.contained`
/// 4. `.mediated` + workspace `/repo` → `.mediated`, not `.contained`
/// 5. `.contained` + workspace `/repo` → writesLimited(`/repo`), descent `.inherited`,
///    network `.unrestricted`, `plan.workspace == /repo`
/// 6. `.contained` + workspace `/ws` + repositoryRoot `/repo` → write limit is `/ws`
/// 7. Empty-string workspace is unrepresentable as `WorkingDirectory` (no String bypass)
/// 8. Observed / mediated never carry `IsolationGuarantees` on `EnforcementMode`
/// 9. Contained first-slice must not use `filesystem == .unrestricted` or
///    `descent == .notInherited`
@Suite("IsolationPlan")
struct IsolationPlanTests {
    @Test func contained_withoutWorkspace_failsContainedRequiresWorkspace() {
        let result = compileIsolationPlan(
            IsolationCompileRequest(requested: .contained)
        )
        expectContainedRequiresWorkspace(result)
    }

    @Test func contained_repositoryRootOnly_failsContainedRequiresWorkspace() throws {
        let root = try requireRepositoryRoot("/repo")
        let result = compileIsolationPlan(
            IsolationCompileRequest(
                requested: .contained,
                workspace: nil,
                repositoryRoot: root
            )
        )
        expectContainedRequiresWorkspace(result)
    }

    @Test func observed_withoutWorkspace_returnsObserved() {
        let result = compileIsolationPlan(
            IsolationCompileRequest(requested: .observed)
        )
        expectObserved(
            result,
            workspace: nil,
            repositoryRoot: nil
        )
    }

    @Test func observed_withWorkspace_returnsObservedNotContained() throws {
        let workspace = try requireWorkspace("/repo")
        let result = compileIsolationPlan(
            IsolationCompileRequest(requested: .observed, workspace: workspace)
        )
        expectObserved(
            result,
            workspace: workspace,
            repositoryRoot: nil
        )
    }

    @Test func mediated_withWorkspace_returnsMediatedNotContained() throws {
        let workspace = try requireWorkspace("/repo")
        let result = compileIsolationPlan(
            IsolationCompileRequest(requested: .mediated, workspace: workspace)
        )
        expectMediated(
            result,
            workspace: workspace,
            repositoryRoot: nil
        )
    }

    @Test func contained_withWorkspace_writesLimitedInheritedNetworkUnrestricted() throws {
        let workspace = try requireWorkspace("/repo")
        let result = compileIsolationPlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        expectContainedFirstSlice(
            result,
            workspace: workspace,
            repositoryRoot: nil
        )
    }

    @Test func contained_differingRepositoryRoot_limitsWritesToWorkspace() throws {
        let workspace = try requireWorkspace("/ws")
        let root = try requireRepositoryRoot("/repo")
        let result = compileIsolationPlan(
            IsolationCompileRequest(
                requested: .contained,
                workspace: workspace,
                repositoryRoot: root
            )
        )
        expectContainedFirstSlice(
            result,
            workspace: workspace,
            repositoryRoot: root
        )
    }

    @Test func emptyStringWorkspace_isUnrepresentableAsWorkingDirectory() {
        #expect(WorkingDirectory(validating: "") == nil)
        #expect(WorkingDirectory(rawValue: "") == nil)
    }

    @Test func observedAndMediated_neverCarryIsolationGuarantees() throws {
        let workspace = try requireWorkspace("/repo")
        let observed = compileIsolationPlan(
            IsolationCompileRequest(requested: .observed, workspace: workspace)
        )
        let mediated = compileIsolationPlan(
            IsolationCompileRequest(requested: .mediated, workspace: workspace)
        )
        expectObserved(observed, workspace: workspace, repositoryRoot: nil)
        expectMediated(mediated, workspace: workspace, repositoryRoot: nil)
    }

    @Test func containedFirstSlice_rejectsUnrestrictedFilesystemAndNotInheritedDescent() throws {
        let workspace = try requireWorkspace("/repo")
        let compiled = compileIsolationPlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        expectContainedFirstSlice(
            compiled,
            workspace: workspace,
            repositoryRoot: nil
        )

        let factory = IsolationGuarantees.firstSliceContained(workspace: workspace)
        switch factory.filesystem {
        case .writesLimited(let limitedTo):
            #expect(limitedTo == workspace)
        case .unrestricted:
            Issue.record("first-slice factory must not mint unrestricted filesystem")
        }
        switch factory.descent {
        case .inherited:
            break
        case .notInherited:
            Issue.record("first-slice factory must not mint notInherited descent")
        }
        switch factory.network {
        case .unrestricted:
            break
        }
    }

    @Test func enforcementMode_hasExactlyThreeCases() throws {
        let workspace = try requireWorkspace("/repo")
        let observed = compileIsolationPlan(IsolationCompileRequest(requested: .observed))
        let mediated = compileIsolationPlan(IsolationCompileRequest(requested: .mediated))
        let contained = compileIsolationPlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        expectObserved(observed, workspace: nil, repositoryRoot: nil)
        expectMediated(mediated, workspace: nil, repositoryRoot: nil)
        expectContainedFirstSlice(contained, workspace: workspace, repositoryRoot: nil)
    }

    @Test func isolationCompile_operatorProbe_printsIntendedModes() throws {
        let workspace = try requireWorkspace("/repo")
        let observed = compileIsolationPlan(IsolationCompileRequest(requested: .observed))
        let mediated = compileIsolationPlan(
            IsolationCompileRequest(requested: .mediated, workspace: workspace)
        )
        let contained = compileIsolationPlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        let containedMissingWorkspace = compileIsolationPlan(
            IsolationCompileRequest(requested: .contained)
        )

        expectObserved(observed, workspace: nil, repositoryRoot: nil)
        expectMediated(mediated, workspace: workspace, repositoryRoot: nil)
        expectContainedFirstSlice(contained, workspace: workspace, repositoryRoot: nil)
        expectContainedRequiresWorkspace(containedMissingWorkspace)

        print(probeLine(requested: .observed, result: observed))
        print(probeLine(requested: .mediated, result: mediated))
        print(probeLine(requested: .contained, result: contained))
        print(probeLine(requested: .contained, result: containedMissingWorkspace))
    }

    @Test func isolationPlan_productionConstruction_isCompileOrInternalFactory() throws {
        let workspace = try requireWorkspace("/repo")
        let compiled = compileIsolationPlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        let factory = IsolationGuarantees.firstSliceContained(workspace: workspace)
        switch compiled {
        case .success(let plan):
            switch plan.mode {
            case .observed:
                Issue.record("production contained compile must not be observed")
            case .mediated:
                Issue.record("production contained compile must not be mediated")
            case .contained(let guarantees):
                #expect(guarantees == factory)
            }
        case .failure(let error):
            switch error {
            case .containedRequiresWorkspace:
                Issue.record("contained with workspace must succeed via compile")
            }
        }
    }
}

private func requireWorkspace(_ path: String) throws -> WorkingDirectory {
    try #require(WorkingDirectory(validating: path))
}

private func requireRepositoryRoot(_ path: String) throws -> RepositoryRoot {
    try #require(RepositoryRoot(validating: path))
}

private func expectContainedRequiresWorkspace(
    _ result: Result<IsolationPlan, IsolationCompileError>,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .success(let plan):
        Issue.record(
            "contained without workspace must fail closed, got mode \(describeMode(plan.mode))",
            sourceLocation: sourceLocation
        )
    case .failure(let error):
        switch error {
        case .containedRequiresWorkspace:
            break
        }
    }
}

private func expectObserved(
    _ result: Result<IsolationPlan, IsolationCompileError>,
    workspace: WorkingDirectory?,
    repositoryRoot: RepositoryRoot?,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .success(let plan):
        #expect(plan.requested == .observed, sourceLocation: sourceLocation)
        #expect(plan.workspace == workspace, sourceLocation: sourceLocation)
        #expect(plan.repositoryRoot == repositoryRoot, sourceLocation: sourceLocation)
        switch plan.mode {
        case .observed:
            break
        case .mediated:
            Issue.record("observed compile must not be mediated", sourceLocation: sourceLocation)
        case .contained:
            Issue.record(
                "observed compile must not be contained",
                sourceLocation: sourceLocation
            )
        }
    case .failure(let error):
        switch error {
        case .containedRequiresWorkspace:
            Issue.record(
                "observed compile must not fail containedRequiresWorkspace",
                sourceLocation: sourceLocation
            )
        }
    }
}

private func expectMediated(
    _ result: Result<IsolationPlan, IsolationCompileError>,
    workspace: WorkingDirectory?,
    repositoryRoot: RepositoryRoot?,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .success(let plan):
        #expect(plan.requested == .mediated, sourceLocation: sourceLocation)
        #expect(plan.workspace == workspace, sourceLocation: sourceLocation)
        #expect(plan.repositoryRoot == repositoryRoot, sourceLocation: sourceLocation)
        switch plan.mode {
        case .mediated:
            break
        case .observed:
            Issue.record("mediated compile must not be observed", sourceLocation: sourceLocation)
        case .contained:
            Issue.record(
                "mediated compile must not be contained",
                sourceLocation: sourceLocation
            )
        }
    case .failure(let error):
        switch error {
        case .containedRequiresWorkspace:
            Issue.record(
                "mediated compile must not fail containedRequiresWorkspace",
                sourceLocation: sourceLocation
            )
        }
    }
}

private func expectContainedFirstSlice(
    _ result: Result<IsolationPlan, IsolationCompileError>,
    workspace: WorkingDirectory,
    repositoryRoot: RepositoryRoot?,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .success(let plan):
        #expect(plan.requested == .contained, sourceLocation: sourceLocation)
        #expect(plan.workspace == workspace, sourceLocation: sourceLocation)
        #expect(plan.repositoryRoot == repositoryRoot, sourceLocation: sourceLocation)
        switch plan.mode {
        case .observed:
            Issue.record("contained compile must not be observed", sourceLocation: sourceLocation)
        case .mediated:
            Issue.record("contained compile must not be mediated", sourceLocation: sourceLocation)
        case .contained(let guarantees):
            switch guarantees.filesystem {
            case .writesLimited(let limitedTo):
                #expect(limitedTo == workspace, sourceLocation: sourceLocation)
                #expect(plan.workspace == limitedTo, sourceLocation: sourceLocation)
            case .unrestricted:
                Issue.record(
                    "contained first-slice must not use unrestricted filesystem",
                    sourceLocation: sourceLocation
                )
            }
            switch guarantees.descent {
            case .inherited:
                break
            case .notInherited:
                Issue.record(
                    "contained first-slice must not use notInherited descent",
                    sourceLocation: sourceLocation
                )
            }
            switch guarantees.network {
            case .unrestricted:
                break
            }
        }
    case .failure(let error):
        switch error {
        case .containedRequiresWorkspace:
            Issue.record(
                "contained with workspace must not fail containedRequiresWorkspace",
                sourceLocation: sourceLocation
            )
        }
    }
}

private func probeLine(
    requested: RequestedIsolation,
    result: Result<IsolationPlan, IsolationCompileError>
) -> String {
    let requestedLabel: String
    switch requested {
    case .observed:
        requestedLabel = "observed"
    case .mediated:
        requestedLabel = "mediated"
    case .contained:
        requestedLabel = "contained"
    }
    switch result {
    case .success(let plan):
        return "requested=\(requestedLabel) mode=\(describeMode(plan.mode)) error=none"
    case .failure(let error):
        switch error {
        case .containedRequiresWorkspace:
            return "requested=\(requestedLabel) mode=none error=containedRequiresWorkspace"
        }
    }
}

private func describeMode(_ mode: EnforcementMode) -> String {
    switch mode {
    case .observed:
        return "observed"
    case .mediated:
        return "mediated"
    case .contained:
        return "contained"
    }
}
