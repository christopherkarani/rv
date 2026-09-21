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
/// 4. `EstablishedIsolation` accepts contained+landlock; rejects
///    observed+landlock and contained+none (IsolationApply)
/// 5. `landlock().prepare(observed)` → `profileNotApplicable`
/// 6. Darwin: `landlock().prepare(contained)` may succeed; `run` →
///    `backendUnavailable` (no EstablishedIsolation)
/// 7. Darwin: `IsolationBackends.apply(contained)` still family `.seatbelt`
/// 8. `platform().family` is `.seatbelt` on Darwin and `.landlock` on Linux
/// 14. Trampoline exit 125 maps to `backendUnavailable` (not established)
/// 15. Missing trampoline → `backendUnavailable`
@Suite("IsolationApply")
struct IsolationApplyLandlockTests {
    @Test func compileLandlockRuleset_contained_writeRootIsResolvedWorkspaceNotRepositoryRoot()
        throws
    {
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
        switch compileLandlockRuleset(plan) {
        case .success(let ruleset):
            #expect(ruleset.workspacePath == resolvedWorkspace)
            #expect(ruleset.workspacePath != resolvedRepo)
            #expect(ruleset.workspacePath.contains("/repo") == false)
            #expect(ruleset.handledWriteAccess & LandlockAccessFS.writeFile != 0)
            #expect(ruleset.handledWriteAccess & LandlockAccessFS.refer != 0)
            #expect(ruleset.handledWriteAccess & LandlockAccessFS.execute == 0)
            #expect(ruleset.handledWriteAccess & LandlockAccessFS.readFile == 0)
            #expect(ruleset.handledWriteAccess & LandlockAccessFS.readDir == 0)
        case .failure(let error):
            recordUnexpectedApplyError(
                error,
                expected: "compiled first-slice Landlock ruleset rooted at /ws"
            )
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
                .containedGuaranteesUnsupported,
                .processSpawnFailed,
                .commandExecutableMustBeAbsolute:
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
        case .success(let request):
            #expect(request.family == .landlock)
            #expect(request.seatbeltProfile == nil)
            #expect(request.launchExecutable.contains("sandbox-exec") == false)
            #expect(request.launchExecutable.hasSuffix("rv-isolation-exec"))
            guard let ruleset = request.landlockRuleset else {
                Issue.record("landlock prepare must attach a ruleset")
                return
            }
            #expect(
                request.launchArguments == [
                    "--workspace", ruleset.workspacePath, "--", trueCommand.executable,
                ]
            )
        case .failure(let error):
            recordUnexpectedApplyError(error, expected: "prepared landlock launch argv")
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
        case .success(let request):
            switch backend.run(request) {
            case .success:
                Issue.record("missing trampoline must not establish contained")
            case .failure(let error):
                switch error {
                case .backendUnavailable:
                    break
                case .backendMismatch,
                    .workspaceMustBeAbsolute,
                    .workspaceDoesNotExist,
                    .workspacePathUnresolvable,
                    .workspacePathUnsafe,
                    .containedGuaranteesUnsupported,
                    .profileNotApplicable,
                    .processSpawnFailed,
                    .commandExecutableMustBeAbsolute:
                    Issue.record("missing trampoline must be backendUnavailable, got \(error)")
                }
            }
        case .failure(let error):
            recordUnexpectedApplyError(error, expected: "prepared landlock request for missing trampoline")
        }
    }

    @Test func isolationExecExit125_isBackendUnavailable_notEstablished() throws {
        let workspace = try requireWorkspace("/workspace")
        let contained = try requirePlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        )
        switch contained.mode {
        case .observed:
            Issue.record("compiled contained plan must not be observed")
        case .mediated:
            Issue.record("compiled contained plan must not be mediated")
        case .contained(let guarantees):
            let established = try #require(
                EstablishedIsolation(mode: .contained(guarantees), family: .landlock)
            )
            #expect(IsolationBackends.isolationExecCouldNotEstablishExit == 125)
            switch interpretIsolationExecExit(125, established: established) {
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
                    .containedGuaranteesUnsupported,
                    .profileNotApplicable,
                    .processSpawnFailed,
                    .commandExecutableMustBeAbsolute:
                    Issue.record("exit 125 must be backendUnavailable, got \(error)")
                }
            }
            switch interpretIsolationExecExit(1, established: established) {
            case .success(let result):
                #expect(result.exitStatus == 1)
                #expect(result.established.family == .landlock)
                switch result.established.mode {
                case .contained:
                    break
                case .observed:
                    Issue.record("inner deny must stay established contained")
                case .mediated:
                    Issue.record("inner deny must stay established contained")
                }
            case .failure(let error):
                recordUnexpectedApplyError(error, expected: "established contained with inner exit 1")
            }
        }
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
        case .success(let request):
            #expect(request.family == .landlock)
            switch backend.run(request) {
            case .success:
                Issue.record("Darwin landlock run must not establish contained")
            case .failure(let error):
                switch error {
                case .backendUnavailable:
                    break
                case .backendMismatch,
                    .workspaceMustBeAbsolute,
                    .workspaceDoesNotExist,
                    .workspacePathUnresolvable,
                    .workspacePathUnsafe,
                    .containedGuaranteesUnsupported,
                    .profileNotApplicable,
                    .processSpawnFailed,
                    .commandExecutableMustBeAbsolute:
                    Issue.record("Darwin landlock run must be backendUnavailable, got \(error)")
                }
            }
        case .failure(let error):
            recordUnexpectedApplyError(error, expected: "Darwin landlock prepare of existing workspace")
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
            .containedGuaranteesUnsupported,
            .processSpawnFailed,
            .commandExecutableMustBeAbsolute:
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
