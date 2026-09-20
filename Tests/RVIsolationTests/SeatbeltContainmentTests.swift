#if os(macOS)
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Darwin kernel edges this suite encodes before production code:
/// 10. contained + `seatbelt()`: `touch` inside workspace → `exitStatus == 0`,
///     file exists, established `.contained` first-slice, family `.seatbelt`
/// 11. contained + `seatbelt()`: `touch` outside workspace (sibling path) →
///     `exitStatus != 0`, file absent, established still `.contained` / `.seatbelt`
/// 12. contained + `seatbelt()`: `/bin/sh -c '/usr/bin/touch OUTSIDE'` → same as 11
///     (inheritance)
/// 13. observed + workspace + `unavailable()`: `touch` outside succeeds (control:
///     observed is not secretly sandboxed)
/// 14. contained + differing `RepositoryRoot`: write under the repo root but
///     outside the workspace is blocked
/// Missing `/usr/bin/sandbox-exec` must fail these tests — do not skip.
@Suite("SeatbeltContainment")
struct SeatbeltContainmentTests {
    @Test func seatbelt_touchInsideWorkspace_succeedsAndEstablishesContained() throws {
        let sandboxExec = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        #expect(FileManager.default.isExecutableFile(atPath: sandboxExec.path))

        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let inside = tree.workspaceURL.appendingPathComponent("inside.txt").path
        let result = apply(
            plan: tree.contained,
            command: IsolatedCommand(executable: "/usr/bin/touch", arguments: [inside]),
            backend: IsolationBackends.seatbelt()
        )
        switch result {
        case .success(let run):
            #expect(run.exitStatus == 0)
            #expect(FileManager.default.fileExists(atPath: inside))
            expectContainedSeatbelt(run.established, matching: tree.contained)
        case .failure(let error):
            recordUnexpectedContainmentError(error, expected: "in-workspace touch")
        }
    }

    @Test func seatbelt_touchOutsideWorkspace_isBlockedFileAbsent_stillEstablishedContained() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("outside.txt").path
        #expect(FileManager.default.fileExists(atPath: outside) == false)
        let result = apply(
            plan: tree.contained,
            command: IsolatedCommand(executable: "/usr/bin/touch", arguments: [outside]),
            backend: IsolationBackends.seatbelt()
        )
        switch result {
        case .success(let run):
            #expect(run.exitStatus != 0)
            #expect(FileManager.default.fileExists(atPath: outside) == false)
            expectContainedSeatbelt(run.established, matching: tree.contained)
        case .failure(let error):
            recordUnexpectedContainmentError(error, expected: "blocked outside touch with established contained")
        }
    }

    @Test func seatbelt_binShChild_cannotWriteOutsideWorkspace() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("child-outside.txt").path
        let result = apply(
            plan: tree.contained,
            command: IsolatedCommand(
                executable: "/bin/sh",
                arguments: ["-c", "/usr/bin/touch \(outside)"]
            ),
            backend: IsolationBackends.seatbelt()
        )
        switch result {
        case .success(let run):
            #expect(run.exitStatus != 0)
            #expect(FileManager.default.fileExists(atPath: outside) == false)
            expectContainedSeatbelt(run.established, matching: tree.contained)
        case .failure(let error):
            recordUnexpectedContainmentError(error, expected: "inherited write deny for /bin/sh child")
        }
    }

    @Test func observed_touchOutsideWorkspace_succeeds_notSecretlySandboxed() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("observed-outside.txt").path
        let result = apply(
            plan: tree.observed,
            command: IsolatedCommand(executable: "/usr/bin/touch", arguments: [outside]),
            backend: IsolationBackends.unavailable()
        )
        switch result {
        case .success(let run):
            #expect(run.exitStatus == 0)
            #expect(FileManager.default.fileExists(atPath: outside))
            switch run.established.mode {
            case .observed:
                break
            case .mediated:
                Issue.record("observed control must not establish mediated")
            case .contained:
                Issue.record("observed control must not establish contained")
            }
            switch run.established.family {
            case .none:
                break
            case .seatbelt:
                Issue.record("observed control must not use family seatbelt")
            }
        case .failure(let error):
            recordUnexpectedContainmentError(error, expected: "unsandboxed observed outside touch")
        }
    }

    @Test func seatbelt_writeUnderRepositoryRootOutsideWorkspace_isBlocked() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let leak = tree.repositoryURL.appendingPathComponent("leak.txt").path
        let result = apply(
            plan: tree.containedDifferingRoot,
            command: IsolatedCommand(executable: "/usr/bin/touch", arguments: [leak]),
            backend: IsolationBackends.seatbelt()
        )
        switch result {
        case .success(let run):
            #expect(run.exitStatus != 0)
            #expect(FileManager.default.fileExists(atPath: leak) == false)
            expectContainedSeatbelt(run.established, matching: tree.containedDifferingRoot)
        case .failure(let error):
            recordUnexpectedContainmentError(
                error,
                expected: "blocked write under repositoryRoot outside workspace"
            )
        }
    }
}

private struct ContainmentTree {
    let rootURL: URL
    let workspaceURL: URL
    let siblingURL: URL
    let repositoryURL: URL
    let contained: IsolationPlan
    let observed: IsolationPlan
    let containedDifferingRoot: IsolationPlan

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-seatbelt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repo", isDirectory: true)
        let workspace = repository.appendingPathComponent("ws", isDirectory: true)
        let sibling = root.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        rootURL = root.resolvingSymlinksInPath()
        workspaceURL = workspace.resolvingSymlinksInPath()
        siblingURL = sibling.resolvingSymlinksInPath()
        repositoryURL = repository.resolvingSymlinksInPath()

        let workspaceDir = try requireWorkspace(workspaceURL.path)
        let repoRoot = try requireRepositoryRoot(repositoryURL.path)
        contained = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspaceDir)
        )
        observed = try requirePlan(
            IsolationCompileRequest(requested: .observed, workspace: workspaceDir)
        )
        containedDifferingRoot = try requirePlan(
            IsolationCompileRequest(
                requested: .contained,
                workspace: workspaceDir,
                repositoryRoot: repoRoot
            )
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private func requireWorkspace(_ path: String) throws -> WorkingDirectory {
    try #require(WorkingDirectory(validating: path))
}

private func requireRepositoryRoot(_ path: String) throws -> RepositoryRoot {
    try #require(RepositoryRoot(validating: path))
}

private func requirePlan(_ request: IsolationCompileRequest) throws -> IsolationPlan {
    switch compileIsolationPlan(request) {
    case .success(let plan):
        return plan
    case .failure(let error):
        switch error {
        case .containedRequiresWorkspace:
            Issue.record("containment fixture compile must not fail containedRequiresWorkspace")
            throw error
        }
    }
}

private func apply(
    plan: IsolationPlan,
    command: IsolatedCommand,
    backend: IsolationBackend
) -> Result<IsolatedRunResult, IsolationApplyError> {
    switch backend.prepare(plan, command) {
    case .success(let request):
        return backend.run(request)
    case .failure(let error):
        return .failure(error)
    }
}

private func expectContainedSeatbelt(
    _ established: EstablishedIsolation,
    matching plan: IsolationPlan,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(established.mode == plan.mode, sourceLocation: sourceLocation)
    switch established.family {
    case .seatbelt:
        break
    case .none:
        Issue.record("Darwin contained establish must be family seatbelt", sourceLocation: sourceLocation)
    }
    switch established.mode {
    case .contained(let guarantees):
        switch guarantees.filesystem {
        case .writesLimited(let limitedTo):
            #expect(limitedTo == plan.workspace, sourceLocation: sourceLocation)
        case .unrestricted:
            Issue.record(
                "established contained must keep first-slice write limit",
                sourceLocation: sourceLocation
            )
        }
        switch guarantees.descent {
        case .inherited:
            break
        case .notInherited:
            Issue.record(
                "established contained must keep inherited descent",
                sourceLocation: sourceLocation
            )
        }
        switch guarantees.network {
        case .unrestricted:
            break
        }
    case .observed:
        Issue.record("Darwin contained establish must not be observed", sourceLocation: sourceLocation)
    case .mediated:
        Issue.record("Darwin contained establish must not be mediated", sourceLocation: sourceLocation)
    }
}

private func recordUnexpectedContainmentError(
    _ error: IsolationApplyError,
    expected: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch error {
    case .backendUnavailable:
        Issue.record("expected \(expected), got backendUnavailable", sourceLocation: sourceLocation)
    case .backendMismatch:
        Issue.record("expected \(expected), got backendMismatch", sourceLocation: sourceLocation)
    case .workspaceMustBeAbsolute:
        Issue.record("expected \(expected), got workspaceMustBeAbsolute", sourceLocation: sourceLocation)
    case .workspaceDoesNotExist:
        Issue.record("expected \(expected), got workspaceDoesNotExist", sourceLocation: sourceLocation)
    case .workspacePathUnresolvable:
        Issue.record(
            "expected \(expected), got workspacePathUnresolvable",
            sourceLocation: sourceLocation
        )
    case .workspacePathUnsafe:
        Issue.record("expected \(expected), got workspacePathUnsafe", sourceLocation: sourceLocation)
    case .containedGuaranteesUnsupported:
        Issue.record(
            "expected \(expected), got containedGuaranteesUnsupported",
            sourceLocation: sourceLocation
        )
    case .profileNotApplicable:
        Issue.record("expected \(expected), got profileNotApplicable", sourceLocation: sourceLocation)
    case .processSpawnFailed:
        Issue.record("expected \(expected), got processSpawnFailed", sourceLocation: sourceLocation)
    case .commandExecutableMustBeAbsolute:
        Issue.record(
            "expected \(expected), got commandExecutableMustBeAbsolute",
            sourceLocation: sourceLocation
        )
    }
}
#endif
