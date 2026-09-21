#if os(Linux)
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Linux kernel edges this suite encodes before production code:
/// 9. contained + landlock: `touch` inside → exit 0, file exists, established
///    contained + `.landlock`
/// 10. `touch` outside (sibling) → exit != 0 and != 125, file absent,
///     established still contained + `.landlock`
/// 11. `/bin/sh -c touch OUTSIDE` → same (inheritance)
/// 12. observed `apply`: outside `touch` succeeds (not secretly jailed)
/// 13. write under `RepositoryRoot` but outside workspace is blocked
/// 14. trampoline apply failure exits 125 and does not exec
/// 15. outside truncate is denied (ABI ≥ 3 write-class) and still established
/// 16. trampoline argv lock and filesystem-root workspace exit 125
/// 17. missing inner after apply exits 126 and does not mint establishment
/// 18. `landlock(executable: /usr/bin/true)` does not establish
/// Missing Landlock / missing trampoline must fail these tests — do not skip.
@Suite("LandlockContainment")
struct LandlockContainmentTests {
    @Test func landlock_touchInsideWorkspace_succeedsAndEstablishesContained() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let inside = tree.workspaceURL.appendingPathComponent("inside.txt").path
        let result = IsolationBackends.apply(
            tree.contained,
            command: IsolatedCommand(executable: "/usr/bin/touch", arguments: [inside])!
        )
        switch result {
        case .success(let run):
            #expect(run.exitStatus == 0)
            #expect(FileManager.default.fileExists(atPath: inside))
            expectContainedLandlock(run.established, matching: tree.contained)
        case .failure(let error):
            recordUnexpectedContainmentError(error, expected: "in-workspace touch")
        }
    }

    @Test func landlock_touchOutsideWorkspace_isBlockedFileAbsent_stillEstablishedContained() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("outside.txt").path
        #expect(FileManager.default.fileExists(atPath: outside) == false)
        let result = IsolationBackends.apply(
            tree.contained,
            command: IsolatedCommand(executable: "/usr/bin/touch", arguments: [outside])!
        )
        switch result {
        case .success(let run):
            #expect(run.exitStatus != 0)
            #expect(run.exitStatus != IsolationBackends.isolationExecCouldNotEstablishExit)
            #expect(FileManager.default.fileExists(atPath: outside) == false)
            expectContainedLandlock(run.established, matching: tree.contained)
        case .failure(let error):
            recordUnexpectedContainmentError(
                error,
                expected: "blocked outside touch with established contained"
            )
        }
    }

    @Test func landlock_binShChild_cannotWriteOutsideWorkspace() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("child-outside.txt").path
        let result = IsolationBackends.apply(
            tree.contained,
            command: IsolatedCommand(
                executable: "/bin/sh",
                arguments: ["-c", "/usr/bin/touch \(outside)"]
            )!
        )
        switch result {
        case .success(let run):
            #expect(run.exitStatus != 0)
            #expect(run.exitStatus != IsolationBackends.isolationExecCouldNotEstablishExit)
            #expect(FileManager.default.fileExists(atPath: outside) == false)
            expectContainedLandlock(run.established, matching: tree.contained)
        case .failure(let error):
            recordUnexpectedContainmentError(error, expected: "inherited write deny for /bin/sh child")
        }
    }

    @Test func observed_touchOutsideWorkspace_succeeds_notSecretlySandboxed() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("observed-outside.txt").path
        let result = IsolationBackends.apply(
            tree.observed,
            command: IsolatedCommand(executable: "/usr/bin/touch", arguments: [outside])!
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
            case .landlock:
                Issue.record("observed control must not use family landlock")
            }
        case .failure(let error):
            recordUnexpectedContainmentError(error, expected: "unsandboxed observed outside touch")
        }
    }

    @Test func landlock_writeUnderRepositoryRootOutsideWorkspace_isBlocked() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let leak = tree.repositoryURL.appendingPathComponent("leak.txt").path
        let result = IsolationBackends.apply(
            tree.containedDifferingRoot,
            command: IsolatedCommand(executable: "/usr/bin/touch", arguments: [leak])!
        )
        switch result {
        case .success(let run):
            #expect(run.exitStatus != 0)
            #expect(run.exitStatus != IsolationBackends.isolationExecCouldNotEstablishExit)
            #expect(FileManager.default.fileExists(atPath: leak) == false)
            expectContainedLandlock(run.established, matching: tree.containedDifferingRoot)
        case .failure(let error):
            recordUnexpectedContainmentError(
                error,
                expected: "blocked write under repositoryRoot outside workspace"
            )
        }
    }

    @Test func trampoline_applyFailure_exits125_andDoesNotExec() throws {
        let missingWorkspace = "/no/such/rv-landlock-workspace-\(UUID().uuidString)"
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-landlock-must-not-exec-\(UUID().uuidString)").path
        let exec = try requireIsolationExec()
        let process = Process()
        process.executableURL = exec
        process.arguments = [
            "--workspace", missingWorkspace, "--", "/usr/bin/touch", marker,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == IsolationBackends.isolationExecCouldNotEstablishExit)
        #expect(FileManager.default.fileExists(atPath: marker) == false)
    }

    @Test func landlock_truncateOutsideWorkspace_isBlockedFileUnchanged_stillEstablished() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("seed.txt").path
        try "keep-me\n".write(toFile: outside, atomically: true, encoding: .utf8)
        let python = python3Executable()
        let result = IsolationBackends.apply(
            tree.contained,
            command: IsolatedCommand(
                executable: python,
                arguments: ["-c", "import os,sys; os.truncate(sys.argv[1], 0)", outside]
            )!
        )
        switch result {
        case .success(let run):
            #expect(run.exitStatus != 0)
            #expect(run.exitStatus != IsolationBackends.isolationExecCouldNotEstablishExit)
            #expect(run.exitStatus != IsolationBackends.isolationExecExecFailedExit)
            let remaining = try String(contentsOfFile: outside, encoding: .utf8)
            #expect(remaining == "keep-me\n")
            expectContainedLandlock(run.established, matching: tree.contained)
        case .failure(let error):
            recordUnexpectedContainmentError(
                error,
                expected: "blocked outside truncate with established contained"
            )
        }
    }

    @Test func trampoline_argvLock_exits125_andDoesNotExec() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let exec = try requireIsolationExec()
        let marker = tree.siblingURL.appendingPathComponent("argv-must-not-exec").path
        let cases: [[String]] = [
            [],
            ["--workspace"],
            ["--workspace", tree.workspaceURL.path],
            ["--not-workspace", tree.workspaceURL.path, "--", "/usr/bin/touch", marker],
            ["--workspace", "relative-ws", "--", "/usr/bin/touch", marker],
            ["--workspace", "/", "--", "/usr/bin/touch", marker],
            ["--workspace", tree.workspaceURL.path, "--"],
            ["--workspace", tree.workspaceURL.path, "--", "touch", marker],
        ]
        for arguments in cases {
            let status = try runIsolationExec(exec, arguments: arguments)
            #expect(status == IsolationBackends.isolationExecCouldNotEstablishExit)
            #expect(FileManager.default.fileExists(atPath: marker) == false)
        }
    }

    @Test func trampoline_missingInnerAfterApply_exits126() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let exec = try requireIsolationExec()
        let missingInner = "/no/such/rv-isolation-inner-\(UUID().uuidString)"
        let status = try runIsolationExec(
            exec,
            arguments: ["--workspace", tree.workspaceURL.path, "--", missingInner]
        )
        #expect(status == IsolationBackends.isolationExecExecFailedExit)
    }

    @Test func landlock_overrideTrue_doesNotEstablishContained() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let backend = IsolationBackends.landlock(
            executable: URL(fileURLWithPath: "/usr/bin/true")
        )
        switch backend.apply(tree.contained, command: trueCommand) {
        case .success:
            Issue.record("/usr/bin/true must not mint contained+landlock")
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
                Issue.record("true override must be backendUnavailable, got \(error)")
            }
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
            .appendingPathComponent("rv-landlock-\(UUID().uuidString)", isDirectory: true)
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

private func requireIsolationExec() throws -> URL {
    if let env = ProcessInfo.processInfo.environment["RV_ISOLATION_EXEC"],
        env.hasPrefix("/"),
        FileManager.default.isExecutableFile(atPath: env)
    {
        return URL(fileURLWithPath: env)
    }
    if let argv0 = CommandLine.arguments.first {
        let sibling = URL(fileURLWithPath: argv0)
            .deletingLastPathComponent()
            .appendingPathComponent("rv-isolation-exec")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
    }
    for bundle in Bundle.allBundles {
        let sibling = bundle.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("rv-isolation-exec")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
    }
    Issue.record("rv-isolation-exec must be built next to the test process")
    throw IsolationApplyError.backendUnavailable
}

private let trueCommand = IsolatedCommand(executable: "/usr/bin/true")!

private func python3Executable() -> String {
    let candidates = ["/usr/bin/python3", "/usr/bin/python3.12", "/usr/bin/python3.11"]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    Issue.record("python3 is required to prove outside truncate is denied")
    return "/usr/bin/python3"
}

private func runIsolationExec(_ exec: URL, arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = exec
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func expectContainedLandlock(
    _ established: EstablishedIsolation,
    matching plan: IsolationPlan,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(established.mode == plan.mode, sourceLocation: sourceLocation)
    switch established.family {
    case .landlock:
        break
    case .none:
        Issue.record("Linux contained establish must be family landlock", sourceLocation: sourceLocation)
    case .seatbelt:
        Issue.record(
            "Linux contained establish must be family landlock, not seatbelt",
            sourceLocation: sourceLocation
        )
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
        Issue.record("Linux contained establish must not be observed", sourceLocation: sourceLocation)
    case .mediated:
        Issue.record("Linux contained establish must not be mediated", sourceLocation: sourceLocation)
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
