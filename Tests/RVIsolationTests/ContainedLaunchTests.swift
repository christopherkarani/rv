import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Executor-internal contained launch edges (`IsolationBackends.applyLaunch`).
///
/// This is the `LocalExecutor` / admitted-command door, not an interactive
/// path: no CLI command reaches it. Interactive launches go through the
/// workspace host (`WorkspaceHostTests`, `RuntimeTerminalTests`).
/// 1. Contained + `/usr/bin/true` (or `/bin/true`) → established `.seatbelt`, exit 0
/// 2. Contained + absolute `touch` inside `ContainmentTree` → file exists, seatbelt
/// 3. Contained + `touch` sibling path → seatbelt established, file absent, exit ≠ 0
/// 4. Two contained launches mint distinct runtime sessions, never the hook id
/// 5. The session record lands before execution with host/backend/workspace
@Suite("ContainedLaunch")
struct ContainedLaunchTests {
    @Test func launch_containedTrue_establishes() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let command = try requireTrueCommand()
        let plan = try tree.containedPlan()
        switch await IsolationBackends.applyLaunchOffPool(
            plan.isolationPlan(),
            command: command,
            io: .discard,
            host: .opencode,
            sessionStore: .production
        ) {
        case .success(let run):
            #if os(Linux)
            Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
            #else
            #expect(run.exitStatus == 0)
            expectContainedPlatform(run.established, matching: plan.isolationPlan())
            #endif
        case .failure(let error):
            #if os(Linux)
            if error == .containedGuaranteesUnsupported {
                return
            }
            #endif
            recordUnexpectedApplyError(error, expected: "contained true establish")
        }
    }

    @Test func launch_containedInWorkspaceTouch_succeeds() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let inside = tree.workspaceURL.appendingPathComponent("inside.txt").path
        let command = try requireTouchCommand(arguments: [inside])
        let plan = try tree.containedPlan()
        switch await IsolationBackends.applyLaunchOffPool(
            plan.isolationPlan(),
            command: command,
            io: .discard,
            host: .opencode,
            sessionStore: .production
        ) {
        case .success(let run):
            #if os(Linux)
            Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
            #else
            #expect(run.exitStatus == 0)
            #expect(FileManager.default.fileExists(atPath: inside))
            expectContainedPlatform(run.established, matching: plan.isolationPlan())
            #endif
        case .failure(let error):
            #if os(Linux)
            if error == .containedGuaranteesUnsupported {
                #expect(FileManager.default.fileExists(atPath: inside) == false)
                return
            }
            #endif
            recordUnexpectedApplyError(error, expected: "in-workspace touch")
        }
    }

    @Test func launch_containedOutsideTouch_deniedByKernel() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let outside = tree.siblingURL.appendingPathComponent("outside.txt").path
        #expect(FileManager.default.fileExists(atPath: outside) == false)
        let command = try requireTouchCommand(arguments: [outside])
        let plan = try tree.containedPlan()
        switch await IsolationBackends.applyLaunchOffPool(
            plan.isolationPlan(),
            command: command,
            io: .discard,
            host: .opencode,
            sessionStore: .production
        ) {
        case .success(let run):
            #if os(Linux)
            Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
            #else
            #expect(run.exitStatus != 0)
            #expect(FileManager.default.fileExists(atPath: outside) == false)
            expectContainedPlatform(run.established, matching: plan.isolationPlan())
            #endif
        case .failure(let error):
            #if os(Linux)
            if error == .containedGuaranteesUnsupported {
                #expect(FileManager.default.fileExists(atPath: outside) == false)
                return
            }
            #endif
            recordUnexpectedApplyError(
                error,
                expected: "blocked outside touch with established contained"
            )
        }
    }

    @Test func launch_containedSessionsAreDistinctFromHookSessionID() async throws {
        #if os(macOS)
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let command = try requireTrueCommand()
        let plan = try tree.containedPlan()
        let hook = try #require(SessionID(validating: "hook-session-must-not-be-runtime-id"))
        let firstSession = try await IsolationBackends.applyLaunchOffPool(
            plan.isolationPlan(),
            command: command,
            io: .discard,
            host: .opencode,
            sessionStore: .production
        ).get().session
        let secondSession = try await IsolationBackends.applyLaunchOffPool(
            plan.isolationPlan(),
            command: command,
            io: .discard,
            host: .opencode,
            sessionStore: .production
        ).get().session
        let first = try #require(firstSession)
        let second = try #require(secondSession)
        #expect(first.id != second.id)
        #expect(first.id.rawValue.uuidString != hook.rawValue)
        #expect(second.id.rawValue.uuidString != hook.rawValue)
        #expect(first.host == .opencode)
        #expect(second.host == .opencode)
        #expect(first.backend == .seatbelt)
        #expect((first.child?.pid ?? 0) > 1)
        #endif
    }

    @Test func launch_persistsSessionBeforeExecution() async throws {
        #if os(macOS)
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let log = tree.rootURL.appendingPathComponent("sessions.jsonl")
        let command = try requireTrueCommand()
        let run = try await IsolationBackends.applyLaunchOffPool(
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

private enum ContainedLaunchFixtureError: Error {
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
    throw ContainedLaunchFixtureError.missingTrue
}

private func requireTouchExecutable() throws -> String {
    for path in safeTouchExecutables where FileManager.default.fileExists(atPath: path) {
        return path
    }
    Issue.record("neither /usr/bin/touch nor /bin/touch exists")
    throw ContainedLaunchFixtureError.missingTouch
}

private func requireTouchCommand(arguments: [String]) throws -> IsolatedCommand {
    let executable = try requireTouchExecutable()
    return try #require(IsolatedCommand(executable: executable, arguments: arguments))
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
    Issue.record("first-slice contained launch requires Darwin or Linux", sourceLocation: sourceLocation)
    switch established {
    case .observed, .mediated, .seatbelt:
        break
    }
    #endif
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
    case .resourceStagingFailed(let detail):
        Issue.record("expected \(expected), got resourceStagingFailed(\(detail))", sourceLocation: sourceLocation)
    case .processSpawnFailed:
        Issue.record("expected \(expected), got processSpawnFailed", sourceLocation: sourceLocation)
    case .commandContainsNUL:
        Issue.record("unexpected NUL command rejection", sourceLocation: sourceLocation)
    case .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceUnresolved:
        Issue.record(
            "expected \(expected), got commandExecutableMustBeAbsolute",
            sourceLocation: sourceLocation
        )
    }
}
