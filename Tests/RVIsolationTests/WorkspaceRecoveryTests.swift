#if canImport(Darwin)
import Darwin
#endif
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

#if os(macOS)
@Suite("Workspace recovery", .serialized)
struct WorkspaceRecoveryTests {
    @Test func cleanRecoveryDoesNotTouchTheProject() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let logs = RecoveryLogs(tree: tree)
        let directory = try workspace(tree)
        let outcome = WorkspaceRecovery.recover(directory, lifecycleLog: logs.life, runtimeLog: logs.runtime)
        #expect(outcome == .clean)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
        let names = try FileManager.default.contentsOfDirectory(atPath: tree.rootURL.path)
        #expect(names.contains { $0 == "workspace-gates" || $0 == "workspace-snapshots" } == false)
    }

    @Test func tornTrailingLineKeepsTheEarlierWorkspaceVisible() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let logs = RecoveryLogs(tree: tree)
        let id = UUID()
        let record = sampleRecord(kind: .created, id: id, path: tree.workspaceURL.path, at: 10)
        #expect(succeeded(WorkspaceLifecycleLog.append(record, to: logs.life)))
        try appendRaw("{\"torn\"", to: logs.life)
        guard case .decoded(let read) = WorkspaceLifecycleLog.load(at: logs.life) else {
            Issue.record("torn log must stay readable")
            return
        }
        #expect(read.tornTrailing)
        #expect(read.records.contains { $0.workspace == id && $0.kind == .created })
        let assessment = WorkspaceRecovery.assess(try workspace(tree), lifecycleLog: logs.life, runtimeLog: logs.runtime)
        #expect(assessment != .clean)
    }

    @Test func tornLineAloneIsNotACleanHistory() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let logs = RecoveryLogs(tree: tree)
        try Data("{\"torn\"".utf8).write(to: logs.life)
        let assessment = WorkspaceRecovery.assess(try workspace(tree), lifecycleLog: logs.life, runtimeLog: logs.runtime)
        guard case .blocked(let block) = assessment else {
            Issue.record("a torn log must not look clean, got \(assessment)")
            return
        }
        #expect(block.reason == .tornLog)
        let recovered = WorkspaceRecovery.recover(try workspace(tree), lifecycleLog: logs.life, runtimeLog: logs.runtime)
        #expect(recovered == .blocked(block))
    }

    @Test func closedHistoryWithATornTailIsNotClean() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let logs = RecoveryLogs(tree: tree)
        let id = UUID()
        let path = tree.workspaceURL.path
        #expect(succeeded(WorkspaceLifecycleLog.append(sampleRecord(kind: .created, id: id, path: path, at: 10), to: logs.life)))
        #expect(succeeded(WorkspaceLifecycleLog.append(sampleRecord(kind: .closed, id: id, path: path, at: 11), to: logs.life)))
        try appendRaw("{\"next\"", to: logs.life)
        let assessment = WorkspaceRecovery.assess(try workspace(tree), lifecycleLog: logs.life, runtimeLog: logs.runtime)
        guard case .blocked(let block) = assessment else {
            Issue.record("torn tail after close must not look clean, got \(assessment)")
            return
        }
        #expect(block.reason == .tornLog)
    }

    @Test func reusedProcessGroupIsNotKilled() throws {
        let pid = try spawnGroupSleep()
        defer { _ = kill(-pid, SIGKILL) }
        let fact = try #require(ProcessGroupRecovery.capture(pid: pid))
        let wrong = RecordedProcessGroup(
            runtime: UUID(),
            pgid: fact.pgid,
            startSeconds: fact.startSeconds &+ 50,
            startMicroseconds: fact.startMicroseconds
        )
        #expect(succeeded(ProcessGroupRecovery.terminate(wrong)))
        #expect(kill(pid, 0) == 0)
        let initGroup = RecordedProcessGroup(runtime: UUID(), pgid: 1, startSeconds: 0, startMicroseconds: 0)
        let stopped = ProcessGroupRecovery.terminate(initGroup)
        if case .failure(.refusedIdentity) = stopped {
        } else {
            Issue.record("pid 1 must not be signalled, got \(stopped)")
        }
        if kill(1, 0) != 0 {
            #expect(errno == EPERM)
        }
    }

    @Test func provenProcessGroupIsKilled() throws {
        let pid = try spawnGroupSleep()
        let fact = try #require(ProcessGroupRecovery.capture(pid: pid))
        let owned = RecordedProcessGroup(
            runtime: UUID(),
            pgid: fact.pgid,
            startSeconds: fact.startSeconds,
            startMicroseconds: fact.startMicroseconds
        )
        #expect(succeeded(ProcessGroupRecovery.terminate(owned)))
        #expect(waitUntil(seconds: 5) {
            var status: Int32 = 0
            return waitpid(pid, &status, WNOHANG) == pid || processIsGone(pid)
        })
    }

    @Test func liveOwnerRefusesASecondWorkspace() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let logs = RecoveryLogs(tree: tree)
        let opened = try openWorkspace(tree, logs: logs)
        defer { _ = opened.supervisor.close() }
        let running = try launch(opened, script: "printf owned > owned.txt; /bin/sleep 30")
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("owned.txt")))
        let pid = try #require(running.session.child?.pid)
        switch WorkspaceSessionSupervisor.open(
            try workspace(tree),
            lifecycleLog: .file(logs.life),
            runtimeLog: logs.runtime
        ) {
        case .failure(.ownedByLiveProcess(let id)):
            #expect(id == opened.supervisor.id.rawValue)
        case .failure(let error):
            Issue.record("live owner must refuse, got \(error)")
        case .success:
            Issue.record("live owner must refuse a second workspace")
        }
        #expect(kill(pid, 0) == 0)
        #expect(savedNames(in: tree).count == 1)
        #expect(opened.supervisor.snapshot.phase == .active)
    }

    @Test func orphanWithoutAChildPreservesTheNewFileAndMintsANewWorkspace() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let logs = RecoveryLogs(tree: tree)
        let opened = try openWorkspace(tree, logs: logs)
        let oldID = opened.supervisor.id.rawValue
        let device = opened.supervisor.volumeDevice
        _ = try launch(opened, script: "printf preserved > only-on-volume.txt")
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("only-on-volume.txt")))
        #expect(waitUntil(seconds: 10) { ended(oldID, in: logs.life) })
        opened.supervisor.abandonForCrashSimulation()
        let reopened = try WorkspaceSessionSupervisor.open(
            try workspace(tree),
            lifecycleLog: .file(logs.life),
            runtimeLog: logs.runtime
        ).get()
        defer { _ = reopened.close() }
        #expect(reopened.id.rawValue != oldID)
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("only-on-volume.txt"), encoding: .utf8) == "preserved")
        let records = WorkspaceLifecycleLog.records(at: logs.life)
        #expect(records.contains { $0.workspace == oldID && $0.kind == .recoveryCompleted })
        #expect(records.contains { $0.workspace == oldID && $0.kind == .closed })
        #expect(records.contains { $0.workspace == reopened.id.rawValue && $0.kind == .created })
        #expect(records.contains { $0.kind == .recoveryBegan && $0.workspace == reopened.id.rawValue } == false)
        #expect(succeeded(reopened.close()))
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("only-on-volume.txt"), encoding: .utf8) == "preserved")
        #expect(savedNames(in: tree).isEmpty)
        #expect(workspacePathIdentity(tree.workspaceURL.path)?.device != device)
        #expect(WorkspaceRecovery.recover(try workspace(tree), lifecycleLog: logs.life, runtimeLog: logs.runtime) == .clean)
    }

    @Test func liveChildDiesBeforePublish() throws {
        let tree = try ContainmentTree()
        defer { cleanupVolume(in: tree) }
        let logs = RecoveryLogs(tree: tree)
        let opened = try openWorkspace(tree, logs: logs)
        let running = try launch(opened, script: "printf preserved > only-on-volume.txt; /bin/sleep 60")
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("only-on-volume.txt")))
        let pid = try #require(running.session.child?.pid)
        let created = try createdRecord(logs.life, workspace: opened.supervisor.id.rawValue)
        opened.supervisor.abandonForCrashSimulation()
        let interrupted = WorkspaceRecovery.recover(
            try workspace(tree),
            lifecycleLog: logs.life,
            runtimeLog: logs.runtime,
            fault: WorkspaceRecoveryFault(boundary: .afterChildTeardown)
        )
        #expect(interrupted == .interrupted(.afterChildTeardown))
        #expect(waitUntil(seconds: 5) { processIsGone(pid) })
        let savedFile = try #require(created.identity).savedPath.appendingPath("only-on-volume.txt")
        #expect(FileManager.default.fileExists(atPath: savedFile) == false)
        #expect(FileManager.default.fileExists(atPath: tree.workspaceURL.appendingPathComponent("only-on-volume.txt").path))
        let finished = WorkspaceRecovery.recover(try workspace(tree), lifecycleLog: logs.life, runtimeLog: logs.runtime)
        #expect(finished == .recovered(opened.supervisor.id.rawValue))
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("only-on-volume.txt"), encoding: .utf8) == "preserved")
        #expect(processIsGone(pid))
    }

    @Test func publicationConflictKeepsBothCopies() throws {
        let tree = try ContainmentTree()
        defer { cleanupVolume(in: tree) }
        try Data("before\n".utf8).write(to: tree.workspaceURL.appendingPathComponent("original.txt"))
        let logs = RecoveryLogs(tree: tree)
        let opened = try openWorkspace(tree, logs: logs)
        _ = try launch(opened, script: "printf 'after\\n' > original.txt; printf vol > only-on-volume.txt")
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("only-on-volume.txt")))
        let created = try createdRecord(logs.life, workspace: opened.supervisor.id.rawValue)
        let savedFile = try #require(created.identity).savedPath.appendingPath("original.txt")
        #expect(unlink(savedFile) == 0)
        try Data("replaced".utf8).write(to: URL(fileURLWithPath: savedFile))
        let device = opened.supervisor.volumeDevice
        opened.supervisor.abandonForCrashSimulation()
        let outcome = WorkspaceRecovery.recover(try workspace(tree), lifecycleLog: logs.life, runtimeLog: logs.runtime)
        guard case .blocked(let block) = outcome else {
            Issue.record("conflict must block, got \(outcome)")
            return
        }
        #expect(block.reason == .publicationConflict)
        #expect(block.workspace == opened.supervisor.id.rawValue)
        #expect(workspacePathIdentity(tree.workspaceURL.path)?.device == device)
        #expect(FileManager.default.fileExists(atPath: tree.workspaceURL.appendingPathComponent("only-on-volume.txt").path))
        #expect(FileManager.default.fileExists(atPath: savedFile))
        #expect(WorkspaceRecovery.recover(try workspace(tree), lifecycleLog: logs.life, runtimeLog: logs.runtime) == outcome)
        switch WorkspaceSessionSupervisor.open(
            try workspace(tree),
            lifecycleLog: .file(logs.life),
            runtimeLog: logs.runtime
        ) {
        case .failure(.unresolvedWorkspace(let refusal)):
            #expect(refusal.reason == .publicationConflict)
        case .failure(let error):
            Issue.record("unresolved workspace must refuse open, got \(error)")
        case .success:
            Issue.record("unresolved workspace must refuse open")
        }
    }

    @Test func missingMountStaysUnresolved() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let logs = RecoveryLogs(tree: tree)
        let opened = try openWorkspace(tree, logs: logs)
        let created = try createdRecord(logs.life, workspace: opened.supervisor.id.rawValue)
        let identity = try #require(created.identity)
        opened.supervisor.abandonForCrashSimulation()
        detach(identity.disk)
        #expect(waitUntil(seconds: 5) {
            workspacePathIdentity(tree.workspaceURL.path)?.device != identity.volumeDevice
        })
        let outcome = WorkspaceRecovery.recover(try workspace(tree), lifecycleLog: logs.life, runtimeLog: logs.runtime)
        guard case .blocked(let block) = outcome else {
            Issue.record("missing mount must block, got \(outcome)")
            return
        }
        #expect(block.reason == .missingVolume)
        let closed = WorkspaceLifecycleLog.records(at: logs.life).contains {
            $0.kind == .closed && $0.workspace == opened.supervisor.id.rawValue
        }
        #expect(closed == false)
        #expect(FileManager.default.fileExists(atPath: identity.savedPath))
        #expect(WorkspaceRecovery.recover(try workspace(tree), lifecycleLog: logs.life, runtimeLog: logs.runtime) == outcome)
    }

    @Test func unrelatedMountIsNotDetached() throws {
        let tree = try ContainmentTree()
        defer { cleanupVolume(in: tree) }
        let logs = RecoveryLogs(tree: tree)
        let opened = try openWorkspace(tree, logs: logs)
        let device = opened.supervisor.volumeDevice
        let created = try createdRecord(logs.life, workspace: opened.supervisor.id.rawValue)
        opened.supervisor.abandonForCrashSimulation()
        let tampered = tree.rootURL.appendingPathComponent("tampered.jsonl")
        try tamper(logs.life, into: tampered) { object in
            object["volumeDevice"] = 1
            var identity = object["identity"] as? [String: Any] ?? [:]
            identity["volumeDevice"] = 1
            identity["mountSource"] = "/dev/disk-not-rv"
            object["identity"] = identity
        }
        let outcome = WorkspaceRecovery.recover(try workspace(tree), lifecycleLog: tampered, runtimeLog: logs.runtime)
        guard case .blocked(let block) = outcome else {
            Issue.record("unrelated mount must block, got \(outcome)")
            return
        }
        #expect(block.reason == .unrelatedMount || block.reason == .ambiguousOwnership)
        #expect(workspacePathIdentity(tree.workspaceURL.path)?.device == device)
        #expect(FileManager.default.fileExists(atPath: try #require(created.identity).savedPath))
    }

    @Test func unrelatedSavedTreeIsNotRestored() throws {
        let tree = try ContainmentTree()
        defer { cleanupVolume(in: tree) }
        let logs = RecoveryLogs(tree: tree)
        let opened = try openWorkspace(tree, logs: logs)
        let created = try createdRecord(logs.life, workspace: opened.supervisor.id.rawValue)
        let saved = try #require(created.identity).savedPath
        let device = opened.supervisor.volumeDevice
        opened.supervisor.abandonForCrashSimulation()
        let tampered = tree.rootURL.appendingPathComponent("tampered-saved.jsonl")
        try tamper(logs.life, into: tampered) { object in
            var identity = object["identity"] as? [String: Any] ?? [:]
            identity["savedInode"] = 1
            object["identity"] = identity
        }
        let outcome = WorkspaceRecovery.recover(try workspace(tree), lifecycleLog: tampered, runtimeLog: logs.runtime)
        guard case .blocked(let block) = outcome else {
            Issue.record("unrelated saved tree must block, got \(outcome)")
            return
        }
        #expect(block.reason == .ambiguousSavedTree || block.reason == .ambiguousOwnership)
        #expect(FileManager.default.fileExists(atPath: saved))
        #expect(workspacePathIdentity(tree.workspaceURL.path)?.device == device)
    }

    @Test(arguments: [
        WorkspaceRecoveryFault.Boundary.afterChildTeardown,
        .afterPublish,
        .afterUnmount,
        .afterOriginalRestoration,
        .beforeTerminalAppend,
    ])
    func partialRecoveryConverges(_ boundary: WorkspaceRecoveryFault.Boundary) throws {
        let tree = try ContainmentTree()
        defer { cleanupVolume(in: tree) }
        let logs = RecoveryLogs(tree: tree)
        let opened = try openWorkspace(tree, logs: logs)
        let id = opened.supervisor.id.rawValue
        _ = try launch(opened, script: "printf preserved > only-on-volume.txt")
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("only-on-volume.txt")))
        #expect(waitUntil(seconds: 10) { ended(id, in: logs.life) })
        let created = try createdRecord(logs.life, workspace: id)
        let identity = try #require(created.identity)
        let savedFile = identity.savedPath.appendingPath("only-on-volume.txt")
        opened.supervisor.abandonForCrashSimulation()
        let first = WorkspaceRecovery.recover(
            try workspace(tree),
            lifecycleLog: logs.life,
            runtimeLog: logs.runtime,
            fault: WorkspaceRecoveryFault(boundary: boundary)
        )
        #expect(first == .interrupted(boundary))
        switch boundary {
        case .afterChildTeardown:
            #expect(FileManager.default.fileExists(atPath: savedFile) == false)
            #expect(FileManager.default.fileExists(atPath: tree.workspaceURL.appendingPathComponent("only-on-volume.txt").path))
        case .afterPublish:
            #expect(FileManager.default.fileExists(atPath: savedFile))
            #expect(workspacePathIdentity(tree.workspaceURL.path)?.device == identity.volumeDevice)
        case .afterUnmount:
            #expect(FileManager.default.fileExists(atPath: savedFile))
            #expect(workspacePathIdentity(tree.workspaceURL.path)?.device != identity.volumeDevice)
        case .afterOriginalRestoration, .beforeTerminalAppend:
            #expect(FileManager.default.fileExists(atPath: savedFile) == false)
            #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("only-on-volume.txt"), encoding: .utf8) == "preserved")
        }
        let finishedEarly = WorkspaceLifecycleLog.records(at: logs.life).contains {
            $0.kind == .recoveryCompleted && $0.workspace == id
        }
        #expect(finishedEarly == false)
        #expect(WorkspaceRecovery.recover(try workspace(tree), lifecycleLog: logs.life, runtimeLog: logs.runtime) == .recovered(id))
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("only-on-volume.txt"), encoding: .utf8) == "preserved")
        #expect(WorkspaceRecovery.recover(try workspace(tree), lifecycleLog: logs.life, runtimeLog: logs.runtime) == .clean)
    }

    @Test func canonicalAliasCannotOpenASecondWorkspace() throws {
        let tree = try ContainmentTree()
        defer { cleanupVolume(in: tree) }
        let logs = RecoveryLogs(tree: tree)
        let opened = try openWorkspace(tree, logs: logs)
        let oldID = opened.supervisor.id.rawValue
        _ = try launch(opened, script: "printf preserved > only-on-volume.txt")
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("only-on-volume.txt")))
        opened.supervisor.abandonForCrashSimulation()
        let alias = tree.rootURL.appendingPathComponent("alias-ws")
        #expect(symlink(tree.workspaceURL.path, alias.path) == 0)
        let directory = try #require(WorkingDirectory(validating: alias.path))
        let reopened = try WorkspaceSessionSupervisor.open(
            directory,
            lifecycleLog: .file(logs.life),
            runtimeLog: logs.runtime
        ).get()
        defer { _ = reopened.close() }
        #expect(reopened.id.rawValue != oldID)
        #expect(savedNames(in: tree).count == 1)
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("only-on-volume.txt"), encoding: .utf8) == "preserved")
        #expect(WorkspaceLifecycleLog.records(at: logs.life).contains { $0.workspace == oldID && $0.kind == .closed })
    }

    @Test func oldCapabilityCannotRunInTheNextWorkspace() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let logs = RecoveryLogs(tree: tree)
        let opened = try openWorkspace(tree, logs: logs)
        let running = try launch(opened, script: "/bin/sleep 30")
        let oldCapability = running.capability
        let oldRuntime = running.id
        let pid = try #require(running.session.child?.pid)
        #expect(waitUntil(seconds: 5) { kill(pid, 0) == 0 })
        opened.supervisor.abandonForCrashSimulation()
        let reopened = try WorkspaceSessionSupervisor.open(
            try workspace(tree),
            lifecycleLog: .file(logs.life),
            runtimeLog: logs.runtime
        ).get()
        defer { _ = reopened.close() }
        #expect(reopened.id != opened.supervisor.id)
        let stale = reopened.submit(recoveryFrame("sleep 1", capability: oldCapability, claim: oldRuntime), to: oldRuntime)
        #expect(stale == nil)
        let fresh = try launch(
            RecoveryOpen(supervisor: reopened, runtimeLog: logs.runtime, lifeLog: logs.life),
            script: "/bin/sleep 30"
        )
        #expect(fresh.id != oldRuntime)
        let rejected = reopened.submit(
            recoveryFrame("sleep 1", capability: oldCapability, claim: fresh.id),
            to: fresh.id
        )
        #expect(rejected?.response == .rejected(.invalidCapability))
        #expect(rejected?.execute == nil)
    }

    @Test func normalCloseDoesNotRecordRecovery() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let logs = RecoveryLogs(tree: tree)
        let opened = try openWorkspace(tree, logs: logs)
        defer { _ = opened.supervisor.close() }
        _ = try launch(opened, script: "printf ok > done.txt")
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("done.txt")))
        #expect(succeeded(opened.supervisor.close()))
        let kinds = Set(WorkspaceLifecycleLog.records(at: logs.life).map(\.kind))
        #expect(kinds.contains(.created))
        #expect(kinds.contains(.closed))
        #expect(kinds.contains(.recoveryBegan) == false)
        #expect(kinds.contains(.recoveryCompleted) == false)
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("done.txt"), encoding: .utf8) == "ok")
    }
}

private struct RecoveryLogs {
    var life: URL
    var runtime: URL

    init(tree: ContainmentTree) {
        life = tree.rootURL.appendingPathComponent("workspace-sessions.jsonl")
        runtime = tree.rootURL.appendingPathComponent("runtime-sessions.jsonl")
    }
}

private struct RecoveryOpen {
    var supervisor: WorkspaceSessionSupervisor
    var runtimeLog: URL
    var lifeLog: URL
}

private func openWorkspace(_ tree: ContainmentTree, logs: RecoveryLogs) throws -> RecoveryOpen {
    let supervisor = try WorkspaceSessionSupervisor.open(
        try workspace(tree),
        lifecycleLog: .file(logs.life),
        runtimeLog: logs.runtime
    ).get()
    return RecoveryOpen(supervisor: supervisor, runtimeLog: logs.runtime, lifeLog: logs.life)
}

private func workspace(_ tree: ContainmentTree) throws -> WorkingDirectory {
    try #require(WorkingDirectory(validating: tree.workspaceURL.path))
}

private func launch(_ opened: RecoveryOpen, script: String) throws -> RunningRuntime {
    try opened.supervisor.launch(
        host: .opencode,
        command: try #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", script])),
        plan: compileContainedPlan(workspace: opened.supervisor.snapshot.policyWorkspace),
        io: .discard,
        admission: .failClosed,
        sessionStore: .file(opened.runtimeLog)
    ).get()
}

private func sampleRecord(kind: WorkspaceLifecycleRecord.Kind, id: UUID, path: String, at time: TimeInterval) -> WorkspaceLifecycleRecord {
    WorkspaceLifecycleRecord(
        kind: kind,
        workspace: id,
        originalPath: path,
        protectedPath: path,
        volumeDevice: 1,
        disk: "/dev/disk9",
        runtime: nil,
        recordedAt: Date(timeIntervalSince1970: time)
    )
}

private func createdRecord(_ log: URL, workspace: UUID) throws -> WorkspaceLifecycleRecord {
    try #require(WorkspaceLifecycleLog.records(at: log).first { $0.workspace == workspace && $0.kind == .created })
}

private func ended(_ workspace: UUID, in log: URL) -> Bool {
    WorkspaceLifecycleLog.records(at: log).contains { $0.kind == .runtimeEnded && $0.workspace == workspace }
}

private func savedNames(in tree: ContainmentTree) -> [String] {
    let parent = tree.workspaceURL.deletingLastPathComponent().path
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
    return names.filter { $0.hasPrefix(".rv-saved-") }
}

private func waitFor(_ url: URL) -> Bool {
    waitUntil(seconds: 20) { FileManager.default.fileExists(atPath: url.path) }
}

private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

private func succeeded<T>(_ result: Result<T, some Error>) -> Bool {
    if case .success = result { return true }
    return false
}

private func appendRaw(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

private extension String {
    func appendingPath(_ name: String) -> String {
        (self as NSString).appendingPathComponent(name)
    }
}

private func tamper(_ source: URL, into destination: URL, _ mutate: (inout [String: Any]) -> Void) throws {
    let text = try String(contentsOf: source, encoding: .utf8)
    var output = Data()
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        var object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        if object["kind"] as? String == "created" {
            mutate(&object)
        }
        output.append(try JSONSerialization.data(withJSONObject: object))
        output.append(UInt8(ascii: "\n"))
    }
    try output.write(to: destination)
}

private func detach(_ disk: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = ["detach", "-force", "-quiet", disk]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

private func cleanupVolume(in tree: ContainmentTree) {
    let logURL = tree.rootURL.appendingPathComponent("workspace-sessions.jsonl")
    if let identity = workspacePathIdentity(tree.workspaceURL.path),
        let log = try? String(contentsOf: logURL, encoding: .utf8)
    {
        for line in log.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                object["kind"] as? String == "created",
                let nested = object["identity"] as? [String: Any],
                let disk = nested["disk"] as? String,
                let recorded = nested["volumeDevice"] as? UInt64,
                identity.device == recorded
            else { continue }
            detach(disk)
        }
    }
    tree.tearDown()
}

private func spawnGroupSleep() throws -> pid_t {
    var attributes: posix_spawnattr_t?
    try #require(posix_spawnattr_init(&attributes) == 0)
    defer { posix_spawnattr_destroy(&attributes) }
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    try #require(posix_spawnattr_setflags(&attributes, flags) == 0)
    try #require(posix_spawnattr_setpgroup(&attributes, 0) == 0)
    let arguments = ["/bin/sleep", "60"]
    let pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    var argv = pointers
    argv.append(nil)
    var pid: pid_t = 0
    let spawned = argv.withUnsafeMutableBufferPointer { buffer -> Int32 in
        guard let base = buffer.baseAddress else { return -1 }
        return posix_spawn(&pid, "/bin/sleep", nil, &attributes, base, environ)
    }
    try #require(spawned == 0)
    try #require(pid > 1)
    return pid
}

private func recoveryFrame(
    _ command: String,
    capability: RuntimeCapability,
    claim: RuntimeSessionID
) -> RuntimeActionFrame {
    RuntimeActionFrame(
        version: 1,
        requestID: RuntimeActionRequestID(validating: UUID().uuidString)!,
        capability: capability,
        claimedSession: RuntimeSessionClaim(validating: claim.rawValue.uuidString)!,
        action: .shell(ShellCommand(rawValue: command))
    )
}
#endif
