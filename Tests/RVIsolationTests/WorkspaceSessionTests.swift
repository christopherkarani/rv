#if canImport(Darwin)
import Darwin
#endif
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

#if os(macOS)
@Suite("WorkspaceSession", .serialized)
struct WorkspaceSessionTests {
    @Test func twoWorkspacesMintDifferentIDs() throws {
        let firstTree = try ContainmentTree()
        defer { firstTree.tearDown() }
        let secondTree = try ContainmentTree()
        defer { secondTree.tearDown() }
        let first = try openWorkspace(firstTree)
        defer { _ = first.supervisor.close() }
        let second = try openWorkspace(secondTree)
        defer { _ = second.supervisor.close() }
        #expect(first.supervisor.id != second.supervisor.id)
        #expect(first.supervisor.snapshot.phase == .active)
        #expect(second.supervisor.snapshot.phase == .active)
        #expect(first.supervisor.snapshot.originalPath == first.supervisor.snapshot.protectedPath)
        let firstClosed = first.supervisor.close()
        let secondClosed = second.supervisor.close()
        #expect(succeeded(firstClosed))
        #expect(succeeded(secondClosed))
        #expect(first.supervisor.snapshot.phase == .closed)
        #expect(second.supervisor.snapshot.phase == .closed)
        #expect(first.supervisor.publishCount == 1)
        #expect(second.supervisor.publishCount == 1)
        #expect(succeeded(first.supervisor.close()))
        #expect(first.supervisor.publishCount == 1)
    }

    @Test func runtimesShareTheWorkspaceAndNotTheCapability() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let supervisor = opened.supervisor
        let device = supervisor.volumeDevice
        let parent = tree.workspaceURL.deletingLastPathComponent().path
        let aCounter = RunCounter()
        let bCounter = RunCounter()
        let a = try launch(
            supervisor,
            tree: tree,
            log: opened.runtimeLog,
            admission: countingAdmission(aCounter),
            script: "printf from-a > from-a.txt; /bin/sleep 30"
        )
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("from-a.txt")))
        let savedAfterFirst = savedNames(in: parent)
        let b = try launch(
            supervisor,
            tree: tree,
            log: opened.runtimeLog,
            admission: countingAdmission(bCounter),
            script: """
            cat from-a.txt > seen-a.txt
            printf from-b > from-b.txt
            /bin/sleep 30
            """
        )
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("seen-a.txt")))
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("from-b.txt")))
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("seen-a.txt"), encoding: .utf8) == "from-a")
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("from-b.txt"), encoding: .utf8) == "from-b")
        #expect(a.id != b.id)
        #expect(a.session.workspaceSessionID == supervisor.id)
        #expect(b.session.workspaceSessionID == supervisor.id)
        #expect(a.capability.rawValue != b.capability.rawValue)
        let pidA = try #require(a.session.child?.pid)
        let pidB = try #require(b.session.child?.pid)
        #expect(pidA != pidB)
        #expect(getpgid(pidA) == pidA)
        #expect(getpgid(pidB) == pidB)
        #expect(supervisor.volumeDevice == device)
        #expect(savedNames(in: parent) == savedAfterFirst)
        #expect(savedNames(in: parent).count == 1)
        let outside = tree.siblingURL.appendingPathComponent("secret")
        try Data("secret".utf8).write(to: outside)
        let linkResult = outside.path.withCString { source in
            tree.workspaceURL.appendingPathComponent("alias").path.withCString { destination in
                link(source, destination)
            }
        }
        #expect(linkResult != 0)
        #expect(errno == EXDEV)

        let request = UUID()
        let impersonated = supervisor.submit(
            frame("touch marker", capability: a.capability, claim: b.id, runtime: a.id, id: request),
            to: a.id
        )
        #expect(impersonated?.response == .rejected(.impersonation))
        #expect(impersonated?.execute == nil)
        #expect(impersonated?.event.workspace == supervisor.id.rawValue.uuidString)
        #expect(aCounter.count == 0)

        let wrongCapability = supervisor.submit(
            frame("touch marker", capability: a.capability, claim: b.id, runtime: b.id, id: UUID()),
            to: b.id
        )
        #expect(wrongCapability?.response == .rejected(.invalidCapability))
        #expect(bCounter.count == 0)

        let allowed = supervisor.submit(
            frame("touch marker", capability: a.capability, claim: a.id, runtime: a.id, id: request),
            to: a.id
        )
        #expect(allowed?.response == .executed(exitStatus: 0))
        #expect(aCounter.count == 1)
        let replayed = supervisor.submit(
            frame("touch marker", capability: a.capability, claim: a.id, runtime: a.id, id: request),
            to: a.id
        )
        #expect(replayed?.response == .rejected(.replay))
        #expect(aCounter.count == 1)
        let otherRuntime = supervisor.submit(
            frame("touch marker", capability: b.capability, claim: b.id, runtime: b.id, id: request),
            to: b.id
        )
        #expect(otherRuntime?.response == .executed(exitStatus: 0))
        #expect(bCounter.count == 1)
        #expect(kill(pidA, 0) == 0)
        #expect(kill(pidB, 0) == 0)
        #expect(supervisor.snapshot.phase == .active)
    }

    @Test func childExitLeavesTheWorkspaceMounted() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let original = tree.workspaceURL.appendingPathComponent("original.txt")
        try Data("before\n".utf8).write(to: original)
        let opened = try openWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let supervisor = opened.supervisor
        let device = supervisor.volumeDevice
        _ = try launch(
            supervisor,
            tree: tree,
            log: opened.runtimeLog,
            admission: .failClosed,
            script: "printf 'after\\n' > original.txt; printf done > a-done"
        )
        let survivor = try launch(
            supervisor,
            tree: tree,
            log: opened.runtimeLog,
            admission: .failClosed,
            script: """
            count=0
            while [ ! -f a-done ] && [ "$count" -lt 400 ]; do
              /bin/sleep 0.05
              count=$((count + 1))
            done
            printf from-b > from-b.txt
            /bin/sleep 30
            """
        )
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("from-b.txt")))
        let survivorPID = try #require(survivor.session.child?.pid)
        #expect(kill(survivorPID, 0) == 0)
        #expect(supervisor.savedFile("original.txt") == Data("before\n".utf8))
        #expect(supervisor.savedFile("from-b.txt") == nil)
        #expect(supervisor.publishCount == 0)
        #expect(supervisor.snapshot.phase == .active)
        #expect(supervisor.volumeDevice == device)
        #expect(waitUntil(seconds: 10) {
            WorkspaceLifecycleLog.records(at: opened.lifeLog).contains {
                $0.kind == .runtimeEnded && $0.workspace == supervisor.id.rawValue
            }
        })
        #expect(WorkspaceLifecycleLog.records(at: opened.lifeLog).contains { $0.kind == .closed } == false)
        let closed = supervisor.close()
        #expect(succeeded(closed))
        #expect(supervisor.publishCount == 1)
        #expect(supervisor.snapshot.phase == .closed)
        #expect(try String(contentsOf: original, encoding: .utf8) == "after\n")
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("from-b.txt"), encoding: .utf8) == "from-b")
        #expect(succeeded(supervisor.close()))
        #expect(supervisor.publishCount == 1)
        let finalLog = WorkspaceLifecycleLog.records(at: opened.lifeLog)
        #expect(finalLog.filter { $0.kind == .created && $0.workspace == supervisor.id.rawValue }.count == 1)
        #expect(finalLog.filter { $0.kind == .closed && $0.workspace == supervisor.id.rawValue }.count == 1)
        let starts = RuntimeSessionLog.records(at: opened.runtimeLog)
        #expect(starts.count == 2)
        #expect(starts.allSatisfy { $0.workspaceSession == supervisor.id.rawValue })
    }

    @Test func cancellingOneRuntimeLeavesTheOther() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let supervisor = opened.supervisor
        let device = supervisor.volumeDevice
        let counter = RunCounter()
        let doomed = try launch(
            supervisor,
            tree: tree,
            log: opened.runtimeLog,
            admission: .failClosed,
            script: "/bin/sleep 30"
        )
        let survivor = try launch(
            supervisor,
            tree: tree,
            log: opened.runtimeLog,
            admission: countingAdmission(counter),
            script: "/bin/sleep 30"
        )
        let doomedPID = try #require(doomed.session.child?.pid)
        let survivorPID = try #require(survivor.session.child?.pid)
        let cancelled = supervisor.cancel(doomed.id)
        #expect(succeeded(cancelled))
        #expect(processGone(doomedPID))
        #expect(kill(survivorPID, 0) == 0)
        #expect(supervisor.snapshot.phase == .active)
        #expect(supervisor.volumeDevice == device)
        #expect(supervisor.publishCount == 0)
        #expect(supervisor.savedFile("original.txt") == nil)
        let denied = supervisor.submit(
            frame("touch marker", capability: doomed.capability, claim: doomed.id, runtime: doomed.id, id: UUID()),
            to: doomed.id
        )
        #expect(denied?.response == .rejected(.inactiveSession))
        #expect(denied?.execute == nil)
        let allowed = supervisor.submit(
            frame("touch marker", capability: survivor.capability, claim: survivor.id, runtime: survivor.id, id: UUID()),
            to: survivor.id
        )
        #expect(allowed?.response == .executed(exitStatus: 0))
        #expect(counter.count == 1)
        #expect(FileManager.default.fileExists(atPath: tree.workspaceURL.appendingPathComponent("from-cancel").path) == false)
    }

    @Test func closeKillsEveryRuntimeBeforeItReturns() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openWorkspace(tree)
        let supervisor = opened.supervisor
        let first = try launch(
            supervisor,
            tree: tree,
            log: opened.runtimeLog,
            admission: .failClosed,
            script: "printf a > from-a.txt; /bin/sleep 30"
        )
        let second = try launch(
            supervisor,
            tree: tree,
            log: opened.runtimeLog,
            admission: .failClosed,
            script: "printf b > from-b.txt; /bin/sleep 30"
        )
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("from-a.txt")))
        #expect(waitFor(tree.workspaceURL.appendingPathComponent("from-b.txt")))
        let firstPID = try #require(first.session.child?.pid)
        let secondPID = try #require(second.session.child?.pid)
        let closed = supervisor.close()
        #expect(succeeded(closed))
        #expect(processGone(firstPID))
        #expect(processGone(secondPID))
        #expect(kill(-firstPID, 0) == -1 && errno == ESRCH)
        #expect(kill(-secondPID, 0) == -1 && errno == ESRCH)
        #expect(supervisor.snapshot.phase == .closed)
        #expect(supervisor.publishCount == 1)
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("from-a.txt"), encoding: .utf8) == "a")
        #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("from-b.txt"), encoding: .utf8) == "b")
    }

    @Test func launchAfterCloseBeginsDoesNotSpawn() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openWorkspace(tree)
        let supervisor = opened.supervisor
        let held = try launch(
            supervisor,
            tree: tree,
            log: opened.runtimeLog,
            admission: .failClosed,
            script: "/bin/sleep 30"
        )
        let heldPID = try #require(held.session.child?.pid)
        let box = CloseBox()
        let closer = Thread {
            box.result = supervisor.close()
        }
        closer.start()
        #expect(waitUntil(seconds: 10) { supervisor.snapshot.phase == .closing || supervisor.snapshot.phase == .closed })
        let startsBefore = RuntimeSessionLog.records(at: opened.runtimeLog).count
        let marker = tree.workspaceURL.appendingPathComponent("refused")
        let refused = supervisor.launch(
            host: .opencode,
            command: try shell("printf no > refused"),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(opened.runtimeLog)
        )
        if case .success = refused {
            Issue.record("launch during close must not spawn")
        }
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        #expect(RuntimeSessionLog.records(at: opened.runtimeLog).count == startsBefore)
        let join = Date().addingTimeInterval(45)
        while closer.isExecuting, Date() < join {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(closer.isExecuting == false)
        #expect(succeeded(box.result))
        #expect(processGone(heldPID))
        #expect(supervisor.publishCount == 1)
        #expect(supervisor.snapshot.phase == .closed)
    }

    @Test func hardlinkRefusesBeforeTheWorkspaceIsActive() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let file = tree.workspaceURL.appendingPathComponent("linked")
        let alias = tree.workspaceURL.appendingPathComponent("alias")
        try Data("kept".utf8).write(to: file)
        let linked = file.path.withCString { source in
            alias.path.withCString { destination in
                link(source, destination)
            }
        }
        try #require(linked == 0)
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        let log = tree.rootURL.appendingPathComponent("workspace.jsonl")
        switch WorkspaceSessionSupervisor.open(directory, lifecycleLog: .file(log)) {
        case .failure(.apply(.workspaceContainsInodeAlias)):
            break
        case .failure(let error):
            Issue.record("hardlink must refuse before activation, got \(error)")
        case .success(let supervisor):
            _ = supervisor.close()
            Issue.record("hardlink workspace became active")
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "kept")
        let parent = tree.workspaceURL.deletingLastPathComponent().path
        #expect(savedNames(in: parent).isEmpty)
        #expect(WorkspaceLifecycleLog.records(at: log).isEmpty)
    }

    @Test func runtimeDoesNotReceiveWorkspaceDescriptors() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let probe = try compileDescriptorProbe(in: tree.rootURL)
        let opened = try openWorkspace(tree)
        defer { _ = opened.supervisor.close() }
        let supervisor = opened.supervisor
        let holder = try launch(
            supervisor,
            tree: tree,
            log: opened.runtimeLog,
            admission: .failClosed,
            script: "/bin/sleep 30"
        )
        let identities = supervisor.controlFiles()
        #expect(identities.isEmpty == false)
        let report = tree.workspaceURL.appendingPathComponent("fd-report")
        let probed = try supervisor.launch(
            host: nil,
            command: try #require(IsolatedCommand(executable: probe.path, arguments: [report.path])),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(opened.runtimeLog)
        ).get()
        #expect(probed.session.workspaceSessionID == supervisor.id)
        #expect(waitFor(report))
        let text = try String(contentsOf: report, encoding: .utf8)
        var openFiles: Set<String> = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3 else { continue }
            openFiles.insert("\(parts[1]) \(parts[2])")
        }
        for identity in identities {
            let key = "\(identity.device) \(identity.inode)"
            #expect(openFiles.contains(key) == false, "workspace control file \(key) was open in the runtime\n\(text)")
        }
        let holderPID = try #require(holder.session.child?.pid)
        #expect(kill(holderPID, 0) == 0)
        #expect(supervisor.snapshot.phase == .active)
        #expect(savedNames(in: tree.workspaceURL.deletingLastPathComponent().path).count == 1)
    }
}

private struct OpenedWorkspace {
    var supervisor: WorkspaceSessionSupervisor
    var runtimeLog: URL
    var lifeLog: URL
}

private func openWorkspace(_ tree: ContainmentTree) throws -> OpenedWorkspace {
    let runtimeLog = tree.rootURL.appendingPathComponent("runtime-\(UUID().uuidString).jsonl")
    let lifeLog = tree.rootURL.appendingPathComponent("workspace-\(UUID().uuidString).jsonl")
    let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
    let supervisor = try WorkspaceSessionSupervisor.open(
        directory,
        lifecycleLog: .file(lifeLog)
    ).get()
    return OpenedWorkspace(supervisor: supervisor, runtimeLog: runtimeLog, lifeLog: lifeLog)
}

private func launch(
    _ supervisor: WorkspaceSessionSupervisor,
    tree: ContainmentTree,
    log: URL,
    admission: RuntimeAdmissionConfiguration,
    script: String
) throws -> RunningRuntime {
    _ = tree
    return try supervisor.launch(
        host: .opencode,
        command: shell(script),
        plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
        io: .discard,
        admission: admission,
        sessionStore: .file(log)
    ).get()
}

private func shell(_ script: String) throws -> IsolatedCommand {
    try #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", script]))
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

private func savedNames(in parent: String) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
    return names.filter { $0.hasPrefix(".rv-saved-") }.sorted()
}

private func succeeded(_ result: Result<Void, WorkspaceSessionError>?) -> Bool {
    guard let result else { return false }
    if case .success = result { return true }
    return false
}

private func processGone(_ pid: pid_t) -> Bool {
    if kill(pid, 0) == 0 { return false }
    return errno == ESRCH
}

private final class CloseBox: @unchecked Sendable {
    var result: Result<Void, WorkspaceSessionError>?
}

private final class RunCounter: @unchecked Sendable {
    private let runs = Mutex(0)

    func run(_ action: AllowedAction) -> Result<Int32, RuntimeAdmissionExecutorError> {
        _ = action
        runs.withLock { $0 += 1 }
        return .success(0)
    }

    var count: Int { runs.withLock { $0 } }
}

private func countingAdmission(_ counter: RunCounter) -> RuntimeAdmissionConfiguration {
    RuntimeAdmissionConfiguration(
        normalize: workspaceTouchNormalize,
        executor: .effect(counter.run),
        approval: { _ in nil },
        policy: { _ in .empty },
        evidence: RuntimeAdmissionEvidence()
    )
}

private func workspaceTouchNormalize(
    subject: RuntimeAdmissionSubject,
    action: RuntimeRequestedAction
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    guard case .shell(let command) = action else { return .failure(.failed) }
    let raw = command.rawValue
    let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
    guard tokens.count == 2, tokens[0] == "touch", tokens[1].hasPrefix("/") == false else {
        return .failure(.failed)
    }
    return .success(
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(
                    rawValue: "workspace:\(subject.session.id.rawValue.uuidString):\(raw)"
                ),
                effects: ActionEffects(kinds: [.filesystemCreate]),
                resources: ActionResources(
                    path: tokens[1],
                    filesystemScope: .insideRepository,
                    resourceKind: .unknown
                ),
                scope: ActionScope(workingDirectory: subject.policyWorkspace),
                supportingCommand: command
            )
        )
    )
}

private func frame(
    _ command: String,
    capability: RuntimeCapability,
    claim: RuntimeSessionID,
    runtime: RuntimeSessionID,
    id: UUID
) -> RuntimeActionFrame {
    _ = runtime
    return RuntimeActionFrame(
        version: 1,
        requestID: RuntimeActionRequestID(validating: id.uuidString)!,
        capability: capability,
        claimedSession: RuntimeSessionClaim(validating: claim.rawValue.uuidString)!,
        action: .shell(ShellCommand(rawValue: command))
    )
}

private func compileDescriptorProbe(in directory: URL) throws -> URL {
    let source = directory.appendingPathComponent("fd-probe.c")
    let binary = directory.appendingPathComponent("fd-probe")
    try Data(descriptorProbe.utf8).write(to: source)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compile.arguments = ["-O2", "-o", binary.path, source.path]
    compile.standardOutput = FileHandle.nullDevice
    compile.standardError = FileHandle.nullDevice
    try compile.run()
    compile.waitUntilExit()
    try #require(compile.terminationStatus == 0)
    return binary
}

private let descriptorProbe = #"""
#include <stdio.h>
#include <sys/stat.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    FILE *out = fopen(argv[1], "w");
    if (!out) return 1;
    for (int fd = 0; fd < 256; fd++) {
        struct stat info;
        if (fstat(fd, &info) != 0) continue;
        fprintf(out, "%d %llu %llu\n", fd,
            (unsigned long long)info.st_dev,
            (unsigned long long)info.st_ino);
    }
    fclose(out);
    return 0;
}
"""#
#endif

#if os(Linux)
@Suite("WorkspaceSessionLinux")
struct WorkspaceSessionLinuxTests {
    @Test func openDoesNotMountOrExecute() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("must-not-run")
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        switch WorkspaceSessionSupervisor.open(directory) {
        case .failure(.apply(.containedGuaranteesUnsupported)):
            break
        case .failure(let error):
            Issue.record("Linux workspace open must refuse, got \(error)")
        case .success:
            Issue.record("Linux workspace open must not succeed")
        }
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }
}
#endif
