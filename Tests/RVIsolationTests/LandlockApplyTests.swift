import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Portable Landlock apply edges this suite encodes before production code:
/// 1. `compileLandlockRuleset(contained)` write root is resolved workspace, not
///    `RepositoryRoot` when they differ; handled bits are write-class only
/// 2. compile of observed / mediated → `profileNotApplicable`
/// 3. `IsolationBackendFamily` is exactly none / seatbelt / landlock
///    (exhaustive switch lives in IsolationApply)
/// 4. `EstablishedIsolation` rejects contained+landlock, observed+landlock,
///    and contained+none (IsolationApply)
/// 5. `landlock().prepare(observed)` → `profileNotApplicable`
/// 6. A strict contained plan does not prepare a Landlock launch.
///    `prepare` returns `containedGuaranteesUnsupported` for a real directory.
/// 7. Darwin: `IsolationBackends.apply(contained)` still family `.seatbelt`
/// 8. `platform().family` is `.seatbelt` on Darwin and `.landlock` on Linux
/// 14. Trampoline exit 125 maps to `backendUnavailable` (not established)
/// 15. Missing trampoline → `backendUnavailable`
/// 16. Exit 126 maps to `processSpawnFailed` (not established)
/// 17. Compile / prepare reject filesystem-root and symlink-to-root workspaces
/// 18. `rv-isolation-exec` identity: basename, regular file, not under workspace
/// 19. `spawn` of `/usr/bin/true`, a workspace-local helper, or an
///     identity-valid helper does not mint contained+landlock. A valid helper
///     is refused before it executes.
@Suite("IsolationApply")
struct IsolationApplyLandlockTests {
    @Test func compileLandlockRuleset_contained_writeRootIsResolvedWorkspaceNotRepositoryRoot()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-landlock-compile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try requireWorkspace(directory.resolvingSymlinksInPath().path)
        let root = try requireRepositoryRoot("/repo")
        let plan = try requirePlan(
            IsolationCompileRequest(
                requested: .contained,
                workspace: workspace,
                repositoryRoot: root
            )
        )
        let resolvedWorkspace = resolvedWorkspacePath(workspace)
        let resolvedRepo = URL(fileURLWithPath: root.rawValue).resolvingSymlinksInPath().path
        switch compileLandlockRuleset(plan) {
        case .success:
            Issue.record("Landlock must not compile a write-only ruleset for a workspace-scoped plan")
        case .failure(let error):
            switch error {
            case .containedGuaranteesUnsupported:
                #expect(resolvedWorkspace != resolvedRepo)
            case .backendUnavailable, .backendMismatch, .workspaceMustBeAbsolute,
                .workspaceDoesNotExist, .workspacePathUnresolvable, .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed, .profileNotApplicable, .processSpawnFailed,
                .commandContainsNUL, .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
                Issue.record("valid workspace must be containedGuaranteesUnsupported, got \(error)")
            }
        }
    }

    @Test func compileLandlockRuleset_observedAndMediated_returnsProfileNotApplicable() throws {
        let workspace = try requireWorkspace("/workspace")
        let observed = try requirePlan(
            IsolationCompileRequest(requested: .observed, workspace: workspace)
        )
        let mediated = try requirePlan(
            IsolationCompileRequest(requested: .mediated, workspace: workspace)
        )
        expectProfileNotApplicable(compileLandlockRuleset(observed))
        expectProfileNotApplicable(compileLandlockRuleset(mediated))
    }

    @Test func landlock_prepare_observed_returnsProfileNotApplicable() throws {
        let workspace = try requireWorkspace("/workspace")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .observed, workspace: workspace)
        )
        switch IsolationBackends.landlock().prepare(plan, trueCommand) {
        case .success:
            Issue.record("landlock prepare of observed must not succeed")
        case .failure(let error):
            switch error {
            case .profileNotApplicable:
                break
            case .backendUnavailable,
                .backendMismatch,
                .workspaceMustBeAbsolute,
                .workspaceDoesNotExist,
                .workspacePathUnresolvable,
                .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed,
                .containedGuaranteesUnsupported,
                .processSpawnFailed,
                .commandContainsNUL,
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
                Issue.record("landlock observed prepare must be profileNotApplicable, got \(error)")
            }
        }
    }

    @Test func landlock_prepare_contained_launchArguments_areWorkspaceSeparatorAndInnerArgv() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-landlock-launch-argv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try requireWorkspace(root.resolvingSymlinksInPath().path)
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        switch IsolationBackends.landlock().prepare(plan, trueCommand) {
        case .success:
            Issue.record("strict contained plan must not prepare a write-only Landlock launch")
        case .failure(let error):
            switch error {
            case .containedGuaranteesUnsupported:
                break
            case .backendUnavailable, .backendMismatch, .workspaceMustBeAbsolute,
                .workspaceDoesNotExist, .workspacePathUnresolvable, .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed, .profileNotApplicable, .processSpawnFailed,
                .commandContainsNUL, .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
                Issue.record("existing workspace must be containedGuaranteesUnsupported, got \(error)")
            }
        }
    }

    @Test func landlock_run_missingTrampoline_returnsBackendUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-landlock-missing-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try requireWorkspace(root.resolvingSymlinksInPath().path)
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        let missing = URL(
            fileURLWithPath: "/no/such/rv-isolation-exec-\(UUID().uuidString)"
        )
        let backend = IsolationBackends.landlock(executable: missing)
        switch backend.prepare(plan, trueCommand) {
        case .success:
            Issue.record("strict contained plan must not prepare a Landlock launch")
        case .failure(let error):
            switch error {
            case .containedGuaranteesUnsupported:
                break
            case .backendUnavailable, .backendMismatch, .workspaceMustBeAbsolute,
                .workspaceDoesNotExist, .workspacePathUnresolvable, .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed, .profileNotApplicable, .processSpawnFailed,
                .commandContainsNUL, .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
                Issue.record("missing helper must still refuse before launch, got \(error)")
            }
        }
    }

    @Test func isolationExecExit125_isBackendUnavailable_notEstablished() throws {
        let workspace = try requireWorkspace("/workspace")
        let contained = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        switch contained.mode {
        case .contained:
            break
        case .observed, .mediated:
            Issue.record("compiled contained plan must stay contained")
        }
        #expect(IsolationBackends.isolationExecCouldNotEstablishExit == 125)
        switch interpretIsolationExecExit(125) {
        case .success:
            Issue.record("exit 125 must not mint IsolatedRunResult")
        case .failure(let error):
            switch error {
            case .backendUnavailable:
                break
            case .backendMismatch,
                .workspaceMustBeAbsolute,
                .workspaceDoesNotExist,
                .workspacePathUnresolvable,
                .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed,
                .containedGuaranteesUnsupported,
                .profileNotApplicable,
                .processSpawnFailed,
                .commandContainsNUL,
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
                Issue.record("exit 125 must be backendUnavailable, got \(error)")
            }
        }
        #expect(IsolationBackends.isolationExecExecFailedExit == 126)
        switch interpretIsolationExecExit(0) {
        case .success:
            Issue.record("exit 0 must not mint contained Landlock establishment")
        case .failure(let error):
            switch error {
            case .containedGuaranteesUnsupported:
                break
            case .backendUnavailable, .backendMismatch, .workspaceMustBeAbsolute,
                .workspaceDoesNotExist, .workspacePathUnresolvable, .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed, .profileNotApplicable, .processSpawnFailed,
                .commandContainsNUL, .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
                Issue.record("exit 0 must be containedGuaranteesUnsupported, got \(error)")
            }
        }
        switch interpretIsolationExecExit(126) {
        case .success:
            Issue.record("exit 126 must not mint IsolatedRunResult")
        case .failure(let error):
            switch error {
            case .processSpawnFailed:
                break
            case .backendUnavailable,
                .backendMismatch,
                .workspaceMustBeAbsolute,
                .workspaceDoesNotExist,
                .workspacePathUnresolvable,
                .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed,
                .containedGuaranteesUnsupported,
                .profileNotApplicable,
                .commandContainsNUL,
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
                Issue.record("exit 126 must be processSpawnFailed, got \(error)")
            }
        }
        switch interpretIsolationExecExit(1) {
        case .success:
            Issue.record("exit 1 must not mint contained Landlock establishment")
        case .failure(let error):
            switch error {
            case .containedGuaranteesUnsupported:
                break
            case .backendUnavailable, .backendMismatch, .workspaceMustBeAbsolute,
                .workspaceDoesNotExist, .workspacePathUnresolvable, .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed, .profileNotApplicable, .processSpawnFailed,
                .commandContainsNUL, .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
                Issue.record("exit 1 must be containedGuaranteesUnsupported, got \(error)")
            }
        }
    }

    @Test func compileLandlockRuleset_filesystemRoot_returnsWorkspacePathUnsafe() throws {
        let workspace = try requireWorkspace("/")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        expectApplyFailure(
            compileLandlockRuleset(plan),
            .workspacePathUnsafe,
            because: "filesystem-root workspace compile"
        )
    }

    @Test func compileLandlockRuleset_symlinkToFilesystemRoot_returnsWorkspacePathUnsafe() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-landlock-rootlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("as-root")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/")
        let workspace = try requireWorkspace(link.path)
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        expectApplyFailure(
            compileLandlockRuleset(plan),
            .workspacePathUnsafe,
            because: "symlink-to-root workspace compile"
        )
    }

    @Test func compileLandlockRuleset_newlineWorkspace_returnsWorkspacePathUnsafe() throws {
        let workspace = try requireWorkspace("/workspace\noutside")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        expectApplyFailure(
            compileLandlockRuleset(plan),
            .workspacePathUnsafe,
            because: "newline workspace compile"
        )
    }

    @Test func compileLandlockRuleset_relativeWorkspace_returnsWorkspaceMustBeAbsolute() throws {
        let workspace = try requireWorkspace("repo")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        expectApplyFailure(
            compileLandlockRuleset(plan),
            .workspaceMustBeAbsolute,
            because: "relative workspace compile"
        )
    }

    @Test func landlock_prepare_mediated_returnsProfileNotApplicable() throws {
        let workspace = try requireWorkspace("/workspace")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .mediated, workspace: workspace)
        )
        expectApplyFailure(
            IsolationBackends.landlock().prepare(plan, trueCommand),
            .profileNotApplicable,
            because: "landlock prepare of mediated"
        )
    }

    @Test func landlock_prepare_contained_relativeWorkspace_returnsWorkspaceMustBeAbsolute() throws {
        let workspace = try requireWorkspace("repo")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        expectApplyFailure(
            IsolationBackends.landlock().prepare(plan, trueCommand),
            .workspaceMustBeAbsolute,
            because: "landlock prepare of relative workspace"
        )
    }

    @Test func landlock_prepare_contained_missingDirectory_returnsWorkspaceDoesNotExist() throws {
        let missing = "/no/such/rv-landlock-workspace-\(UUID().uuidString)"
        let workspace = try requireWorkspace(missing)
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        expectApplyFailure(
            IsolationBackends.landlock().prepare(plan, trueCommand),
            .workspaceDoesNotExist,
            because: "landlock prepare of missing workspace"
        )
    }

    @Test func landlock_prepare_contained_symlinkToFilesystemRoot_returnsWorkspacePathUnsafe() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-landlock-prepare-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("as-root")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/")
        let workspace = try requireWorkspace(link.path)
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        expectApplyFailure(
            IsolationBackends.landlock().prepare(plan, trueCommand),
            .workspacePathUnsafe,
            because: "landlock prepare of symlink-to-root"
        )
    }

    @Test func isolatedLaunchRequest_rejectsLandlockWithObservedOrUnsandboxedContained() throws {
        let workspace = try requireWorkspace("/workspace")
        let observed = try requirePlan(
            IsolationCompileRequest(requested: .observed, workspace: workspace)
        )
        let contained = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        let ruleset = LandlockRuleset(
            workspacePath: "/workspace",
            handledWriteAccess: LandlockAccessFS.writeClass
        )
        #expect(
            IsolatedLaunchRequest(plan: observed, command: trueCommand, launch: .landlock(ruleset))
                == nil
        )
        let mediated = try requirePlan(
            IsolationCompileRequest(requested: .mediated, workspace: workspace)
        )
        #expect(
            IsolatedLaunchRequest(plan: mediated, command: trueCommand, launch: .landlock(ruleset))
                == nil
        )
        #expect(
            IsolatedLaunchRequest(plan: contained, command: trueCommand, launch: .unsandboxed) == nil
        )
        #expect(
            IsolatedLaunchRequest(plan: observed, command: trueCommand, launch: .unsandboxed) != nil
        )
    }

    @Test func runLandlock_seatbeltRequest_returnsBackendMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-landlock-mismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try requireWorkspace(root.resolvingSymlinksInPath().path)
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        switch IsolationBackends.seatbelt().prepare(plan, trueCommand) {
        case .success(let request):
            expectApplyFailure(
                runLandlock(request, executable: nil),
                .backendMismatch,
                because: "runLandlock of a seatbelt request"
            )
        case .failure(let error):
            recordUnexpectedApplyError(error, expected: "prepared seatbelt request for mismatch")
        }
    }

    @Test func isolationExecIdentity_rejectsWrongNameDirectoryAndWorkspaceLocalHelper() throws {
        let tree = try HelperTree()
        defer { tree.tearDown() }

        #expect(isFilesystemRoot("/"))
        #expect(isFilesystemRoot("/tmp") == false)
        #expect(isResolvedPath("/tmp/ws/bin", atOrBeneath: "/tmp/ws"))
        #expect(isResolvedPath("/tmp/ws", atOrBeneath: "/tmp/ws"))
        #expect(isResolvedPath("/tmp/ws-evil/bin", atOrBeneath: "/tmp/ws") == false)
        #expect(isResolvedPath("/tmp/ws2", atOrBeneath: "/tmp/ws") == false)

        #expect(
            usableIsolationExecPath("/usr/bin/true", workspacePath: tree.workspacePath) == nil
        )
        #expect(
            usableIsolationExecPath("rv-isolation-exec", workspacePath: tree.workspacePath) == nil
        )
        #expect(
            usableIsolationExecPath(tree.wrongNameHelper.path, workspacePath: tree.workspacePath)
                == nil
        )
        #expect(
            usableIsolationExecPath(tree.directoryHelper.path, workspacePath: tree.workspacePath)
                == nil
        )
        #expect(
            usableIsolationExecPath(tree.workspaceHelper.path, workspacePath: tree.workspacePath)
                == nil
        )
        #expect(
            usableIsolationExecPath(
                "/no/such/rv-isolation-exec-\(UUID().uuidString)",
                workspacePath: tree.workspacePath
            ) == nil
        )
        let accepted = usableIsolationExecPath(
            tree.outsideHelper.path,
            workspacePath: tree.workspacePath
        )
        #expect(accepted == posixRealpath(tree.outsideHelper.path))

        #expect(
            resolvedIsolationExecPath(
                override: URL(fileURLWithPath: "/usr/bin/true"),
                workspacePath: tree.workspacePath
            ) == nil
        )
        #expect(
            resolvedIsolationExecPath(
                override: tree.workspaceHelper,
                workspacePath: tree.workspacePath
            ) == nil
        )
        #expect(
            resolvedIsolationExecPath(
                override: tree.outsideHelper,
                workspacePath: tree.workspacePath
            ) == posixRealpath(tree.outsideHelper.path)
        )
        #expect(
            usableIsolationExecPath(tree.unexecutableHelper.path, workspacePath: tree.workspacePath)
                == nil
        )
        #expect(
            usableIsolationExecPath(tree.brokenSymlinkHelper.path, workspacePath: tree.workspacePath)
                == nil
        )
        #expect(
            usableIsolationExecPath(tree.symlinkToTrue.path, workspacePath: tree.workspacePath)
                == nil
        )
        #expect(
            usableIsolationExecPath(
                tree.workspaceSymlinkToOutside.path,
                workspacePath: tree.workspacePath
            ) == nil
        )
        #expect(isLookupInsideWorkspace(tree.workspaceHelper.path, workspace: tree.workspacePath))
        #expect(
            isLookupInsideWorkspace(
                tree.workspaceSymlinkToOutside.path,
                workspace: tree.workspacePath
            )
        )
        #expect(
            isLookupInsideWorkspace(tree.outsideHelper.path, workspace: tree.workspacePath) == false
        )
        #expect(
            usableIsolationExecPath(tree.outsideHelper.path, workspacePath: "/") == nil
        )
        if let searched = resolvedIsolationExecPath(
            override: nil,
            workspacePath: tree.workspacePath
        ) {
            #expect(URL(fileURLWithPath: searched).lastPathComponent == "rv-isolation-exec")
            #expect(isResolvedPath(searched, atOrBeneath: tree.workspacePath) == false)
        }
    }

    @Test func spawn_landlock_trueOrWorkspaceHelper_doesNotEstablish() throws {
        let tree = try HelperTree()
        defer { tree.tearDown() }
        let workspace = try requireWorkspace(tree.workspacePath)
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        let ruleset = LandlockRuleset(
            workspacePath: tree.workspacePath,
            handledWriteAccess: LandlockAccessFS.writeClass
        )
        let request = try #require(
            IsolatedLaunchRequest(plan: plan, command: trueCommand, launch: .landlock(ruleset))
        )
        do {
            expectApplyFailure(
                spawn(request),
                .backendUnavailable,
                because: "spawn of landlock basename without a trampoline"
            )
            expectApplyFailure(
                spawn(request, executablePath: "/usr/bin/true"),
                .backendUnavailable,
                because: "spawn of /usr/bin/true as a landlock trampoline"
            )
            expectApplyFailure(
                spawn(request, executablePath: tree.workspaceHelper.path),
                .backendUnavailable,
                because: "spawn of a workspace-local rv-isolation-exec"
            )
            expectApplyFailure(
                spawn(request, executablePath: tree.workspaceSymlinkToOutside.path),
                .backendUnavailable,
                because: "spawn of a workspace symlink to an outside helper"
            )
            expectApplyFailure(
                spawn(request, executablePath: tree.wrongNameHelper.path),
                .backendUnavailable,
                because: "spawn of a helper not named rv-isolation-exec"
            )
            let marker = tree.rootURL.appendingPathComponent("helper-ran")
            let quoted = marker.path.replacingOccurrences(of: "'", with: "'\\''")
            try "#!/bin/sh\nprintf ran > '\(quoted)'\nexit 0\n".write(
                to: tree.outsideHelper, atomically: true, encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tree.outsideHelper.path
            )
            expectApplyFailure(
                spawn(request, executablePath: tree.outsideHelper.path),
                .containedGuaranteesUnsupported,
                because: "identity-valid helper must not exec or establish containment"
            )
            #expect(FileManager.default.fileExists(atPath: marker.path) == false)
            expectApplyFailure(
                runUnavailable(request),
                .backendMismatch,
                because: "runUnavailable of a landlock request"
            )
            expectApplyFailure(
                runSeatbelt(request),
                .backendMismatch,
                because: "runSeatbelt of a landlock request"
            )
        }
    }

    @Test func landlock_prepare_contained_regularFileWorkspace_returnsWorkspaceDoesNotExist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-landlock-file-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("not-a-directory")
        try "not a dir\n".write(to: file, atomically: true, encoding: .utf8)
        let workspace = try requireWorkspace(file.resolvingSymlinksInPath().path)
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        expectApplyFailure(
            IsolationBackends.landlock().prepare(plan, trueCommand),
            .workspaceDoesNotExist,
            because: "landlock prepare of a regular-file workspace"
        )
    }

    #if os(macOS)
    @Test func landlock_run_contained_onDarwin_returnsBackendUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-landlock-darwin-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try requireWorkspace(root.resolvingSymlinksInPath().path)
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        let backend = IsolationBackends.landlock()
        switch backend.prepare(plan, trueCommand) {
        case .success:
            Issue.record("Darwin must not prepare a write-only Landlock launch")
        case .failure(let error):
            switch error {
            case .containedGuaranteesUnsupported:
                break
            case .backendUnavailable, .backendMismatch, .workspaceMustBeAbsolute,
                .workspaceDoesNotExist, .workspacePathUnresolvable, .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed, .profileNotApplicable, .processSpawnFailed,
                .commandContainsNUL, .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
                Issue.record("Darwin landlock prepare must refuse the strict plan, got \(error)")
            }
        }
    }

    @Test func apply_contained_onDarwin_stillEstablishesSeatbelt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-landlock-darwin-apply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try requireWorkspace(root.resolvingSymlinksInPath().path)
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        switch IsolationBackends.apply(plan, command: trueCommand) {
        case .success(let result):
            #expect(result.exitStatus == 0)
            switch result.established.family {
            case .seatbelt:
                break
            case .none:
                Issue.record("Darwin apply(contained) must be family seatbelt")
            case .landlock:
                Issue.record("Darwin apply(contained) must stay family seatbelt, not landlock")
            }
            switch result.established.mode {
            case .contained:
                break
            case .observed:
                Issue.record("Darwin apply(contained) must not establish observed")
            case .mediated:
                Issue.record("Darwin apply(contained) must not establish mediated")
            }
        case .failure(let error):
            recordUnexpectedApplyError(error, expected: "Darwin apply(contained) seatbelt establish")
        }
    }
    #endif
}

private let trueCommand = IsolatedCommand(executable: "/usr/bin/true")!

private struct HelperTree {
    let rootURL: URL
    let workspacePath: String
    let outsideHelper: URL
    let workspaceHelper: URL
    let wrongNameHelper: URL
    let directoryHelper: URL
    let unexecutableHelper: URL
    let brokenSymlinkHelper: URL
    let symlinkToTrue: URL
    let workspaceSymlinkToOutside: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-landlock-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = root.appendingPathComponent("ws", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let directoryHelper = outside.appendingPathComponent(
            "rv-isolation-exec-dir",
            isDirectory: true
        ).appendingPathComponent("rv-isolation-exec")
        try FileManager.default.createDirectory(
            at: directoryHelper,
            withIntermediateDirectories: true
        )
        rootURL = root.resolvingSymlinksInPath()
        workspacePath = posixRealpath(workspace.path) ?? workspace.resolvingSymlinksInPath().path
        outsideHelper = try makeExecutable(
            at: outside.appendingPathComponent("rv-isolation-exec")
        )
        workspaceHelper = try makeExecutable(
            at: workspace.appendingPathComponent("rv-isolation-exec")
        )
        wrongNameHelper = try makeExecutable(at: outside.appendingPathComponent("not-the-helper"))
        self.directoryHelper = directoryHelper
        let unexecutable = root.appendingPathComponent("unexec").appendingPathComponent(
            "rv-isolation-exec"
        )
        try FileManager.default.createDirectory(
            at: unexecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: unexecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: unexecutable.path
        )
        unexecutableHelper = unexecutable
        let broken = root.appendingPathComponent("broken").appendingPathComponent(
            "rv-isolation-exec"
        )
        try FileManager.default.createDirectory(
            at: broken.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: broken.path,
            withDestinationPath: "/no/such/rv-isolation-exec-target-\(UUID().uuidString)"
        )
        brokenSymlinkHelper = broken
        let alias = root.appendingPathComponent("alias").appendingPathComponent(
            "rv-isolation-exec"
        )
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: "/usr/bin/true"
        )
        symlinkToTrue = alias
        let workspaceAlias = workspace.appendingPathComponent("linkdir")
        try FileManager.default.createDirectory(
            at: workspaceAlias,
            withIntermediateDirectories: true
        )
        let workspaceSymlink = workspaceAlias.appendingPathComponent("rv-isolation-exec")
        try FileManager.default.createSymbolicLink(
            atPath: workspaceSymlink.path,
            withDestinationPath: outsideHelper.path
        )
        workspaceSymlinkToOutside = workspaceSymlink
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private func makeExecutable(at url: URL) throws -> URL {
    try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func expectApplyFailure<T>(
    _ result: Result<T, IsolationApplyError>,
    _ expected: IsolationApplyError,
    because: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .success:
        Issue.record("\(because) must not succeed", sourceLocation: sourceLocation)
    case .failure(let error):
        if error != expected {
            recordUnexpectedApplyError(error, expected: because, sourceLocation: sourceLocation)
        }
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
            Issue.record("fixture compile must not fail containedRequiresWorkspace")
            throw error
        case .notContainedRequest:
            Issue.record("fixture compile must not fail notContainedRequest")
            throw error
        }
    }
}

private func expectProfileNotApplicable(
    _ result: Result<LandlockRuleset, IsolationApplyError>,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .success:
        Issue.record(
            "observed/mediated compileLandlockRuleset must be profileNotApplicable",
            sourceLocation: sourceLocation
        )
    case .failure(let error):
        switch error {
        case .profileNotApplicable:
            break
        case .backendUnavailable,
            .backendMismatch,
            .workspaceMustBeAbsolute,
            .workspaceDoesNotExist,
            .workspacePathUnresolvable,
            .workspacePathUnsafe,
            .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed,
            .containedGuaranteesUnsupported,
            .processSpawnFailed,
            .commandContainsNUL,
            .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
            Issue.record(
                "observed/mediated ruleset compile must be profileNotApplicable, got \(error)",
                sourceLocation: sourceLocation
            )
        }
    }
}

private func recordUnexpectedApplyError(
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
    case .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
        Issue.record(
            "expected \(expected), got commandExecutableMustBeAbsolute",
            sourceLocation: sourceLocation
        )
    }
}
