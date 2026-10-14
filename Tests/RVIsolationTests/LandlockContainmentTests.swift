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
    @Test func landlock_touchInsideWorkspace_succeedsAndEstablishesContained() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let inside = tree.workspaceURL.appendingPathComponent("inside.txt").path
        let result = await IsolationBackends.applyOffPool(
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

    @Test func landlock_touchOutsideWorkspace_isBlockedFileAbsent_stillEstablishedContained() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("outside.txt").path
        #expect(FileManager.default.fileExists(atPath: outside) == false)
        let result = await IsolationBackends.applyOffPool(
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

    @Test func landlock_binShChild_cannotWriteOutsideWorkspace() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("child-outside.txt").path
        let result = await IsolationBackends.applyOffPool(
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

    @Test func landlock_writeUnderRepositoryRootOutsideWorkspace_isBlocked() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let leak = tree.repositoryURL.appendingPathComponent("leak.txt").path
        let result = await IsolationBackends.applyOffPool(
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

    @Test func landlock_truncateOutsideWorkspace_isBlockedFileUnchanged_stillEstablished() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("seed.txt").path
        try "keep-me\n".write(toFile: outside, atomically: true, encoding: .utf8)
        let python = python3Executable()
        let result = await IsolationBackends.applyOffPool(
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

    @Test func landlock_readOutsideWorkspace_refusedBeforeExec() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let outside = tree.siblingURL.appendingPathComponent("secret.txt").path
        try "outside-secret\n".write(toFile: outside, atomically: true, encoding: .utf8)
        let result = await IsolationBackends.applyOffPool(
            tree.contained,
            command: IsolatedCommand(executable: "/bin/cat", arguments: [outside])!
        )
        switch result {
        case .success:
            Issue.record("strict plan must not launch a read outside the workspace")
        case .failure(let error):
            expectContainedRefused(error)
        }
    }

    @Test func landlock_readInsideWorkspace_refusedBeforeExec() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }

        let inside = tree.workspaceURL.appendingPathComponent("note.txt").path
        try "inside-note\n".write(toFile: inside, atomically: true, encoding: .utf8)
        let result = await IsolationBackends.applyOffPool(
            tree.contained,
            command: IsolatedCommand(executable: "/bin/cat", arguments: [inside])!
        )
        switch result {
        case .success:
            Issue.record("strict plan must not launch even a workspace-scoped read")
        case .failure(let error):
            expectContainedRefused(error)
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

    /// Missing-inner exit follows the measured Landlock ABI. On ABI >= 3
    /// the helper applies the write slice, then `execve` fails (126); below
    /// 3 the shim probe fails closed and the helper exits 125 without exec
    /// (`Sources/RVIsolation/landlock_apply.c:104`,
    /// `Sources/rv-isolation-exec/main.c:54`). Neither exit mints
    /// establishment (`Sources/RVIsolation/LandlockApply.swift:80`). This is
    /// the `hard_requirement` shape — fail to start when the kernel cannot
    /// apply the rules — pinned per ABI regime instead of assumed (OpenShell
    /// `landlock.compatibility` with its ABI v3 floor:
    /// https://docs.nvidia.com/openshell/latest/how-it-works/policies/schema).
    @Test func trampoline_missingInnerAfterApply_exits126() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let exec = try requireIsolationExec()
        let missingInner = "/no/such/rv-isolation-inner-\(UUID().uuidString)"
        let status = try runIsolationExec(
            exec,
            arguments: ["--workspace", tree.workspaceURL.path, "--", missingInner]
        )
        #expect(status == expectedMissingInnerExit(forABI: measuredLandlockABI()))
    }

    /// AC-5 compile pin: every valid contained plan refuses at compile time
    /// with `containedGuaranteesUnsupported`, on any ABI regime. Compile is
    /// syscall-free (`Sources/RVIsolation/LandlockRuleset.swift:4`), so even
    /// an ABI >= 3 kernel must not flip this suite toward enforcement.
    @Test func compileContainedPlan_refusesRegardlessOfABI() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        for plan in [tree.contained, tree.containedDifferingRoot] {
            switch compileLandlockRuleset(plan) {
            case .success:
                Issue.record("valid contained plan must not compile a Landlock ruleset")
            case .failure(let error):
                expectContainedRefused(error)
            }
        }
    }

    @Test func landlock_overrideTrue_doesNotEstablishContained() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let backend = IsolationBackends.landlock(
            executable: URL(fileURLWithPath: "/usr/bin/true")
        )
        switch await backend.applyOffPool(tree.contained, command: trueCommand) {
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
                .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved, .resourceStagingFailed:
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

/// Helper exit for a valid invocation whose inner command is missing,
/// selected by measured Landlock ABI: 126 when ABI >= 3 lets the helper
/// reach `execve`, 125 when the shim probe fails closed below 3.
private func expectedMissingInnerExit(forABI abi: Int) -> Int32 {
    if abi >= 3 {
        return IsolationBackends.isolationExecExecFailedExit
    }
    return IsolationBackends.isolationExecCouldNotEstablishExit
}

/// Live Landlock ABI of the test kernel. Cross-checks the CI gate's
/// `RV_LANDLOCK_ABI` by regime when set: a disagreement means the gate
/// measured a different kernel than the suite runs on.
private func measuredLandlockABI(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Int {
    let live = liveLandlockABI()
    if let raw = environment["RV_LANDLOCK_ABI"] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ci = Int(trimmed) {
            if (ci >= 3) != (live >= 3) {
                Issue.record(
                    "CI-measured Landlock ABI \(ci) disagrees with live probe \(live)"
                )
            }
        } else {
            Issue.record("RV_LANDLOCK_ABI is not an integer: \(raw)")
        }
    }
    return live
}

/// VERSION probe of the running kernel via the same call the C shim
/// uses: `landlock_create_ruleset(NULL, 0, VERSION)` as raw syscall 444
/// with flags 1 (`Sources/RVIsolation/landlock_apply.c:104`; ctypes form
/// at `Scripts/isolation-linux-adversarial.py:161`). Returns the ABI
/// version, or -1 when the kernel does not implement Landlock (ENOSYS).
private func liveLandlockABI() -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python3Executable())
    process.arguments = [
        "-c",
        "import ctypes; print(ctypes.CDLL(None, use_errno=True).syscall(444, 0, 0, 1))",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        Issue.record("Landlock ABI probe failed to launch: \(error)")
        return -1
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        Issue.record("Landlock ABI probe exited \(process.terminationStatus)")
        return -1
    }
    let output = String(
        data: pipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let abi = Int(output) {
        return abi
    }
    Issue.record("Landlock ABI probe printed unparseable output: \(output)")
    return -1
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
        .commandContainsNUL, .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved, .resourceStagingFailed:
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
    case .workspaceContainsInodeAlias:
        Issue.record("expected \(expected), got workspaceContainsInodeAlias", sourceLocation: sourceLocation)
    case .workspaceInodeBoundaryFailed:
        Issue.record("expected \(expected), got workspaceInodeBoundaryFailed", sourceLocation: sourceLocation)
    case .containedGuaranteesUnsupported:
        Issue.record(
            "expected \(expected), got containedGuaranteesUnsupported",
            sourceLocation: sourceLocation
        )
    case .profileNotApplicable:
        Issue.record("expected \(expected), got profileNotApplicable", sourceLocation: sourceLocation)
    case .resourceStagingFailed(let detail):
        Issue.record(
            "expected \(expected), got resourceStagingFailed(\(detail))",
            sourceLocation: sourceLocation
        )
    case .processSpawnFailed:
        Issue.record("expected \(expected), got processSpawnFailed", sourceLocation: sourceLocation)
    case .commandContainsNUL:
        Issue.record("unexpected NUL command rejection")
    case .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved, .resourceStagingFailed:
        Issue.record(
            "expected \(expected), got commandExecutableMustBeAbsolute",
            sourceLocation: sourceLocation
        )
    }
}
#endif
