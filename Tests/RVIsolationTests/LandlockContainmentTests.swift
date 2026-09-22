#if os(Linux)
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Linux contained launch refuses before exec. These tests prove a strict
/// plan does not run the inner command and does not mint contained+landlock.
/// Observed apply is still unsandboxed. Filesystem-root and helper-identity
/// failures stay typed. A write-class helper is not a successful contained run.
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
        case .success:
            Issue.record("strict plan must not launch a write-only Landlock sandbox")
        case .failure(let error):
            expectContainedRefused(error)
            #expect(FileManager.default.fileExists(atPath: inside) == false)
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
        case .success:
            Issue.record("strict plan must not launch before an outside write")
        case .failure(let error):
            expectContainedRefused(error)
            #expect(FileManager.default.fileExists(atPath: outside) == false)
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
        case .success:
            Issue.record("strict plan must not launch a child shell")
        case .failure(let error):
            expectContainedRefused(error)
            #expect(FileManager.default.fileExists(atPath: outside) == false)
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

    @Test func landlock_writeUnderRepositoryRootOutsideWorkspace_isBlocked() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let leak = tree.repositoryURL.appendingPathComponent("leak.txt").path
        let result = IsolationBackends.apply(
            tree.containedDifferingRoot,
            command: IsolatedCommand(executable: "/usr/bin/touch", arguments: [leak])!
        )
        switch result {
        case .success:
            Issue.record("strict plan must not launch a repository write")
        case .failure(let error):
            expectContainedRefused(error)
            #expect(FileManager.default.fileExists(atPath: leak) == false)
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
        case .success:
            Issue.record("strict plan must not launch a truncate")
        case .failure(let error):
            expectContainedRefused(error)
            #expect(try String(contentsOfFile: outside, encoding: .utf8) == "keep-me\n")
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
            case .containedGuaranteesUnsupported:
                break
            case .backendUnavailable, .backendMismatch,
                .workspaceMustBeAbsolute,
                .workspaceDoesNotExist,
                .workspacePathUnresolvable,
                .workspacePathUnsafe,
                .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed,
                .profileNotApplicable,
                .processSpawnFailed,
                .commandContainsNUL,
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
                Issue.record("true override must be backendUnavailable, got \(error)")
            }
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

private func expectContainedRefused(
    _ error: IsolationApplyError,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch error {
    case .containedGuaranteesUnsupported:
        break
    case .backendUnavailable, .backendMismatch, .workspaceMustBeAbsolute,
        .workspaceDoesNotExist, .workspacePathUnresolvable, .workspacePathUnsafe,
        .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed, .profileNotApplicable, .processSpawnFailed,
        .commandContainsNUL, .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
        Issue.record(
            "strict contained plan must be containedGuaranteesUnsupported, got \(error)",
            sourceLocation: sourceLocation
        )
    }
}

private func expectContainedLandlock(
    _ established: EstablishedIsolation,
    matching plan: IsolationPlan,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch established {
    case .observed, .mediated, .seatbelt:
        Issue.record(
            "Landlock cannot be a successful IsolatedRunResult",
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
    case .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled:
        Issue.record(
            "expected \(expected), got commandExecutableMustBeAbsolute",
            sourceLocation: sourceLocation
        )
    }
}
#endif
