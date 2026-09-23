import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Isolation apply edges this suite encodes before production code:
/// 1. `compileSeatbeltProfile` on a compiled contained `/workspace` plan contains
///    `(version 1)`, `(deny default)`, workspace `file-write*`, and `subpath`
///    with the resolved workspace; does not contain `(allow default)` or an
///    `(allow network` rule
/// 2. contained workspace `/ws` + `RepositoryRoot` `/repo` → profile subpath is
///    `/ws` (resolved), not `/repo`
/// 3. `compileSeatbeltProfile` on observed (and mediated) → `profileNotApplicable`
/// 4. `unavailable().prepare(contained)` → `backendUnavailable` (not observed)
/// 5. `unavailable().prepare(observed)` then `run` → established `.observed`
///    with no session, and no `sandbox-exec` in the argv
/// 6. `unavailable().prepare(mediated)` then `run` → established `.mediated`
///    with no session
/// 7. contained + relative workspace (`"repo"`) → `workspaceMustBeAbsolute`
/// 8. contained + absolute workspace that does not exist → `workspaceDoesNotExist`
/// 9. Successful establishment is `.observed`, `.mediated`, or `.seatbelt`.
///    Landlock is not an `IsolatedRunResult`
/// 10. apply / prepare / run do not call `AgentAuthorization.decide` (no Domain
///     coupling; comment + verification `rg` only)
/// 11. `platform()` family is `.seatbelt` on Darwin and `.landlock` on Linux
/// 15. Darwin `platform().family == .seatbelt`; Linux `platform().family == .landlock`
/// 16. `IsolatedCommand` rejects empty / relative executables
/// 17. `IsolationBackends.apply` establishes observed / mediated without the
///     caller picking `unavailable()`
/// 18. `IsolationBackends.apply` of contained without a usable backend/workspace
///     fails closed
/// 19. `seatbelt().prepare(observed)` is `profileNotApplicable`
/// 20. newline workspace compile is `workspacePathUnsafe`
/// 21. Seatbelt `launchArguments` are `-p` + profile + inner argv
@Suite("IsolationApply")
struct IsolationApplyTests {
    @Test func compileSeatbeltProfile_contained_isDenyDefaultWorkspaceScope()
        throws
    {
        let workspace = try requireWorkspace("/workspace")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        let resolved = resolvedWorkspacePath(workspace)
        switch compileSeatbeltProfile(plan) {
        case .success(let profile):
            #expect(profile.source.contains("(version 1)"))
            #expect(profile.source.contains("(deny default)"))
            #expect(profile.source.contains("(allow default)") == false)
            #expect(profile.source.contains("(allow network") == false)
            #expect(profile.source.contains("file-write*"))
            #expect(profile.source.contains("(allow signal (target same-sandbox))"))
            #expect(profile.source.contains("(allow signal (target self))") == false)
            #expect(profile.source.contains("(deny file-link)"))
            #expect(profile.source.contains("(deny file-clone)"))
            #expect(profile.source.contains("(deny syscall-unix (syscall-number 82))"))
            #expect(profile.source.contains("(deny syscall-unix (syscall-number 147))"))
            #expect(profile.source.contains("(deny syscall-unix (syscall-number 244))"))
            #expect(profile.source.contains("subpath \"\(escapeSBPL(resolved))\""))
            let again = try #require(try? compileSeatbeltProfile(plan).get())
            #expect(profile.source == again.source)
        case .failure(let error):
            recordUnexpectedApplyError(error, expected: "compiled first-slice Seatbelt profile")
        }
    }

    #if os(macOS)
    @Test func workspacePublishDecision_rejectsForeignInodeAndLinkCountChange() {
        let original = WorkspaceInodeStamp(device: 1, inode: 10, linkCount: 1, kind: .regular)
        var extraLink = original
        extraLink.linkCount = 2
        let outside = WorkspaceInodeStamp(device: 1, inode: 99, linkCount: 2, kind: .regular)
        #expect(workspacePublishDecision(snapshot: original, saved: original, onVolume: true) == .update)
        #expect(workspacePublishDecision(snapshot: original, saved: extraLink, onVolume: true) == .reject)
        #expect(workspacePublishDecision(snapshot: original, saved: outside, onVolume: true) == .reject)
        #expect(workspacePublishDecision(snapshot: nil, saved: nil, onVolume: true) == .create)
        #expect(workspacePublishDecision(snapshot: nil, saved: outside, onVolume: true) == .reject)
        #expect(workspacePublishDecision(snapshot: original, saved: original, onVolume: false) == .remove)
        #expect(workspacePublishDecision(snapshot: original, saved: outside, onVolume: false) == .reject)
        #expect(workspacePublishDecision(snapshot: nil, saved: outside, onVolume: false) == .leave)
        let directory = WorkspaceInodeStamp(device: 1, inode: 4, linkCount: 3, kind: .directory)
        var directoryAfterChild = directory
        directoryAfterChild.linkCount = 4
        #expect(
            workspacePublishDecision(snapshot: directory, saved: directoryAfterChild, onVolume: true)
                == .update
        )
        #expect(
            workspacePublishDecision(snapshot: directory, saved: directoryAfterChild, onVolume: false)
                == .remove
        )
        var replacedDirectory = directory
        replacedDirectory.inode = 5
        #expect(
            workspacePublishDecision(snapshot: directory, saved: replacedDirectory, onVolume: true)
                == .reject
        )
        let link = WorkspaceInodeStamp(device: 1, inode: 8, linkCount: 1, kind: .symlink)
        var linkedTwice = link
        linkedTwice.linkCount = 2
        #expect(workspacePublishDecision(snapshot: link, saved: linkedTwice, onVolume: true) == .reject)
    }

    @Test func containedLaunchResult_reportsTeardownFailure() throws {
        let success = Result<IsolatedRunResult, IsolationApplyError>.success(
            IsolatedRunResult(established: .observed, exitStatus: 0)
        )
        let childFailure = Result<IsolatedRunResult, IsolationApplyError>.failure(.processSpawnFailed)
        let restored = Result<Void, IsolationApplyError>.success(())
        let restoreFailure = Result<Void, IsolationApplyError>.failure(.workspaceInodeBoundaryFailed)
        #expect(containedLaunchResult(child: success, teardown: restored) == success)
        #expect(containedLaunchResult(child: childFailure, teardown: restored) == childFailure)
        #expect(
            containedLaunchResult(child: success, teardown: restoreFailure)
                == .failure(.workspaceInodeBoundaryFailed)
        )
        #expect(
            containedLaunchResult(child: childFailure, teardown: restoreFailure)
                == .failure(.workspaceInodeBoundaryFailed)
        )
    }
    #endif

    @Test func compileSeatbeltProfile_contained_writeLimitIsWorkspaceNotRepositoryRoot() throws {
        let workspace = try requireWorkspace("/ws")
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
        switch compileSeatbeltProfile(plan) {
        case .success(let profile):
            #expect(profile.source.contains("subpath \"\(escapeSBPL(resolvedWorkspace))\""))
            #expect(profile.source.contains("subpath \"\(escapeSBPL(resolvedRepo))\"") == false)
            #expect(profile.source.contains("/repo") == false)
        case .failure(let error):
            recordUnexpectedApplyError(error, expected: "profile subpath of workspace /ws")
        }
    }

    @Test func compileSeatbeltProfile_observedAndMediated_returnsProfileNotApplicable() throws {
        let workspace = try requireWorkspace("/workspace")
        let observed = try requirePlan(
            IsolationCompileRequest(requested: .observed, workspace: workspace)
        )
        let mediated = try requirePlan(
            IsolationCompileRequest(requested: .mediated, workspace: workspace)
        )
        expectProfileNotApplicable(compileSeatbeltProfile(observed))
        expectProfileNotApplicable(compileSeatbeltProfile(mediated))
    }

    @Test func unavailable_prepare_contained_returnsBackendUnavailable() throws {
        let workspace = try requireWorkspace("/workspace")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        let result = IsolationBackends.unavailable().prepare(plan, trueCommand)
        switch result {
        case .success(let request):
            switch request.plan.mode {
            case .observed:
                Issue.record("unavailable contained prepare must not succeed as observed")
            case .mediated:
                Issue.record("unavailable contained prepare must not succeed as mediated")
            case .contained:
                Issue.record("unavailable contained prepare must not return a contained request")
            }
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
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
                Issue.record("unavailable contained prepare must be backendUnavailable, got \(error)")
            }
        }
    }

    @Test func unavailable_prepareAndRun_observed_establishesObservedFamilyNone_withoutSandboxExec()
        throws
    {
        let workspace = try requireWorkspace("/workspace")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .observed, workspace: workspace)
        )
        let backend = IsolationBackends.unavailable()
        switch backend.prepare(plan, trueCommand) {
        case .success(let request):
            #expect(request.family == .none)
            #expect(request.seatbeltProfile == nil)
            #expect(request.launchExecutable == trueCommand.executable)
            #expect(request.launchExecutable.contains("sandbox-exec") == false)
            switch request.plan.mode {
            case .observed:
                break
            case .mediated:
                Issue.record("observed prepare must not be mediated")
            case .contained:
                Issue.record("observed prepare must not be contained")
            }
            switch backend.run(request) {
            case .success(let result):
                #expect(result.established == .observed)
                #expect(result.session == nil)
                #expect(result.exitStatus == 0)
            case .failure(let error):
                recordUnexpectedApplyError(error, expected: "established observed run")
            }
        case .failure(let error):
            recordUnexpectedApplyError(error, expected: "prepared observed request")
        }
    }

    @Test func unavailable_prepareAndRun_mediated_establishesMediatedFamilyNone() throws {
        let workspace = try requireWorkspace("/workspace")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .mediated, workspace: workspace)
        )
        let backend = IsolationBackends.unavailable()
        switch backend.prepare(plan, trueCommand) {
        case .success(let request):
            #expect(request.family == .none)
            #expect(request.seatbeltProfile == nil)
            #expect(request.launchExecutable.contains("sandbox-exec") == false)
            switch request.plan.mode {
            case .mediated:
                break
            case .observed:
                Issue.record("mediated prepare must not be observed")
            case .contained:
                Issue.record("mediated prepare must not be contained")
            }
            switch backend.run(request) {
            case .success(let result):
                #expect(result.established == .mediated)
                #expect(result.session == nil)
                #expect(result.exitStatus == 0)
            case .failure(let error):
                recordUnexpectedApplyError(error, expected: "established mediated run")
            }
        case .failure(let error):
            recordUnexpectedApplyError(error, expected: "prepared mediated request")
        }
    }

    @Test func seatbelt_prepare_contained_relativeWorkspace_returnsWorkspaceMustBeAbsolute() throws {
        let workspace = try requireWorkspace("repo")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        let result = IsolationBackends.seatbelt().prepare(plan, trueCommand)
        switch result {
        case .success:
            Issue.record("relative contained workspace must not prepare")
        case .failure(let error):
            switch error {
            case .workspaceMustBeAbsolute:
                break
            case .backendUnavailable,
                .backendMismatch,
                .workspaceDoesNotExist,
                .workspacePathUnresolvable,
                .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed,
                .containedGuaranteesUnsupported,
                .profileNotApplicable,
                .processSpawnFailed,
                .commandContainsNUL,
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
                Issue.record("relative workspace must be workspaceMustBeAbsolute, got \(error)")
            }
        }
    }

    @Test func seatbelt_prepare_contained_missingDirectory_returnsWorkspaceDoesNotExist() throws {
        let missing = "/no/such/rv-isolation-workspace-\(UUID().uuidString)"
        let workspace = try requireWorkspace(missing)
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        let result = IsolationBackends.seatbelt().prepare(plan, trueCommand)
        switch result {
        case .success:
            Issue.record("missing contained workspace must not prepare")
        case .failure(let error):
            switch error {
            case .workspaceDoesNotExist:
                break
            case .backendUnavailable,
                .backendMismatch,
                .workspaceMustBeAbsolute,
                .workspacePathUnresolvable,
                .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed,
                .containedGuaranteesUnsupported,
                .profileNotApplicable,
                .processSpawnFailed,
                .commandContainsNUL,
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
                Issue.record("missing directory must be workspaceDoesNotExist, got \(error)")
            }
        }
    }

    @Test func isolationBackendFamily_hasExactlyNoneSeatbeltAndLandlock() {
        let families: [IsolationBackendFamily] = [.none, .seatbelt, .landlock]
        for family in families {
            switch family {
            case .none:
                break
            case .seatbelt:
                break
            case .landlock:
                break
            }
        }
    }

    @Test func isolatedCommand_rejectsEmptyAndRelativeExecutable() {
        #expect(IsolatedCommand(executable: "") == nil)
        #expect(IsolatedCommand(executable: "touch") == nil)
        #expect(IsolatedCommand(executable: "/usr/bin/true") != nil)
        switch IsolatedCommand.make(executable: "/usr/bin/true") {
        case .success(let command):
            #expect(command.executable == "/usr/bin/true")
        case .failure(let error):
            recordUnexpectedApplyError(error, expected: "absolute IsolatedCommand.make")
        }
        switch IsolatedCommand.make(executable: "touch") {
        case .success:
            Issue.record("relative IsolatedCommand.make must fail")
        case .failure(let error):
            switch error {
            case .commandContainsNUL:
                Issue.record("unexpected NUL command rejection")
            case .commandExecutableMustBeAbsolute:
                break
            case .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
                Issue.record("relative command must be commandExecutableMustBeAbsolute, got \(error)")
            case .backendUnavailable,
                .backendMismatch,
                .workspaceMustBeAbsolute,
                .workspaceDoesNotExist,
                .workspacePathUnresolvable,
                .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed,
                .containedGuaranteesUnsupported,
                .profileNotApplicable,
                .processSpawnFailed:
                Issue.record("relative command must be commandExecutableMustBeAbsolute, got \(error)")
            }
        }
    }

    @Test func apply_observedAndMediated_doNotRequireCallerToPickUnavailable() throws {
        let workspace = try requireWorkspace("/workspace")
        let observed = try requirePlan(
            IsolationCompileRequest(requested: .observed, workspace: workspace)
        )
        let mediated = try requirePlan(
            IsolationCompileRequest(requested: .mediated, workspace: workspace)
        )
        switch IsolationBackends.apply(observed, command: trueCommand) {
        case .success(let result):
            #expect(result.established == .observed)
            #expect(result.session == nil)
            #expect(result.exitStatus == 0)
        case .failure(let error):
            recordUnexpectedApplyError(error, expected: "apply observed without picking a factory")
        }
        switch IsolationBackends.apply(mediated, command: trueCommand) {
        case .success(let result):
            #expect(result.established == .mediated)
            #expect(result.session == nil)
            #expect(result.exitStatus == 0)
        case .failure(let error):
            recordUnexpectedApplyError(error, expected: "apply mediated without picking a factory")
        }
    }

    @Test func apply_contained_withoutUsableWorkspaceOrBackend_failsClosed() throws {
        let missing = "/no/such/rv-isolation-apply-\(UUID().uuidString)"
        let workspace = try requireWorkspace(missing)
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        switch IsolationBackends.apply(plan, command: trueCommand) {
        case .success:
            Issue.record("contained apply without a usable workspace/backend must fail closed")
        case .failure(let error):
            #if os(macOS)
            switch error {
            case .workspaceDoesNotExist:
                break
            case .backendUnavailable,
                .backendMismatch,
                .workspaceMustBeAbsolute,
                .workspacePathUnresolvable,
                .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed,
                .containedGuaranteesUnsupported,
                .profileNotApplicable,
                .processSpawnFailed,
                .commandContainsNUL,
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
                Issue.record(
                    "Darwin contained apply of a missing workspace must be workspaceDoesNotExist, got \(error)"
                )
            }
            #elseif os(Linux)
            switch error {
            case .workspaceDoesNotExist:
                break
            case .backendUnavailable,
                .backendMismatch,
                .workspaceMustBeAbsolute,
                .workspacePathUnresolvable,
                .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed,
                .containedGuaranteesUnsupported,
                .profileNotApplicable,
                .processSpawnFailed,
                .commandContainsNUL,
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
                Issue.record(
                    "Linux contained apply of a missing workspace must be workspaceDoesNotExist, got \(error)"
                )
            }
            #else
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
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
                Issue.record(
                    "non-Darwin contained apply must be backendUnavailable, got \(error)"
                )
            }
            #endif
        }
    }

    @Test func seatbelt_prepare_observed_returnsProfileNotApplicable() throws {
        let workspace = try requireWorkspace("/workspace")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .observed, workspace: workspace)
        )
        switch IsolationBackends.seatbelt().prepare(plan, trueCommand) {
        case .success:
            Issue.record("seatbelt prepare of observed must not succeed")
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
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
                Issue.record("seatbelt observed prepare must be profileNotApplicable, got \(error)")
            }
        }
    }

    @Test func compileSeatbeltProfile_filesystemRoot_returnsWorkspacePathUnsafe() throws {
        let workspace = try requireWorkspace("/")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        switch compileSeatbeltProfile(plan) {
        case .success:
            Issue.record("filesystem-root workspace must not compile a Seatbelt profile")
        case .failure(let error):
            switch error {
            case .workspacePathUnsafe:
                break
            case .backendUnavailable,
                .backendMismatch,
                .workspaceMustBeAbsolute,
                .workspaceDoesNotExist,
                .workspacePathUnresolvable,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed,
                .containedGuaranteesUnsupported,
                .profileNotApplicable,
                .processSpawnFailed,
                .commandContainsNUL,
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
                Issue.record("filesystem-root workspace must be workspacePathUnsafe, got \(error)")
            }
        }
    }

    @Test func compileSeatbeltProfile_newlineWorkspace_returnsWorkspacePathUnsafe() throws {
        let workspace = try requireWorkspace("/workspace\noutside")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        switch compileSeatbeltProfile(plan) {
        case .success:
            Issue.record("newline workspace must not compile a Seatbelt profile")
        case .failure(let error):
            switch error {
            case .workspacePathUnsafe:
                break
            case .backendUnavailable,
                .backendMismatch,
                .workspaceMustBeAbsolute,
                .workspaceDoesNotExist,
                .workspacePathUnresolvable,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed,
                .containedGuaranteesUnsupported,
                .profileNotApplicable,
                .processSpawnFailed,
                .commandContainsNUL,
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
                Issue.record("newline workspace must be workspacePathUnsafe, got \(error)")
            }
        }
    }

    @Test func rejectWorkspaceInodeAlias_unreadableDirectory_refusesHiddenAlias() throws {
        let tree = try ContainmentTree()
        let blocked = tree.workspaceURL.appendingPathComponent("blocked", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: blocked.path
            )
            tree.tearDown()
        }
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        let outside = tree.siblingURL.appendingPathComponent("source")
        try Data("original".utf8).write(to: outside)
        try FileManager.default.linkItem(at: outside, to: blocked.appendingPathComponent("alias"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        let root = try #require(posixRealpath(tree.workspaceURL.path))
        switch rejectWorkspaceInodeAlias(root) {
        case .failure(.workspaceContainsInodeAlias):
            break
        case .success:
            Issue.record("an unreadable directory must refuse the alias scan")
        case .failure(let error):
            Issue.record("expected workspaceContainsInodeAlias, got \(error)")
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "original")
    }

    @Test func seatbelt_prepare_launchArguments_areSandboxExecProfileAndInnerArgv() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-isolation-launch-argv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try requireWorkspace(root.resolvingSymlinksInPath().path)
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        switch IsolationBackends.seatbelt().prepare(plan, trueCommand) {
        case .success(let request):
            #expect(request.launchExecutable == IsolationBackends.sandboxExecPath)
            #expect(request.launchExecutable.contains("sandbox-exec"))
            guard let profile = request.seatbeltProfile else {
                Issue.record("seatbelt prepare must attach a profile")
                return
            }
            #expect(request.launchArguments == ["-p", profile.source, trueCommand.executable])
        case .failure(let error):
            recordUnexpectedApplyError(error, expected: "prepared seatbelt launch argv")
        }
    }

    @Test func platform_family_isSeatbeltOnDarwin_landlockOnLinux() throws {
        let backend = IsolationBackends.platform()
        #if os(macOS)
        switch backend.family {
        case .seatbelt:
            break
        case .none:
            Issue.record("Darwin platform() must be family seatbelt")
        case .landlock:
            Issue.record("Darwin platform() must be family seatbelt, not landlock")
        }
        #elseif os(Linux)
        switch backend.family {
        case .landlock:
            break
        case .none:
            Issue.record("Linux platform() must be family landlock")
        case .seatbelt:
            Issue.record("Linux platform() must be family landlock, not seatbelt")
        }
        #else
        switch backend.family {
        case .none:
            break
        case .seatbelt:
            Issue.record("unknown platform() must be family none")
        case .landlock:
            Issue.record("unknown platform() must be family none, not landlock")
        }
        let workspace = try requireWorkspace("/workspace")
        let plan = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        switch backend.prepare(plan, trueCommand) {
        case .success:
            Issue.record("unknown platform() contained prepare must fail closed")
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
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
                Issue.record(
                    "unknown platform() contained must be backendUnavailable, got \(error)"
                )
            }
        }
        #endif
    }

    // apply / prepare / run do not call AgentAuthorization.decide — Isolation
    // apply consumes IsolationPlan only. Verification: `rg` over Sources/RVIsolation.

    @Test func isolationApply_operatorProbe_printsEstablishedModes() throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }

        print(probeLine(requested: .contained, result: fixture.containedInside))
        print(probeLine(requested: .contained, result: fixture.containedOutside))
        print(probeLine(requested: .contained, result: fixture.containedChildOutside))
        print(probeLine(requested: .observed, result: fixture.observedOutside))
        print(probeLine(requested: .contained, result: fixture.containedUnavailable))
    }
}

private let trueCommand = IsolatedCommand(executable: "/usr/bin/true")!

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

private func resolvedWorkspacePath(_ workspace: WorkingDirectory) -> String {
    URL(fileURLWithPath: workspace.rawValue).resolvingSymlinksInPath().path
}

private func escapeSBPL(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func expectProfileNotApplicable(
    _ result: Result<SeatbeltProfile, IsolationApplyError>,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .success:
        Issue.record(
            "observed/mediated compileSeatbeltProfile must be profileNotApplicable",
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
            .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
            Issue.record(
                "observed/mediated profile compile must be profileNotApplicable, got \(error)",
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
    case .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
        Issue.record(
            "expected \(expected), got commandExecutableMustBeAbsolute",
            sourceLocation: sourceLocation
        )
    }
}

private struct ProbeFixture {
    let containedInside: Result<IsolatedRunResult, IsolationApplyError>
    let containedOutside: Result<IsolatedRunResult, IsolationApplyError>
    let containedChildOutside: Result<IsolatedRunResult, IsolationApplyError>
    let observedOutside: Result<IsolatedRunResult, IsolationApplyError>
    let containedUnavailable: Result<IsolatedRunResult, IsolationApplyError>
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-isolation-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspaceURL = root.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let resolvedWorkspace = workspaceURL.resolvingSymlinksInPath()
        let workspace = try requireWorkspace(resolvedWorkspace.path)
        let contained = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        let observed = try requirePlan(
            IsolationCompileRequest(requested: .observed, workspace: workspace)
        )
        let inside = resolvedWorkspace.appendingPathComponent("inside").path
        let outside = root.resolvingSymlinksInPath().appendingPathComponent("outside").path
        let childOutside = root.resolvingSymlinksInPath().appendingPathComponent("child-outside").path
        containedInside = IsolationBackends.apply(contained, command: touchCommand(inside))
        containedOutside = IsolationBackends.apply(contained, command: touchCommand(outside))
        containedChildOutside = IsolationBackends.apply(
            contained,
            command: IsolatedCommand(
                executable: "/bin/sh",
                arguments: ["-c", "/usr/bin/touch \(childOutside)"]
            )!
        )
        observedOutside = IsolationBackends.apply(
            observed,
            command: touchCommand(outside + "-observed")
        )
        containedUnavailable = IsolationBackends.unavailable().apply(
            contained,
            command: touchCommand(inside)
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func touchCommand(_ path: String) -> IsolatedCommand {
    IsolatedCommand(executable: "/usr/bin/touch", arguments: [path])!
}

private func probeLine(
    requested: RequestedIsolation,
    result: Result<IsolatedRunResult, IsolationApplyError>
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
    case .success(let run):
        let established: String
        let family: String
        switch run.established {
        case .observed:
            established = "observed"
            family = "none"
        case .mediated:
            established = "mediated"
            family = "none"
        case .seatbelt:
            established = "seatbelt"
            family = "seatbelt"
        }
        return
            "requested=\(requestedLabel) established=\(established) family=\(family) exit=\(run.exitStatus) error=none"
    case .failure(let error):
        return
            "requested=\(requestedLabel) established=none family=none exit=none error=\(describeError(error))"
    }
}

private func describeError(_ error: IsolationApplyError) -> String {
    switch error {
    case .backendUnavailable:
        return "backendUnavailable"
    case .backendMismatch:
        return "backendMismatch"
    case .workspaceMustBeAbsolute:
        return "workspaceMustBeAbsolute"
    case .workspaceDoesNotExist:
        return "workspaceDoesNotExist"
    case .workspacePathUnresolvable:
        return "workspacePathUnresolvable"
    case .workspacePathUnsafe:
        return "workspacePathUnsafe"
    case .workspaceContainsInodeAlias:
        return "workspaceContainsInodeAlias"
    case .workspaceInodeBoundaryFailed:
        return "workspaceInodeBoundaryFailed"
    case .containedGuaranteesUnsupported:
        return "containedGuaranteesUnsupported"
    case .profileNotApplicable:
        return "profileNotApplicable"
    case .processSpawnFailed:
        return "processSpawnFailed"
    case .commandContainsNUL:
        return "commandContainsNUL"
    case .commandExecutableMustBeAbsolute:
        return "commandExecutableMustBeAbsolute"
    case .sessionRecordFailed:
        return "sessionRecordFailed"
    case .seatbeltNotEstablished:
        return "seatbeltNotEstablished"
    case .lifetimeBoundaryFailed:
        return "lifetimeBoundaryFailed"
    case .cancelled:
        return "cancelled"
    case .workspaceUnresolved:
        return "workspaceUnresolved"
    }
}
