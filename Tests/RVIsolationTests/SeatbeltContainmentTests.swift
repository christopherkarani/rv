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
/// 13. observed + workspace + `IsolationBackends.apply`: `touch` outside succeeds
///     (control: the production door does not secretly sandbox observed)
/// 14. contained + differing `RepositoryRoot`: write under the repo root but
///     outside the workspace is blocked
/// Missing `/usr/bin/sandbox-exec` must fail these tests — do not skip.
@Suite("SeatbeltContainment")
struct SeatbeltContainmentTests {
    @Test func seatbelt_touchInsideWorkspace_succeedsAndEstablishesContained() async throws {
        let sandboxExec = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        #expect(FileManager.default.isExecutableFile(atPath: sandboxExec.path))

        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let inside = tree.workspaceURL.appendingPathComponent("inside.txt").path
        let result = await IsolationBackends.seatbelt().applyOffPool(
            tree.contained,
            command: IsolatedCommand(executable: "/usr/bin/touch", arguments: [inside])!
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

    @Test func seatbelt_touchOutsideWorkspace_isBlockedFileAbsent_stillEstablishedContained() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("outside.txt").path
        #expect(FileManager.default.fileExists(atPath: outside) == false)
        let result = await IsolationBackends.seatbelt().applyOffPool(
            tree.contained,
            command: IsolatedCommand(executable: "/usr/bin/touch", arguments: [outside])!
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

    @Test func seatbelt_binShChild_cannotWriteOutsideWorkspace() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("child-outside.txt").path
        let result = await IsolationBackends.seatbelt().applyOffPool(
            tree.contained,
            command: IsolatedCommand(
                executable: "/bin/sh",
                arguments: ["-c", "/usr/bin/touch \(outside)"]
            )!
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

    @Test func observed_touchOutsideWorkspace_succeeds_notSecretlySandboxed() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("observed-outside.txt").path
        let result = await IsolationBackends.applyOffPool(
            tree.observed,
            command: IsolatedCommand(executable: "/usr/bin/touch", arguments: [outside])!
        )
        switch result {
        case .success(let run):
            #expect(run.exitStatus == 0)
            #expect(FileManager.default.fileExists(atPath: outside))
            switch run.established {
            case .observed:
                #expect(run.session == nil)
            case .mediated:
                Issue.record("observed control must not establish mediated")
            case .seatbelt:
                Issue.record("observed control must not establish seatbelt")
            }
        case .failure(let error):
            recordUnexpectedContainmentError(error, expected: "unsandboxed observed outside touch")
        }
    }

    @Test func seatbelt_writeUnderRepositoryRootOutsideWorkspace_isBlocked() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let leak = tree.repositoryURL.appendingPathComponent("leak.txt").path
        let result = await IsolationBackends.seatbelt().applyOffPool(
            tree.containedDifferingRoot,
            command: IsolatedCommand(executable: "/usr/bin/touch", arguments: [leak])!
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

private func expectContainedSeatbelt(
    _ established: EstablishedIsolation,
    matching plan: IsolationPlan,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch established {
    case .seatbelt(let session):
        #expect(session.backend == .seatbelt, sourceLocation: sourceLocation)
    case .observed:
        Issue.record(
            "Darwin contained establish must be seatbelt, not observed",
            sourceLocation: sourceLocation
        )
    case .mediated:
        Issue.record(
            "Darwin contained establish must be seatbelt, not mediated",
            sourceLocation: sourceLocation
        )
    }
    switch plan.mode {
    case .contained(let guarantees):
        switch guarantees.filesystem {
        case .workspaceScoped(let limitedTo):
            #expect(limitedTo == plan.workspace, sourceLocation: sourceLocation)
        case .unrestricted:
            Issue.record(
                "established contained must keep workspace scope",
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
        case .denied:
            break
        case .unrestricted:
            Issue.record(
                "established contained must keep denied network",
                sourceLocation: sourceLocation
            )
        }
        switch guarantees.process {
        case .hostSignalsDenied:
            break
        case .unrestricted:
            Issue.record(
                "established contained must keep host signal denial",
                sourceLocation: sourceLocation
            )
        }
    case .observed:
        Issue.record("matching plan must be contained, not observed", sourceLocation: sourceLocation)
    case .mediated:
        Issue.record("matching plan must be contained, not mediated", sourceLocation: sourceLocation)
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
    case .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed:
        Issue.record("expected \(expected), got workspaceContainsInodeAlias", sourceLocation: sourceLocation)
    case .containedGuaranteesUnsupported:
        Issue.record(
            "expected \(expected), got containedGuaranteesUnsupported",
            sourceLocation: sourceLocation
        )
    case .profileNotApplicable:
        Issue.record("expected \(expected), got profileNotApplicable", sourceLocation: sourceLocation)
    case .processSpawnFailed:
        Issue.record("expected \(expected), got processSpawnFailed", sourceLocation: sourceLocation)
    case .commandContainsNUL:
        Issue.record("unexpected NUL command rejection")
    case .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
        Issue.record(
            "expected \(expected), got commandExecutableMustBeAbsolute",
            sourceLocation: sourceLocation
        )
    }
}
#endif
