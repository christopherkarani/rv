import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Host-launch edges this suite encodes before production code:
/// 1. `.pi` / `.claude` + contained isolation + `/usr/bin/true` → `hostUnsupported`; no spawn
/// 2. Observed plan `containedIsolation()` is `.notContained`; launch is not called
/// 3. Mediated plan `containedIsolation()` is `.notContained`; launch is not called
/// 4. `.opencode` + contained + `/usr/bin/true` (or `/bin/true`) → established
///    `.seatbelt`, exit 0
/// 5. `.opencode` + contained + absolute `touch` inside `ContainmentTree` →
///    file exists, seatbelt
/// 6. `.opencode` + contained + `touch` sibling path → seatbelt established,
///    file absent, exit ≠ 0
@Suite("HostLaunch")
struct HostLaunchTests {
    @Test func launch_nonOpenCode_fails() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let command = try requireTrueCommand()

        let isolation = try tree.requireContainedIsolation()
        expectHostUnsupported(
            launchContainedHost(host: .pi, command: command, plan: isolation)
        )
        expectHostUnsupported(
            launchContainedHost(host: .claude, command: command, plan: isolation)
        )
    }

    @Test func observedPlan_containedIsolation_fails() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        #expect(tree.observed.containedIsolation() == .failure(.notContained))
    }

    @Test func mediatedPlan_containedIsolation_fails() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let workspace = try #require(tree.contained.workspace)
        let mediated = try ContainmentTree.requirePlan(
            IsolationCompileRequest(requested: .mediated, workspace: workspace)
        )
        #expect(mediated.containedIsolation() == .failure(.notContained))
    }

    @Test func launch_containedTrue_establishes() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let command = try requireTrueCommand()
        let isolation = try tree.requireContainedIsolation()
        switch launchContainedHost(host: .opencode, command: command, plan: isolation) {
        case .success(let run):
            #if os(Linux)
            Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
            #else
            #expect(run.exitStatus == 0)
            expectContainedPlatform(run.established, matching: isolation.plan)
            #endif
        case .failure(let error):
            #if os(Linux)
            if case .apply(.containedGuaranteesUnsupported) = error {
                break
            }
            #endif
            recordUnexpectedHostLaunchError(error, expected: "contained true establish")
        }
    }

    @Test func launch_containedInWorkspaceTouch_succeeds() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let inside = tree.workspaceURL.appendingPathComponent("inside.txt").path
        let command = try requireTouchCommand(arguments: [inside])
        let isolation = try tree.requireContainedIsolation()
        switch launchContainedHost(host: .opencode, command: command, plan: isolation) {
        case .success(let run):
            #if os(Linux)
            Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
            #else
            #expect(run.exitStatus == 0)
            #expect(FileManager.default.fileExists(atPath: inside))
            expectContainedPlatform(run.established, matching: isolation.plan)
            #endif
        case .failure(let error):
            #if os(Linux)
            if case .apply(.containedGuaranteesUnsupported) = error {
                #expect(FileManager.default.fileExists(atPath: inside) == false)
                break
            }
            #endif
            recordUnexpectedHostLaunchError(error, expected: "in-workspace touch")
        }
    }

    @Test func launch_containedOutsideTouch_deniedByKernel() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let outside = tree.siblingURL.appendingPathComponent("outside.txt").path
        #expect(FileManager.default.fileExists(atPath: outside) == false)
        let command = try requireTouchCommand(arguments: [outside])
        let isolation = try tree.requireContainedIsolation()
        switch launchContainedHost(host: .opencode, command: command, plan: isolation) {
        case .success(let run):
            #if os(Linux)
            Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
            #else
            #expect(run.exitStatus != 0)
            #expect(FileManager.default.fileExists(atPath: outside) == false)
            expectContainedPlatform(run.established, matching: isolation.plan)
            #endif
        case .failure(let error):
            #if os(Linux)
            if case .apply(.containedGuaranteesUnsupported) = error {
                #expect(FileManager.default.fileExists(atPath: outside) == false)
                break
            }
            #endif
            recordUnexpectedHostLaunchError(
                error,
                expected: "blocked outside touch with established contained"
            )
        }
    }

    @Test func launch_containedSessionsAreDistinctFromHookSessionID() throws {
        #if os(macOS)
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let command = try requireTrueCommand()
        let isolation = try tree.requireContainedIsolation()
        let hook = try #require(SessionID(validating: "hook-session-must-not-be-runtime-id"))
        let first = try #require(
            launchContainedHost(host: .opencode, command: command, plan: isolation).get().session
        )
        let second = try #require(
            launchContainedHost(host: .opencode, command: command, plan: isolation).get().session
        )
        #expect(first.id != second.id)
        #expect(first.id.rawValue.uuidString != hook.rawValue)
        #expect(second.id.rawValue.uuidString != hook.rawValue)
        #expect(first.host == .opencode)
        #expect(second.host == .opencode)
        #expect(first.backend == .seatbelt)
        #expect((first.child?.pid ?? 0) > 1)
        #endif
    }

    @Test func launch_persistsSessionBeforeExecution() throws {
        #if os(macOS)
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let log = tree.rootURL.appendingPathComponent("sessions.jsonl")
        let command = try requireTrueCommand()
        let run = try IsolationBackends.applyLaunch(
            tree.contained,
            command: command,
            io: .discard,
            host: .opencode,
            sessionStore: .file(log)
        ).get()
        let session = try #require(run.session)
        let canonical = try #require(posixRealpath(tree.workspaceURL.path))
        let records = RuntimeSessionLog.records(at: log)
        let match = try #require(records.first { $0.id == session.id.rawValue })
        #expect(match.host == HookHost.opencode.rawValue)
        #expect(match.backend == RuntimeIsolationBackend.seatbelt.rawValue)
        #expect(match.workspace == canonical)
        #expect(match.workspace == session.workspace.rawValue)
        #expect(abs(match.startedAt.timeIntervalSince(session.startedAt)) < 0.001)
        #endif
    }
}

private enum HostLaunchFixtureError: Error {
    case missingTrue
    case missingTouch
}

private let safeTouchExecutables = ["/usr/bin/touch", "/bin/touch"]

private func requireTrueCommand() throws -> IsolatedCommand {
    for path in ["/usr/bin/true", "/bin/true"]
    where FileManager.default.isExecutableFile(atPath: path) {
        if let command = IsolatedCommand(executable: path) {
            return command
        }
    }
    Issue.record("neither /usr/bin/true nor /bin/true exists")
    throw HostLaunchFixtureError.missingTrue
}

private func requireTouchExecutable() throws -> String {
    for path in safeTouchExecutables where FileManager.default.fileExists(atPath: path) {
        return path
    }
    Issue.record("neither /usr/bin/touch nor /bin/touch exists")
    throw HostLaunchFixtureError.missingTouch
}

private func requireTouchCommand(arguments: [String]) throws -> IsolatedCommand {
    let executable = try requireTouchExecutable()
    return try #require(IsolatedCommand(executable: executable, arguments: arguments))
}

private func expectHostUnsupported(
    _ result: Result<IsolatedRunResult, HostLaunchError>,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch result {
    case .failure(.hostUnsupported):
        break
    case .failure(.apply(let error)):
        Issue.record(
            "non-OpenCode contained launch must not apply, got \(error)",
            sourceLocation: sourceLocation
        )
    case .success:
        Issue.record("non-OpenCode contained launch must not spawn", sourceLocation: sourceLocation)
    }
}

private func expectContainedPlatform(
    _ established: EstablishedIsolation,
    matching plan: IsolationPlan,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch plan.mode {
    case .contained:
        break
    case .observed:
        Issue.record("contained run must match a contained plan, not observed", sourceLocation: sourceLocation)
    case .mediated:
        Issue.record("contained run must match a contained plan, not mediated", sourceLocation: sourceLocation)
    }
    #if os(macOS)
    switch established {
    case .seatbelt(let session):
        #expect(session.backend == .seatbelt, sourceLocation: sourceLocation)
    case .observed:
        Issue.record("contained run must not establish observed", sourceLocation: sourceLocation)
    case .mediated:
        Issue.record("contained run must not establish mediated", sourceLocation: sourceLocation)
    }
    #elseif os(Linux)
    switch established {
    case .observed, .mediated, .seatbelt:
        Issue.record(
            "Linux contained success must not mint IsolatedRunResult",
            sourceLocation: sourceLocation
        )
    }
    #else
    Issue.record("first-slice host launch requires Darwin or Linux", sourceLocation: sourceLocation)
    switch established {
    case .observed, .mediated, .seatbelt:
        break
    }
    #endif
}

private func recordUnexpectedHostLaunchError(
    _ error: HostLaunchError,
    expected: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch error {
    case .hostUnsupported:
        Issue.record("expected \(expected), got hostUnsupported", sourceLocation: sourceLocation)
    case .apply(let apply):
        recordUnexpectedApplyError(apply, expected: expected, sourceLocation: sourceLocation)
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
