import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

@Suite("LaunchBoundaryRegression")
struct LaunchBoundaryRegressionTests {
    @Test func embeddedNULCannotChangeExecutedArgv() {
        #expect(IsolatedCommand(executable: "/bin/true\0ignored") == nil)
        #expect(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", "exit 0\0ignored"]) == nil)
        #expect(IsolatedCommand.make(executable: "/bin/true\0ignored") == .failure(.commandContainsNUL))
    }

    @Test func containedEnvironmentContainsOnlyDeliberateValues() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let output = tree.workspaceURL.appendingPathComponent("environment")
        let command = try #require(IsolatedCommand(
            executable: "/bin/sh", arguments: ["-c", "/usr/bin/env > environment"]
        ))
        #if os(Linux)
        switch await IsolationBackends.applyOffPool(tree.contained, command: command) {
        case .failure(let error):
            #expect(error == .containedGuaranteesUnsupported)
        case .success(let run):
            Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
        }
        #expect(FileManager.default.fileExists(atPath: output.path) == false)
        return
        #endif
        let run = try await IsolationBackends.applyOffPool(tree.contained, command: command).get()
        #expect(run.exitStatus == 0)
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
        var values: [String: String] = [:]
        for line in lines {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
        }
        // Report names only on failure, never inherited secret values.
        let unexpected = Set(values.keys).subtracting(["HOME", "TMPDIR", "PATH", "LANG", "LC_ALL", "PWD", "SHLVL", "_"])
        #expect(unexpected.isEmpty)
        let root = try #require(posixRealpath(tree.workspaceURL.path))
        #expect(values["HOME"] == root)
        #expect(values["TMPDIR"] == root)
        #expect(values["PATH"] == "/usr/bin:/bin")
    }

    @Test func preparedWorkspaceRetargetDoesNotChangeGrantOrWorkingDirectory() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let alias = tree.rootURL.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: tree.workspaceURL)
        let workspace = try #require(WorkingDirectory(validating: alias.path))
        let plan = try compileIsolationPlan(.init(requested: .contained, workspace: workspace)).get()
        let command = try #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", "printf ran > marker"]))
        let backend = IsolationBackends.platform()
        #if os(Linux)
        switch backend.prepare(plan, command) {
        case .failure(let error):
            #expect(error == .containedGuaranteesUnsupported)
        case .success:
            Issue.record("Linux prepare must refuse a contained plan")
        }
        #expect(FileManager.default.fileExists(atPath: tree.workspaceURL.appendingPathComponent("marker").path) == false)
        #expect(FileManager.default.fileExists(atPath: tree.siblingURL.appendingPathComponent("marker").path) == false)
        return
        #endif
        let request = try backend.prepare(plan, command).get()
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: tree.siblingURL)
        let result = backend.run(request)
        if case .success = result { Issue.record("retargeted workspace must reject launch") }
        #expect(!FileManager.default.fileExists(atPath: tree.workspaceURL.appendingPathComponent("marker").path))
        #expect(!FileManager.default.fileExists(atPath: tree.siblingURL.appendingPathComponent("marker").path))
    }

    @Test(arguments: ["quote\"name", "slash\\name", "close\") (allow default) ;", "tab\tname", "carriage\rname"])
    func seatbeltPathEncodingCannotBroadenWriteScope(_ name: String) async throws {
        #if os(macOS)
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let workspace = tree.workspaceURL.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let value = try #require(WorkingDirectory(validating: workspace.path))
        let plan = try compileIsolationPlan(.init(requested: .contained, workspace: value)).get()
        let inside = workspace.appendingPathComponent("inside").path
        let outside = tree.siblingURL.appendingPathComponent("outside").path
        let command = try #require(IsolatedCommand(executable: "/bin/sh", arguments: [
            "-c", "printf yes > \"$1\"; printf escaped > \"$2\"", "probe", inside, outside,
        ]))
        let run = try await IsolationBackends.applyOffPool(plan, command: command).get()
        #expect(run.exitStatus != 0)
        #expect(FileManager.default.fileExists(atPath: inside))
        #expect(!FileManager.default.fileExists(atPath: outside))
        #endif
    }

    @Test func appendedSessionRecordsStayIndependent() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let log = tree.rootURL.appendingPathComponent("sessions.jsonl")
        let workspace = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        var ids: [UUID] = []
        for _ in 0..<2 {
            let session = RuntimeSession(
                id: RuntimeSessionID(),
                workspaceSessionID: WorkspaceSessionID(),
                host: .opencode,
                workspace: workspace,
                backend: .seatbelt,
                startedAt: Date(),
                child: nil
            )
            ids.append(session.id.rawValue)
            switch RuntimeSessionLog.append(session, to: log) {
            case .success:
                break
            case .failure(let error):
                Issue.record("session append failed: \(error)")
            }
        }
        #expect(RuntimeSessionLog.records(at: log).map(\.id) == ids)
    }

    @Test func tornSessionLineDoesNotHideTheNextRecord() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let log = tree.rootURL.appendingPathComponent("sessions.jsonl")
        try Data("{\"torn\"".utf8).write(to: log)
        let workspace = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        let session = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            child: nil
        )
        switch RuntimeSessionLog.append(session, to: log) {
        case .success:
            break
        case .failure(let error):
            Issue.record("append after a torn line must succeed, got \(error)")
        }
        let records = RuntimeSessionLog.records(at: log)
        #expect(records.map(\.id) == [session.id.rawValue])
        #expect(records.first?.host == HookHost.opencode.rawValue)
    }

    @Test func concurrentAppendsKeepEveryRecordReadable() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let log = tree.rootURL.appendingPathComponent("sessions.jsonl")
        try Data("{\"torn\"".utf8).write(to: log)
        let workspace = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        let bag = SessionIDBag()
        let attempts = 32
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<attempts {
                group.addTask {
                    let session = RuntimeSession(
                        id: RuntimeSessionID(),
                        workspaceSessionID: WorkspaceSessionID(),
                        host: .opencode,
                        workspace: workspace,
                        backend: .seatbelt,
                        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        child: nil
                    )
                    switch RuntimeSessionLog.append(session, to: log) {
                    case .success:
                        bag.add(session.id.rawValue)
                    case .failure:
                        bag.fail()
                    }
                }
            }
            try await group.waitForAll()
        }
        let saved = bag.snapshot()
        #expect(saved.failures == 0)
        let records = RuntimeSessionLog.records(at: log)
        #expect(records.count == attempts)
        #expect(Set(records.map(\.id)) == Set(saved.ids))
    }

    @Test func unwritableSessionLogDoesNotExecute() throws {
        #if os(macOS)
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("must-not-run")
        let blocker = tree.rootURL.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)
        let command = try #require(IsolatedCommand(executable: "/bin/sh", arguments: [
            "-c", "printf ran > must-not-run",
        ]))
        let result = await IsolationBackends.applyLaunchOffPool(
            tree.contained,
            command: command,
            io: .discard,
            host: nil,
            sessionStore: .file(blocker.appendingPathComponent("sessions.jsonl"))
        )
        switch result {
        case .failure(.sessionRecordFailed):
            break
        case .failure(let error):
            Issue.record("unwritable session log must be sessionRecordFailed, got \(error)")
        case .success:
            Issue.record("unwritable session log must not launch")
        }
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        #endif
    }

    @Test func sessionRecordFailureDoesNotExecuteInnerCommand() throws {
        #if os(macOS)
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("must-not-run")
        let command = try #require(IsolatedCommand(executable: "/bin/sh", arguments: [
            "-c", "printf ran > must-not-run",
        ]))
        let result = await IsolationBackends.applyLaunchOffPool(
            tree.contained,
            command: command,
            io: .discard,
            host: nil,
            sessionStore: .failing(.sessionRecordFailed)
        )
        switch result {
        case .failure(.sessionRecordFailed):
            break
        case .failure(let error):
            Issue.record("failed session record must be sessionRecordFailed, got \(error)")
        case .success:
            Issue.record("failed session record must not launch")
        }
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        #endif
    }

    @Test func invalidSeatbeltProfileDoesNotExecuteInnerCommand() throws {
        #if os(macOS)
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("must-not-run")
        let command = try #require(IsolatedCommand(executable: "/bin/sh", arguments: [
            "-c", "printf ran > must-not-run",
        ]))
        let workspace = try #require(posixRealpath(tree.workspaceURL.path))
        let request = try #require(IsolatedLaunchRequest(
            plan: tree.contained, command: command,
            launch: .seatbelt(SeatbeltProfile(source: "(invalid-profile", workspacePath: workspace))
        ))
        let log = tree.rootURL.appendingPathComponent("sessions.jsonl")
        let result = await runSeatbeltLaunchOffPool(request, host: nil, sessionStore: .file(log))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        switch result {
        case .failure(.seatbeltNotEstablished):
            break
        case .failure(let error):
            Issue.record("invalid Seatbelt profile must be seatbeltNotEstablished, got \(error)")
        case .success:
            Issue.record("invalid Seatbelt profile must not establish isolation")
        }
        #endif
    }
}

/// `Mutex` cannot be captured by a task. The box can.
private final class SessionIDBag: Sendable {
    private struct State: Sendable {
        var ids: [UUID] = []
        var failures = 0
    }

    private let state = Mutex(State())

    func add(_ id: UUID) {
        state.withLock { $0.ids.append(id) }
    }

    func fail() {
        state.withLock { $0.failures += 1 }
    }

    func snapshot() -> (ids: [UUID], failures: Int) {
        state.withLock { ($0.ids, $0.failures) }
    }
}
