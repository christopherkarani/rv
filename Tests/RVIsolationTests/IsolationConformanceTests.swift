import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// First-slice named bypass catalog (Seatbelt + Landlock).
/// §8 IDs are locked here. A missing deny ID must fail this suite.
/// Deny / allow-in cases call `IsolationBackends.apply` only.
@Suite("IsolationConformance", .serialized)
struct IsolationConformanceTests {
    static let section8IDs: [String] = [
        "FS-WRITE-IN",
        "FS-WRITE-OUT",
        "FS-WRITE-REPO",
        "FS-MKDIR-OUT",
        "FS-APPEND-OUT",
        "FS-UNLINK-OUT",
        "FS-RENAME-OUT",
        "DESC-SH",
        "DESC-NESTED",
        "HOLE-NET",
        "HOLE-READ",
        "HOLE-SYMLINK",
        "FC-UNAVAILABLE",
        "FC-LANDLOCK-DARWIN",
        "FC-ROOT-WS",
        "FC-HELPER-IN-WS",
    ]

    @Test func isolationConformance_catalogListsEverySection8ID() {
        #expect(IsolationConformanceCatalog.ids == Self.section8IDs)
        #expect(Set(IsolationConformanceID.allCases.map(\.rawValue)) == Set(Self.section8IDs))
    }

    @Test func isolationConformance_catalogVerdictsMatchSection8() {
        #expect(verdict(.fsWriteIn) == .allowIn)
        #expect(verdict(.fsWriteOut) == .deny)
        #expect(verdict(.fsWriteRepo) == .deny)
        #expect(verdict(.fsMkdirOut) == .deny)
        #expect(verdict(.fsAppendOut) == .deny)
        #expect(verdict(.fsUnlinkOut) == .deny)
        #expect(verdict(.fsRenameOut) == .deny)
        #expect(verdict(.descSh) == .deny)
        #expect(verdict(.descNested) == .deny)
        #expect(verdict(.holeNet) == .hole)
        #expect(verdict(.holeRead) == .hole)
        #expect(verdict(.holeSymlink) == .hole)
        #expect(verdict(.fcUnavailable) == .failClosed)
        #expect(verdict(.fcLandlockDarwin) == .failClosed)
        #expect(verdict(.fcRootWs) == .failClosed)
        #expect(verdict(.fcHelperInWs) == .failClosed)
    }

    @Test(arguments: IsolationConformanceCatalog.denyAndAllowIn.map(\.id))
    func isolationConformance_kernelFence(_ id: IsolationConformanceID) throws {
        _ = try runCatalogID(id)
    }

    @Test(arguments: IsolationConformanceCatalog.holes.map(\.id))
    func isolationConformance_hole(_ id: IsolationConformanceID) throws {
        _ = try runCatalogID(id)
    }

    @Test(arguments: IsolationConformanceCatalog.failClosedOnThisPlatform.map(\.id))
    func isolationConformance_failClosed(_ id: IsolationConformanceID) throws {
        _ = try runCatalogID(id)
    }

    @Test func isolationConformance_operatorProbe_printsCatalog() throws {
        for entry in IsolationConformanceCatalog.entries {
            let line = try runCatalogID(entry.id)
            print(line)
            #expect(line.contains("id=\(entry.id.rawValue)"))
            #expect(line.contains("verdict=\(entry.verdict.rawValue)"))
        }
    }
}

extension IsolationConformanceID: CustomTestStringConvertible {
    var testDescription: String { rawValue }
}

extension IsolationConformanceCatalog {
    static var failClosedOnThisPlatform: [IsolationConformanceEntry] {
        failClosed.filter { entry in
            switch entry.id {
            case .fcLandlockDarwin:
                #if os(macOS)
                return true
                #else
                return false
                #endif
            case .fcHelperInWs:
                #if os(Linux)
                return true
                #else
                return false
                #endif
            case .fcUnavailable, .fcRootWs:
                return true
            case .fsWriteIn, .fsWriteOut, .fsWriteRepo, .fsMkdirOut, .fsAppendOut, .fsUnlinkOut,
                .fsRenameOut, .descSh, .descNested, .holeNet, .holeRead, .holeSymlink:
                return false
            }
        }
    }
}

private func verdict(_ id: IsolationConformanceID) -> IsolationConformanceVerdict? {
    IsolationConformanceCatalog.entries.first { $0.id == id }?.verdict
}

private func requireCommand(executable: String, arguments: [String] = []) throws -> IsolatedCommand {
    try #require(IsolatedCommand(executable: executable, arguments: arguments))
}

private func applyContained(
    _ plan: IsolationPlan,
    command: IsolatedCommand
) -> Result<IsolatedRunResult, IsolationApplyError> {
    IsolationBackends.apply(plan, command: command)
}

private func runCatalogID(_ id: IsolationConformanceID) throws -> String {
    let verdict = try #require(verdict(id))
    switch id {
    case .fsWriteIn:
        return try runAllowInTouch(verdict: verdict)
    case .fsWriteOut:
        return try runDenyAbsentTouch(
            id: id,
            verdict: verdict,
            plan: { $0.contained },
            target: { $0.siblingURL.appendingPathComponent("out.txt").path }
        )
    case .fsWriteRepo:
        return try runDenyAbsentTouch(
            id: id,
            verdict: verdict,
            plan: { $0.containedDifferingRoot },
            target: { $0.repositoryURL.appendingPathComponent("leak.txt").path }
        )
    case .fsMkdirOut:
        return try runDenyMkdir(verdict: verdict)
    case .fsAppendOut:
        return try runDenyAppend(verdict: verdict)
    case .fsUnlinkOut:
        return try runDenyUnlink(verdict: verdict)
    case .fsRenameOut:
        return try runDenyRename(verdict: verdict)
    case .descSh:
        return try runDenyDescendant(id: id, verdict: verdict, nested: false)
    case .descNested:
        return try runDenyDescendant(id: id, verdict: verdict, nested: true)
    case .holeNet:
        return try runHoleNet(verdict: verdict)
    case .holeRead:
        return try runHoleRead(verdict: verdict)
    case .holeSymlink:
        return try runHoleSymlink(verdict: verdict)
    case .fcUnavailable:
        return try runFCUnavailable(verdict: verdict)
    case .fcLandlockDarwin:
        #if os(macOS)
        return try runFCLandlockDarwin(verdict: verdict)
        #else
        return formatProbe(
            id: id,
            verdict: verdict,
            established: "-",
            family: "-",
            exit: "-",
            error: "darwin-only"
        )
        #endif
    case .fcRootWs:
        return try runFCRootWs(verdict: verdict)
    case .fcHelperInWs:
        #if os(Linux)
        return try runFCHelperInWs(verdict: verdict)
        #else
        return formatProbe(
            id: id,
            verdict: verdict,
            established: "-",
            family: "-",
            exit: "-",
            error: "linux-only"
        )
        #endif
    }
}

#if os(Linux)
/// Contained launch is refused. Kernel allow/deny evidence does not run.
private func expectLinuxContainedRefusal(
    _ result: Result<IsolatedRunResult, IsolationApplyError>,
    id: IsolationConformanceID,
    verdict: IsolationConformanceVerdict,
    sideEffect: () throws -> Void = {}
) throws -> String {
    switch result {
    case .failure(let error):
        if error != .containedGuaranteesUnsupported {
            recordUnexpectedConformanceError(
                error,
                id: id,
                expected: "containedGuaranteesUnsupported"
            )
        }
        try sideEffect()
        return formatProbe(id: id, verdict: verdict, error: error)
    case .success(let run):
        Issue.record("id=\(id.rawValue) Linux must refuse contained launch")
        try sideEffect()
        return formatProbe(id: id, verdict: verdict, run: run)
    }
}
#endif

private func runAllowInTouch(verdict: IsolationConformanceVerdict) throws -> String {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let inside = tree.workspaceURL.appendingPathComponent("in.txt").path
    let command = try requireCommand(executable: "/usr/bin/touch", arguments: [inside])
    let result = applyContained(tree.contained, command: command)
    #if os(Linux)
    return try expectLinuxContainedRefusal(result, id: .fsWriteIn, verdict: verdict) {
        #expect(FileManager.default.fileExists(atPath: inside) == false)
    }
    #else
    switch result {
    case .success(let run):
        #expect(run.exitStatus == 0)
        #expect(FileManager.default.fileExists(atPath: inside))
        expectFirstSliceContained(run.established, matching: tree.contained, id: .fsWriteIn)
        return formatProbe(id: .fsWriteIn, verdict: verdict, run: run)
    case .failure(let error):
        recordUnexpectedConformanceError(
            error,
            id: .fsWriteIn,
            expected: "in-workspace touch established contained"
        )
        return formatProbe(id: .fsWriteIn, verdict: verdict, error: error)
    }
    #endif
}

private func runDenyAbsentTouch(
    id: IsolationConformanceID,
    verdict: IsolationConformanceVerdict,
    plan: (ContainmentTree) -> IsolationPlan,
    target: (ContainmentTree) -> String
) throws -> String {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let isolation = plan(tree)
    let path = target(tree)
    #expect(FileManager.default.fileExists(atPath: path) == false)
    let command = try requireCommand(executable: "/usr/bin/touch", arguments: [path])
    let result = applyContained(isolation, command: command)
    #if os(Linux)
    return try expectLinuxContainedRefusal(result, id: id, verdict: verdict) {
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }
    #else
    switch result {
    case .success(let run):
        expectDeniedExit(run.exitStatus, id: id)
        #expect(FileManager.default.fileExists(atPath: path) == false)
        expectFirstSliceContained(run.established, matching: isolation, id: id)
        return formatProbe(id: id, verdict: verdict, run: run)
    case .failure(let error):
        recordUnexpectedConformanceError(
            error,
            id: id,
            expected: "blocked outside write with established contained"
        )
        return formatProbe(id: id, verdict: verdict, error: error)
    }
    #endif
}

private func runDenyMkdir(verdict: IsolationConformanceVerdict) throws -> String {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let path = tree.siblingURL.appendingPathComponent("newdir").path
    #expect(FileManager.default.fileExists(atPath: path) == false)
    let command = try requireCommand(executable: "/bin/mkdir", arguments: [path])
    let result = applyContained(tree.contained, command: command)
    #if os(Linux)
    return try expectLinuxContainedRefusal(result, id: .fsMkdirOut, verdict: verdict) {
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }
    #else
    switch result {
    case .success(let run):
        expectDeniedExit(run.exitStatus, id: .fsMkdirOut)
        #expect(FileManager.default.fileExists(atPath: path) == false)
        expectFirstSliceContained(run.established, matching: tree.contained, id: .fsMkdirOut)
        return formatProbe(id: .fsMkdirOut, verdict: verdict, run: run)
    case .failure(let error):
        recordUnexpectedConformanceError(
            error,
            id: .fsMkdirOut,
            expected: "blocked outside mkdir with established contained"
        )
        return formatProbe(id: .fsMkdirOut, verdict: verdict, error: error)
    }
    #endif
}

private func runDenyAppend(verdict: IsolationConformanceVerdict) throws -> String {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let path = tree.siblingURL.appendingPathComponent("exist.txt").path
    try "keep\n".write(toFile: path, atomically: true, encoding: .utf8)
    let command = try requireCommand(executable: "/bin/sh", arguments: ["-c", ": >> \(path)"])
    let result = applyContained(tree.contained, command: command)
    #if os(Linux)
    return try expectLinuxContainedRefusal(result, id: .fsAppendOut, verdict: verdict) {
        let remaining = try String(contentsOfFile: path, encoding: .utf8)
        #expect(remaining == "keep\n")
    }
    #else
    switch result {
    case .success(let run):
        expectDeniedExit(run.exitStatus, id: .fsAppendOut)
        let remaining = try String(contentsOfFile: path, encoding: .utf8)
        #expect(remaining == "keep\n")
        expectFirstSliceContained(run.established, matching: tree.contained, id: .fsAppendOut)
        return formatProbe(id: .fsAppendOut, verdict: verdict, run: run)
    case .failure(let error):
        recordUnexpectedConformanceError(
            error,
            id: .fsAppendOut,
            expected: "blocked outside append with established contained"
        )
        return formatProbe(id: .fsAppendOut, verdict: verdict, error: error)
    }
    #endif
}

private func runDenyUnlink(verdict: IsolationConformanceVerdict) throws -> String {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let path = tree.siblingURL.appendingPathComponent("del.txt").path
    try "keep\n".write(toFile: path, atomically: true, encoding: .utf8)
    let command = try requireCommand(executable: "/bin/rm", arguments: [path])
    let result = applyContained(tree.contained, command: command)
    #if os(Linux)
    return try expectLinuxContainedRefusal(result, id: .fsUnlinkOut, verdict: verdict) {
        #expect(FileManager.default.fileExists(atPath: path))
    }
    #else
    switch result {
    case .success(let run):
        expectDeniedExit(run.exitStatus, id: .fsUnlinkOut)
        #expect(FileManager.default.fileExists(atPath: path))
        expectFirstSliceContained(run.established, matching: tree.contained, id: .fsUnlinkOut)
        return formatProbe(id: .fsUnlinkOut, verdict: verdict, run: run)
    case .failure(let error):
        recordUnexpectedConformanceError(
            error,
            id: .fsUnlinkOut,
            expected: "blocked outside unlink with established contained"
        )
        return formatProbe(id: .fsUnlinkOut, verdict: verdict, error: error)
    }
    #endif
}

private func runDenyRename(verdict: IsolationConformanceVerdict) throws -> String {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let source = tree.workspaceURL.appendingPathComponent("move.txt").path
    let dest = tree.siblingURL.appendingPathComponent("moved.txt").path
    try "keep\n".write(toFile: source, atomically: true, encoding: .utf8)
    let command = try requireCommand(executable: "/bin/mv", arguments: [source, dest])
    let result = applyContained(tree.contained, command: command)
    #if os(Linux)
    return try expectLinuxContainedRefusal(result, id: .fsRenameOut, verdict: verdict) {
        #expect(FileManager.default.fileExists(atPath: dest) == false)
        #expect(FileManager.default.fileExists(atPath: source))
    }
    #else
    switch result {
    case .success(let run):
        expectDeniedExit(run.exitStatus, id: .fsRenameOut)
        #expect(FileManager.default.fileExists(atPath: dest) == false)
        #expect(FileManager.default.fileExists(atPath: source))
        expectFirstSliceContained(run.established, matching: tree.contained, id: .fsRenameOut)
        return formatProbe(id: .fsRenameOut, verdict: verdict, run: run)
    case .failure(let error):
        recordUnexpectedConformanceError(
            error,
            id: .fsRenameOut,
            expected: "blocked rename-out with established contained"
        )
        return formatProbe(id: .fsRenameOut, verdict: verdict, error: error)
    }
    #endif
}

private func runDenyDescendant(
    id: IsolationConformanceID,
    verdict: IsolationConformanceVerdict,
    nested: Bool
) throws -> String {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let outside = tree.siblingURL.appendingPathComponent("out.txt").path
    let script: String
    if nested {
        script = "/bin/sh -c '/usr/bin/touch \(outside)'"
    } else {
        script = "/usr/bin/touch \(outside)"
    }
    let command = try requireCommand(executable: "/bin/sh", arguments: ["-c", script])
    let result = applyContained(tree.contained, command: command)
    #if os(Linux)
    return try expectLinuxContainedRefusal(result, id: id, verdict: verdict) {
        #expect(FileManager.default.fileExists(atPath: outside) == false)
    }
    #else
    switch result {
    case .success(let run):
        expectDeniedExit(run.exitStatus, id: id)
        #expect(FileManager.default.fileExists(atPath: outside) == false)
        expectFirstSliceContained(run.established, matching: tree.contained, id: id)
        return formatProbe(id: id, verdict: verdict, run: run)
    case .failure(let error):
        recordUnexpectedConformanceError(
            error,
            id: id,
            expected: "blocked inherited outside touch with established contained"
        )
        return formatProbe(id: id, verdict: verdict, error: error)
    }
    #endif
}

private func runHoleNet(verdict: IsolationConformanceVerdict) throws -> String {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    switch compileSeatbeltProfile(tree.contained) {
    case .success(let profile):
        #expect(profile.source.contains("(deny default)"))
        #expect(profile.source.contains("(allow network") == false)
    case .failure(let error):
        recordUnexpectedConformanceError(
            error,
            id: .holeNet,
            expected: "compiled Seatbelt profile that does not allow network"
        )
    }
    switch compileLandlockRuleset(tree.contained) {
    case .success:
        Issue.record("id=HOLE-NET Landlock must not compile a weaker ruleset")
    case .failure(let error):
        switch error {
        case .containedGuaranteesUnsupported:
            break
        case .backendUnavailable, .backendMismatch, .workspaceMustBeAbsolute,
            .workspaceDoesNotExist, .workspacePathUnresolvable, .workspacePathUnsafe,
            .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed, .profileNotApplicable, .processSpawnFailed,
            .commandContainsNUL, .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
            recordUnexpectedConformanceError(
                error,
                id: .holeNet,
                expected: "Landlock refusal of a network-denied plan"
            )
        }
    }
    let command = try requireCommand(executable: "/usr/bin/true")
    let result = applyContained(tree.contained, command: command)
    #if os(Linux)
    return try expectLinuxContainedRefusal(result, id: .holeNet, verdict: verdict)
    #else
    switch result {
    case .success(let run):
        expectFirstSliceContained(run.established, matching: tree.contained, id: .holeNet)
        return formatProbe(id: .holeNet, verdict: verdict, run: run)
    case .failure(let error):
        recordUnexpectedConformanceError(
            error,
            id: .holeNet,
            expected: "established contained with unrestricted network"
        )
        return formatProbe(id: .holeNet, verdict: verdict, error: error)
    }
    #endif
}

private func runHoleRead(verdict: IsolationConformanceVerdict) throws -> String {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let secret = tree.siblingURL.appendingPathComponent("secret.txt").path
    try "secret\n".write(toFile: secret, atomically: true, encoding: .utf8)
    let command = try requireCommand(executable: "/bin/cat", arguments: [secret])
    let result = applyContained(tree.contained, command: command)
    let unchanged = (try? String(contentsOfFile: secret, encoding: .utf8)) == "secret\n"
    #expect(unchanged)
    switch result {
    case .success(let run):
        #expect(run.exitStatus != 0)
        expectFirstSliceContained(run.established, matching: tree.contained, id: .holeRead)
        return formatProbe(id: .holeRead, verdict: verdict, run: run)
    case .failure(let error):
        switch error {
        case .containedGuaranteesUnsupported:
            break
        case .backendUnavailable, .backendMismatch, .workspaceMustBeAbsolute,
            .workspaceDoesNotExist, .workspacePathUnresolvable, .workspacePathUnsafe,
            .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed, .profileNotApplicable, .processSpawnFailed,
            .commandContainsNUL, .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
            recordUnexpectedConformanceError(
                error,
                id: .holeRead,
                expected: "denied read or refused launch"
            )
        }
        return formatProbe(id: .holeRead, verdict: verdict, error: error)
    }
}

private func runHoleSymlink(verdict: IsolationConformanceVerdict) throws -> String {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let outside = tree.siblingURL.appendingPathComponent("via-link.txt").path
    let link = tree.workspaceURL.appendingPathComponent("link.txt").path
    try "before\n".write(toFile: outside, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
    let command = try requireCommand(executable: "/bin/sh", arguments: ["-c", "printf x >> \(link)"])
    let result = applyContained(tree.contained, command: command)
    #if os(Linux)
    return try expectLinuxContainedRefusal(result, id: .holeSymlink, verdict: verdict) {
        let remaining = try String(contentsOfFile: outside, encoding: .utf8)
        #expect(remaining == "before\n")
    }
    #else
    switch result {
    case .success(let run):
        expectFirstSliceContained(run.established, matching: tree.contained, id: .holeSymlink)
        let remaining = try String(contentsOfFile: outside, encoding: .utf8)
        let effect = remaining == "before\n" ? "unchanged" : "changed"
        print("id=HOLE-SYMLINK effect=\(effect)")
        return formatProbe(id: .holeSymlink, verdict: verdict, run: run, effect: effect)
    case .failure(let error):
        recordUnexpectedConformanceError(
            error,
            id: .holeSymlink,
            expected: "established contained write via workspace symlink"
        )
        let remaining = try String(contentsOfFile: outside, encoding: .utf8)
        let effect = remaining == "before\n" ? "unchanged" : "changed"
        print("id=HOLE-SYMLINK effect=\(effect)")
        return formatProbe(id: .holeSymlink, verdict: verdict, error: error, effect: effect)
    }
    #endif
}

private func runFCUnavailable(verdict: IsolationConformanceVerdict) throws -> String {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let inside = tree.workspaceURL.appendingPathComponent("in.txt").path
    let command = try requireCommand(executable: "/usr/bin/touch", arguments: [inside])
    switch IsolationBackends.unavailable().apply(tree.contained, command: command) {
    case .success(let run):
        recordMintedContained(id: .fcUnavailable, established: run.established)
        return formatProbe(id: .fcUnavailable, verdict: verdict, run: run)
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
                "id=FC-UNAVAILABLE must be backendUnavailable, got \(isolationApplyErrorName(error))"
            )
        }
        return formatProbe(id: .fcUnavailable, verdict: verdict, error: error)
    }
}

#if os(macOS)
private func runFCLandlockDarwin(verdict: IsolationConformanceVerdict) throws -> String {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let command = try requireCommand(executable: "/usr/bin/true")
    let backend = IsolationBackends.landlock()
    switch backend.prepare(tree.contained, command) {
    case .success(let request):
        switch backend.run(request) {
        case .success(let run):
            recordMintedContained(id: .fcLandlockDarwin, established: run.established)
            return formatProbe(id: .fcLandlockDarwin, verdict: verdict, run: run)
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
                    "id=FC-LANDLOCK-DARWIN must be backendUnavailable, got \(isolationApplyErrorName(error))"
                )
            }
            return formatProbe(id: .fcLandlockDarwin, verdict: verdict, error: error)
        }
    case .failure(let error):
        switch error {
        case .containedGuaranteesUnsupported:
            return formatProbe(id: .fcLandlockDarwin, verdict: verdict, error: error)
        case .backendUnavailable, .backendMismatch, .workspaceMustBeAbsolute,
            .workspaceDoesNotExist, .workspacePathUnresolvable, .workspacePathUnsafe,
            .workspaceContainsInodeAlias, .workspaceInodeBoundaryFailed, .profileNotApplicable, .processSpawnFailed,
            .commandContainsNUL, .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
            recordUnexpectedConformanceError(
                error,
                id: .fcLandlockDarwin,
                expected: "Darwin landlock refusal of a strict contained plan"
            )
            return formatProbe(id: .fcLandlockDarwin, verdict: verdict, error: error)
        }
    }
}
#endif

private func runFCRootWs(verdict: IsolationConformanceVerdict) throws -> String {
    let workspace = try ContainmentTree.requireWorkspace("/")
    let plan = try ContainmentTree.requirePlan(
        IsolationCompileRequest(requested: .contained, workspace: workspace)
    )
    switch compileSeatbeltProfile(plan) {
    case .success:
        Issue.record("id=FC-ROOT-WS Seatbelt compile must be workspacePathUnsafe")
    case .failure(let error):
        expectWorkspacePathUnsafe(error, stage: "Seatbelt compile")
    }
    switch compileLandlockRuleset(plan) {
    case .success:
        Issue.record("id=FC-ROOT-WS Landlock compile must be workspacePathUnsafe")
    case .failure(let error):
        expectWorkspacePathUnsafe(error, stage: "Landlock compile")
    }
    let command = try requireCommand(executable: "/usr/bin/true")
    switch IsolationBackends.apply(plan, command: command) {
    case .success(let run):
        recordMintedContained(id: .fcRootWs, established: run.established)
        return formatProbe(id: .fcRootWs, verdict: verdict, run: run)
    case .failure(let error):
        expectWorkspacePathUnsafe(error, stage: "apply")
        return formatProbe(id: .fcRootWs, verdict: verdict, error: error)
    }
}

#if os(Linux)
private func runFCHelperInWs(verdict: IsolationConformanceVerdict) throws -> String {
    let tree = try ContainmentTree()
    defer { tree.tearDown() }
    let helper = tree.workspaceURL.appendingPathComponent("rv-isolation-exec")
    try "#!/bin/sh\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    let inside = tree.workspaceURL.appendingPathComponent("in.txt").path
    let command = try requireCommand(executable: "/usr/bin/touch", arguments: [inside])
    let backend = IsolationBackends.landlock(executable: helper)
    switch backend.apply(tree.contained, command: command) {
    case .success(let run):
        recordMintedContained(id: .fcHelperInWs, established: run.established)
        return formatProbe(id: .fcHelperInWs, verdict: verdict, run: run)
    case .failure(let error):
        return formatProbe(id: .fcHelperInWs, verdict: verdict, error: error)
    }
}
#endif

private func expectDeniedExit(
    _ status: Int32,
    id: IsolationConformanceID,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(status != 0, "id=\(id.rawValue) deny exit must be nonzero", sourceLocation: sourceLocation)
    #if os(Linux)
    #expect(
        status != IsolationBackends.isolationExecCouldNotEstablishExit,
        "id=\(id.rawValue) Linux deny exit must not be trampoline 125",
        sourceLocation: sourceLocation
    )
    #expect(
        status != IsolationBackends.isolationExecExecFailedExit,
        "id=\(id.rawValue) Linux deny exit must not be trampoline 126",
        sourceLocation: sourceLocation
    )
    #endif
}

private func expectFirstSliceContained(
    _ established: EstablishedIsolation,
    matching plan: IsolationPlan,
    id: IsolationConformanceID,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    expectPlatformContainedFamily(established, id: id, sourceLocation: sourceLocation)
    switch plan.mode {
    case .contained(let guarantees):
        switch guarantees.filesystem {
        case .workspaceScoped(let limitedTo):
            #expect(limitedTo == plan.workspace, sourceLocation: sourceLocation)
        case .unrestricted:
            Issue.record(
                "id=\(id.rawValue) established contained must keep workspace scope",
                sourceLocation: sourceLocation
            )
        }
        switch guarantees.descent {
        case .inherited:
            break
        case .notInherited:
            Issue.record(
                "id=\(id.rawValue) established contained must keep inherited descent",
                sourceLocation: sourceLocation
            )
        }
        switch guarantees.network {
        case .denied:
            break
        case .unrestricted:
            Issue.record(
                "id=\(id.rawValue) established contained must keep denied network",
                sourceLocation: sourceLocation
            )
        }
        switch guarantees.process {
        case .hostSignalsDenied:
            break
        case .unrestricted:
            Issue.record(
                "id=\(id.rawValue) established contained must keep host signal denial",
                sourceLocation: sourceLocation
            )
        }
    case .observed:
        Issue.record(
            "id=\(id.rawValue) matching plan must be contained, not observed",
            sourceLocation: sourceLocation
        )
    case .mediated:
        Issue.record(
            "id=\(id.rawValue) matching plan must be contained, not mediated",
            sourceLocation: sourceLocation
        )
    }
}

private func expectPlatformContainedFamily(
    _ established: EstablishedIsolation,
    id: IsolationConformanceID,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #if os(macOS)
    switch established {
    case .seatbelt(let session):
        #expect(session.backend == .seatbelt, sourceLocation: sourceLocation)
    case .observed:
        Issue.record(
            "id=\(id.rawValue) Darwin deny/allow-in must be seatbelt, not observed",
            sourceLocation: sourceLocation
        )
    case .mediated:
        Issue.record(
            "id=\(id.rawValue) Darwin deny/allow-in must be seatbelt, not mediated",
            sourceLocation: sourceLocation
        )
    }
    #elseif os(Linux)
    switch established {
    case .observed, .mediated, .seatbelt:
        Issue.record(
            "id=\(id.rawValue) Linux contained success must not mint IsolatedRunResult",
            sourceLocation: sourceLocation
        )
    }
    #else
    Issue.record(
        "id=\(id.rawValue) first-slice conformance requires Darwin or Linux",
        sourceLocation: sourceLocation
    )
    switch established {
    case .observed, .mediated, .seatbelt:
        break
    }
    #endif
}

private func recordMintedContained(id: IsolationConformanceID, established: EstablishedIsolation) {
    switch established {
    case .seatbelt:
        Issue.record("id=\(id.rawValue) fail-closed must not mint seatbelt establishment")
    case .observed:
        Issue.record("id=\(id.rawValue) fail-closed must be Result.failure, got observed")
    case .mediated:
        Issue.record("id=\(id.rawValue) fail-closed must be Result.failure, got mediated")
    }
}

private func expectWorkspacePathUnsafe(_ error: IsolationApplyError, stage: String) {
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
        Issue.record(
            "id=FC-ROOT-WS \(stage) must be workspacePathUnsafe, got \(isolationApplyErrorName(error))"
        )
    }
}

private func recordUnexpectedConformanceError(
    _ error: IsolationApplyError,
    id: IsolationConformanceID,
    expected: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    Issue.record(
        "id=\(id.rawValue) expected \(expected), got \(isolationApplyErrorName(error))",
        sourceLocation: sourceLocation
    )
}

private func isolationApplyErrorName(_ error: IsolationApplyError) -> String {
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

private func formatProbe(
    id: IsolationConformanceID,
    verdict: IsolationConformanceVerdict,
    run: IsolatedRunResult,
    effect: String? = nil
) -> String {
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
    return formatProbe(
        id: id,
        verdict: verdict,
        established: established,
        family: family,
        exit: String(run.exitStatus),
        error: "-",
        effect: effect
    )
}

private func formatProbe(
    id: IsolationConformanceID,
    verdict: IsolationConformanceVerdict,
    error: IsolationApplyError,
    effect: String? = nil
) -> String {
    formatProbe(
        id: id,
        verdict: verdict,
        established: "-",
        family: "-",
        exit: "-",
        error: isolationApplyErrorName(error),
        effect: effect
    )
}

private func formatProbe(
    id: IsolationConformanceID,
    verdict: IsolationConformanceVerdict,
    established: String,
    family: String,
    exit: String,
    error: String,
    effect: String? = nil
) -> String {
    var line =
        "id=\(id.rawValue) verdict=\(verdict.rawValue) established=\(established) family=\(family) exit=\(exit) error=\(error)"
    if let effect {
        line += " effect=\(effect)"
    }
    return line
}
