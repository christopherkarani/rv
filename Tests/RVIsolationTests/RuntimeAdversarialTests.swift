#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Effect-based acceptance probes for the implemented write fence.
/// `knownGap` tests reproduce missing guarantees; their success is evidence of
/// a release blocker, never evidence that the requested isolation is secure.
/// Every resource and signal target belongs to this test, including fake secrets.
@Suite("RuntimeAdversarial", .serialized)
struct RuntimeAdversarialTests {
    @Test(arguments: AdversarialLauncher.allCases)
    func descendantsCannotWriteOutsideWorkspace(_ launcher: AdversarialLauncher) throws {
        guard let executable = launcher.installedExecutable, launcher.runsUnderBaseline(executable) else {
            print("adversarial technique=\(launcher.rawValue) coverage=NOT-TESTED reason=outside-baseline-or-stub")
            return
        }
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let inside = tree.workspaceURL.appendingPathComponent("ran")
        let outside = tree.siblingURL.appendingPathComponent("escaped")
        let script = "printf ran > \(quote(inside.path)); printf escaped > \(quote(outside.path))"
        let run: IsolatedRunResult
        if launcher == .xargs {
            // posix_spawn is denied so a utility cannot leave RV's process group.
            _ = try runShell(
                tree.contained,
                "printf '%s\\n' fixture | \(quote(executable)) /bin/sh -c \(quote(script))"
            )
            #expect(!exists(inside))
            #expect(!exists(outside))
            return
        } else {
            run = try runIsolated(
                tree.contained,
                executable: executable,
                arguments: launcher.arguments(script: script)
            )
        }
        #expect(try String(contentsOf: inside, encoding: .utf8) == "ran")
        #expect(run.exitStatus != 0)
        #expect(!exists(outside))
        print("adversarial technique=\(launcher.rawValue) executable=\(executable) verdict=WRITE-DENIED")
    }

    @Test(arguments: ["nested", "exec", "background-wait", "env-shebang", "path-replacement", "executable-replacement"])
    func shellIndirectionCannotRemoveWriteFence(_ technique: String) throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let inside = tree.workspaceURL.appendingPathComponent("ran")
        let outside = tree.siblingURL.appendingPathComponent("escaped")
        let payload = "printf ran > \(quote(inside.path)); printf escaped > \(quote(outside.path))"
        let scriptURL = tree.workspaceURL.appendingPathComponent("payload")
        let script: String
        switch technique {
        case "nested":
            script = (0..<4).reduce(payload) { result, _ in "/bin/sh -c \(quote(result))" }
        case "exec":
            script = "exec /bin/sh -c \(quote(payload))"
        case "background-wait":
            script = "/bin/sh -c \(quote(payload)) & child=$!; wait \"$child\""
        case "env-shebang":
            try writeExecutable("#!/usr/bin/env sh\n\(payload)\n", to: scriptURL)
            script = quote(scriptURL.path)
        case "path-replacement":
            let tool = tree.workspaceURL.appendingPathComponent("rv-adversarial-tool")
            try writeExecutable("#!/bin/sh\n\(payload)\n", to: tool)
            script = "PATH=\(quote(tree.workspaceURL.path)); export PATH; rv-adversarial-tool"
        case "executable-replacement":
            try writeExecutable("#!/bin/sh\nexit 0\n", to: scriptURL)
            script = "printf %s \(quote("#!/bin/sh\n" + payload + "\n")) > \(quote(scriptURL.path)); exec \(quote(scriptURL.path))"
        default:
            Issue.record("unknown indirection fixture \(technique)")
            return
        }
        let run = try runShell(tree.contained, script)
        #expect(try String(contentsOf: inside, encoding: .utf8) == "ran")
        #expect(run.exitStatus != 0)
        #expect(!exists(outside))
        print("adversarial technique=\(technique) verdict=WRITE-DENIED")
    }

    @Test(arguments: ["../outside", "../../sibling/outside", "./nested/../../outside"])
    func relativeTraversalCannotWriteOutsideWorkspace(_ target: String) throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try FileManager.default.createDirectory(
            at: tree.workspaceURL.appendingPathComponent("nested"), withIntermediateDirectories: true
        )
        let run = try runShell(tree.contained, "printf ran > inside; printf escaped > \(quote(target))")
        #expect(exists(tree.workspaceURL.appendingPathComponent("inside")))
        #expect(run.exitStatus != 0)
        #expect(!exists(tree.repositoryURL.appendingPathComponent("outside")))
        #expect(!exists(tree.siblingURL.appendingPathComponent("outside")))
    }

    @Test(arguments: [false, true])
    func symlinkChainsCannotWriteOutsideWorkspace(_ createdByAgent: Bool) throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let first = tree.workspaceURL.appendingPathComponent("first")
        let second = tree.workspaceURL.appendingPathComponent("second")
        let outside = tree.siblingURL.appendingPathComponent("escaped")
        var script = ""
        if createdByAgent {
            script = "/bin/ln -s \(quote(tree.siblingURL.path)) \(quote(second.path)) && /bin/ln -s second \(quote(first.path)) && "
        } else {
            try FileManager.default.createSymbolicLink(at: second, withDestinationURL: tree.siblingURL)
            try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: "second")
        }
        script += "printf ran > inside; printf escaped > \(quote(first.appendingPathComponent("escaped").path))"
        let run = try runShell(tree.contained, script)
        #expect(exists(tree.workspaceURL.appendingPathComponent("inside")))
        #expect(run.exitStatus != 0)
        #expect(!exists(outside))
    }

    @Test func renameCannotMoveAcrossWriteBoundary() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let inside = tree.workspaceURL.appendingPathComponent("inside")
        let outside = tree.siblingURL.appendingPathComponent("outside")
        try Data("inside-original".utf8).write(to: inside)
        try Data("outside-original".utf8).write(to: outside)
        let export = try runShell(tree.contained, "/bin/mv \(quote(inside.path)) \(quote(outside.path))")
        #expect(export.exitStatus != 0)
        #expect(try String(contentsOf: inside, encoding: .utf8) == "inside-original")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside-original")
        let imported = tree.workspaceURL.appendingPathComponent("imported")
        let importAttempt = try runShell(tree.contained, "/bin/mv \(quote(outside.path)) \(quote(imported.path))")
        #expect(importAttempt.exitStatus != 0)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside-original")
    }

    @Test func agentCannotCreateAnOutsideHardlinkOrMutateOutsideSource() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let outside = tree.siblingURL.appendingPathComponent("source")
        let link = tree.workspaceURL.appendingPathComponent("alias")
        try Data("original".utf8).write(to: outside)
        let run = try runShell(
            tree.contained,
            "/bin/ln \(quote(outside.path)) \(quote(link.path)) && printf changed > \(quote(link.path))"
        )
        #expect(run.exitStatus != 0)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "original")
    }

    @Test func preexistingHardlinkAliasRefusesLaunchBeforeExecution() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let outside = tree.siblingURL.appendingPathComponent("source")
        let alias = tree.workspaceURL.appendingPathComponent("alias")
        let marker = tree.workspaceURL.appendingPathComponent("executed")
        try Data("original".utf8).write(to: outside)
        try FileManager.default.linkItem(at: outside, to: alias)
        let command = try #require(
            IsolatedCommand(
                executable: "/bin/sh",
                arguments: ["-c", "printf ran > \(quote(marker.path)); printf changed > \(quote(alias.path))"]
            )
        )
        switch IsolationBackends.apply(tree.contained, command: command) {
        case .success:
            Issue.record("preexisting hardlink must refuse launch")
        case .failure(let error):
            switch error {
            case .workspaceContainsInodeAlias:
                break
            case .backendUnavailable, .backendMismatch, .workspaceMustBeAbsolute,
                .workspaceDoesNotExist, .workspacePathUnresolvable, .workspacePathUnsafe,
                .containedGuaranteesUnsupported, .profileNotApplicable, .processSpawnFailed,
                .commandContainsNUL, .commandExecutableMustBeAbsolute, .sessionRecordFailed, .seatbeltNotEstablished, .lifetimeBoundaryFailed, .cancelled, .workspaceInodeBoundaryFailed:
                Issue.record("preexisting hardlink must be workspaceContainsInodeAlias, got \(error)")
            }
        }
        #expect(!exists(marker))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "original")
    }

    /// The alias is created only after the contained process has written `ready`,
    /// so the preflight scan has already returned. A same-user process outside
    /// the sandbox plants the link.
    @Test func hardlinkCreatedAfterPreflightCannotMutateOutsideInode() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let outside = tree.siblingURL.appendingPathComponent("important.txt")
        let seed = tree.workspaceURL.appendingPathComponent("seed")
        let alias = tree.workspaceURL.appendingPathComponent("alias")
        let ready = tree.workspaceURL.appendingPathComponent("ready")
        let trigger = tree.workspaceURL.appendingPathComponent("trigger")
        let inside = tree.workspaceURL.appendingPathComponent("inside")
        try Data("original\n".utf8).write(to: outside)
        try Data("seed\n".utf8).write(to: seed)
        let script = """
        printf go > \(quote(ready.path))
        count=0
        while [ ! -f \(quote(trigger.path)) ] && [ "$count" -lt 400 ]; do
          /bin/sleep 0.05
          count=$((count + 1))
        done
        printf 'changed\\n' > \(quote(alias.path))
        printf 'seed-updated\\n' > \(quote(seed.path))
        printf ok > \(quote(inside.path))
        """
        let plan = tree.contained
        let box = HardlinkRaceBox()
        let runner = Thread {
            guard let command = IsolatedCommand(executable: "/bin/sh", arguments: ["-c", script]) else {
                box.result = .failure(.commandExecutableMustBeAbsolute)
                return
            }
            box.result = IsolationBackends.apply(plan, command: command)
        }
        runner.start()
        let readyDeadline = Date().addingTimeInterval(45)
        while exists(ready) == false, Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(exists(ready))
        let linkResult = outside.path.withCString { source in
            alias.path.withCString { destination in
                link(source, destination)
            }
        }
        let linkError = errno
        try Data("go\n".utf8).write(to: trigger)
        let joinDeadline = Date().addingTimeInterval(45)
        while runner.isExecuting, Date() < joinDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(runner.isExecuting == false)
        if linkResult == 0 {
            Issue.record("same-user hardlink after ready succeeded; boundary did not reject it")
        } else {
            #expect(linkError == EXDEV)
        }
        let outsideBytes = FileManager.default.contents(atPath: outside.path)
        let outsideText = outsideBytes.flatMap { String(decoding: $0, as: UTF8.self) } ?? "<missing \(outside.path)>"
        #expect(outsideText == "original\n")
        let run = try #require(box.result).get()
        #expect(run.exitStatus == 0)
        #expect(try String(contentsOf: inside, encoding: .utf8) == "ok")
        #expect(try String(contentsOf: seed, encoding: .utf8) == "seed-updated\n")
    }

    @Test func knownGapSyntheticCredentialsAreReadableButCannotBeOverwritten() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let home = tree.siblingURL.appendingPathComponent("fake-home")
        let paths = [
            ".ssh/id_ed25519", ".ssh/config", ".aws/credentials", ".config/gcloud/credentials.db",
            ".env", ".git-credentials", ".bash_history", ".zsh_history", ".zshrc",
            "Library/Keychains/login.keychain-db", "Library/Application Support/Browser/Cookies",
            ".config/rv/policy.toml", ".local/bin/rv",
        ]
        for (index, relative) in paths.enumerated() {
            let secret = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: secret.deletingLastPathComponent(), withIntermediateDirectories: true)
            let synthetic = "RV-SYNTHETIC-NOT-A-SECRET-\(index)"
            try Data(synthetic.utf8).write(to: secret)
            let copy = tree.workspaceURL.appendingPathComponent("read-\(index)")
            let read = try runShell(tree.contained, "/bin/cat \(quote(secret.path)) > \(quote(copy.path))")
            #expect(read.exitStatus != 0)
            if exists(copy) {
                #expect(try String(contentsOf: copy, encoding: .utf8) != synthetic)
            }
            let write = try runShell(tree.contained, "printf overwritten > \(quote(secret.path))")
            #expect(write.exitStatus != 0)
            #expect(try String(contentsOf: secret, encoding: .utf8) == synthetic)
        }
    }

    @Test func knownGapWorkspaceGitHooksAndRVConfigurationRemainWritable() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        for relative in [".git/hooks/pre-commit", ".rv/policy.toml", ".config/rv/policy.toml", ".zshrc"] {
            let target = tree.workspaceURL.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let run = try runShell(tree.contained, "printf modified > \(quote(target.path))")
            #expect(run.exitStatus == 0)
            #expect(try String(contentsOf: target, encoding: .utf8) == "modified")
        }
        print("adversarial technique=workspace-control-files security=NOT-SATISFIED reason=no-protected-subpaths")
    }

    @Test func concurrentWorkspacesCannotAcquireEachOthersWriteAuthority() async throws {
        let first = try ContainmentTree()
        let second = try ContainmentTree()
        defer { first.tearDown(); second.tearDown() }
        let firstOwn = first.workspaceURL.appendingPathComponent("own")
        let secondOwn = second.workspaceURL.appendingPathComponent("own")
        let firstAttack = second.workspaceURL.appendingPathComponent("from-first")
        let secondAttack = first.workspaceURL.appendingPathComponent("from-second")
        let jobs = [
            (first.contained, firstOwn.path, firstAttack.path),
            (second.contained, secondOwn.path, secondAttack.path),
        ]
        try await withThrowingTaskGroup(of: Int32.self) { group in
            for (plan, own, attack) in jobs {
                group.addTask {
                    let run = try runShell(plan, "printf own > \(quote(own)); /bin/sleep 0.1; printf stolen > \(quote(attack))")
                    return run.exitStatus
                }
            }
            for try await status in group { #expect(status != 0) }
        }
        #expect(exists(firstOwn))
        #expect(exists(secondOwn))
        #expect(!exists(firstAttack))
        #expect(!exists(secondAttack))
    }

    @Test func backgroundChildCannotRetainWorkspaceAuthorityAfterReturn() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try assertNoSurvivingWriter(tree, script: backgroundAndExit(tree))
    }

    @Test func nestedShellBackgroundChildCannotRetainWorkspaceAuthorityAfterReturn() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let inner = backgroundAndExit(tree)
        try assertNoSurvivingWriter(tree, script: "/bin/sh -c \(quote(inner))")
    }

    @Test func lifetimeSyscallsAreDeniedInsideSeatbelt() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let probe = try compileProbe(lifetimeSyscallProbeSource, named: "lifetime-syscalls", in: tree.workspaceURL)
        let report = tree.workspaceURL.appendingPathComponent("syscalls")
        let command = try #require(IsolatedCommand(executable: probe.path, arguments: [report.path]))
        let run = try IsolationBackends.apply(tree.contained, command: command).get()
        #expect(run.exitStatus == 0)
        #expect(run.session != nil)
        let text = try String(contentsOf: report, encoding: .utf8)
        let lines = Set(text.split(whereSeparator: \.isNewline).map(String.init))
        #expect(lines.contains("fork 0"))
        #expect(lines.contains("setsid 1"))
        #expect(lines.contains("setpgid 1"))
        #expect(lines.contains("posix_spawn 1"))
    }

    @Test func setsidProbeCannotRetainWorkspaceAuthorityAfterReturn() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let probe = try compileProbe(setsidProbeSource, named: "setsid-probe", in: tree.workspaceURL)
        try assertProbeCannotSurvive(tree, executable: probe.path)
    }

    @Test func doubleForkProbeCannotRetainWorkspaceAuthorityAfterReturn() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let probe = try compileProbe(doubleForkProbeSource, named: "double-fork-probe", in: tree.workspaceURL)
        try assertProbeCannotSurvive(tree, executable: probe.path)
    }

    @Test func posixSpawnSetsidProbeCannotRetainWorkspaceAuthorityAfterReturn() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let probe = try compileProbe(posixSpawnSetsidProbeSource, named: "spawn-setsid-probe", in: tree.workspaceURL)
        try assertProbeCannotSurvive(tree, executable: probe.path)
    }

    @Test func knownGapCanSignalSyntheticUnrelatedProcess() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let victim = Process()
        victim.executableURL = URL(fileURLWithPath: "/bin/sleep")
        victim.arguments = ["5"]
        victim.standardInput = FileHandle.nullDevice
        victim.standardOutput = FileHandle.nullDevice
        victim.standardError = FileHandle.nullDevice
        try victim.run()
        defer {
            if victim.isRunning { victim.terminate() }
            victim.waitUntilExit()
        }
        let run = try runShell(tree.contained, "kill -TERM \(victim.processIdentifier)")
        #expect(run.exitStatus != 0)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(victim.isRunning)
    }

    @Test func containedShellCanSignalItsOwnChild() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("child-signaled")
        let run = try runShell(
            tree.contained,
            "sleep 20 & pid=$!; sleep 0.2; kill \"$pid\" || exit 41; wait \"$pid\"; printf killed > \(quote(marker.path))"
        )
        #expect(run.exitStatus == 0)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "killed")
    }
}

enum AdversarialLauncher: String, CaseIterable, Sendable {
    case sh, bash, zsh, env, xargs, python, ruby, node

    var installedExecutable: String? {
        let names: [String]
        switch self {
        case .python: names = ["python3"]
        default: names = [rawValue]
        }
        for directory in ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"] {
            for name in names {
                let path = directory + "/" + name
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    /// Interpreters outside `/bin` and `/usr/bin`, and the Xcode `python3` stub,
    /// are not part of the execution baseline. A payload that never starts is
    /// not a denial result.
    func runsUnderBaseline(_ path: String) -> Bool {
        if path == "/usr/bin/python3" {
            return false
        }
        return path.hasPrefix("/bin/") || path.hasPrefix("/usr/bin/")
    }

    func arguments(script: String) -> [String] {
        switch self {
        case .sh, .bash, .zsh: return ["-c", script]
        case .env: return ["/bin/sh", "-c", script]
        case .xargs: return ["/bin/sh", "-c", script]
        case .python:
            return ["-c", "import subprocess,sys; sys.exit(subprocess.call(['/bin/sh','-c',sys.argv[1]]))", script]
        case .ruby:
            return ["-e", "exec('/bin/sh', '-c', ARGV.fetch(0))", script]
        case .node:
            return ["-e", "process.exit(require('child_process').spawnSync('/bin/sh',['-c',process.argv[1]]).status)", script]
        }
    }
}

private final class HardlinkRaceBox: @unchecked Sendable {
    var result: Result<IsolatedRunResult, IsolationApplyError>?
}

private func runShell(_ plan: IsolationPlan, _ script: String) throws -> IsolatedRunResult {
    try runIsolated(plan, executable: "/bin/sh", arguments: ["-c", script])
}

private func runIsolated(
    _ plan: IsolationPlan,
    executable: String,
    arguments: [String]
) throws -> IsolatedRunResult {
    let command = try #require(IsolatedCommand(executable: executable, arguments: arguments))
    let run = try IsolationBackends.apply(plan, command: command).get()
    #expect(run.established.mode == plan.mode)
    #expect(run.established.family != .none)
    return run
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

private func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func writeExecutable(_ source: String, to url: URL) throws {
    try Data(source.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

private func survivingWriter(_ tree: ContainmentTree) -> String {
    let marker = tree.workspaceURL.appendingPathComponent("after-session").path
    let gate = tree.workspaceURL.appendingPathComponent("parent-returned").path
    let outside = tree.siblingURL.appendingPathComponent("escaped").path
    return "count=0; while [ ! -f \(quote(gate)) ] && [ \"$count\" -lt 150 ]; do /bin/sleep 0.02; count=$((count + 1)); done; printf alive > \(quote(marker)); printf escaped > \(quote(outside))"
}

private func backgroundAndExit(_ tree: ContainmentTree) -> String {
    let pid = tree.workspaceURL.appendingPathComponent("child.pid").path
    return "/bin/sh -c \(quote(survivingWriter(tree))) & printf %s \"$!\" > \(quote(pid)); exit 0"
}

private func assertNoSurvivingWriter(_ tree: ContainmentTree, script: String) throws {
    let marker = tree.workspaceURL.appendingPathComponent("after-session")
    let gate = tree.workspaceURL.appendingPathComponent("parent-returned")
    let outside = tree.siblingURL.appendingPathComponent("escaped")
    let pidFile = tree.workspaceURL.appendingPathComponent("child.pid")
    let run = try runShell(tree.contained, script)
    #expect(run.exitStatus == 0)
    #expect(run.session != nil)
    let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(Int32(pidText))
    let liveness = kill(pid, 0)
    let livenessError = errno
    #expect(liveness == -1)
    #expect(livenessError == ESRCH)
    try Data("parent-has-returned".utf8).write(to: gate)
    Thread.sleep(forTimeInterval: 0.5)
    #expect(!exists(marker))
    #expect(!exists(outside))
}

private func assertProbeCannotSurvive(_ tree: ContainmentTree, executable: String) throws {
    let marker = tree.workspaceURL.appendingPathComponent("after-session")
    let gate = tree.workspaceURL.appendingPathComponent("parent-returned")
    let command = try #require(IsolatedCommand(executable: executable, arguments: [marker.path, gate.path]))
    let result = IsolationBackends.apply(tree.contained, command: command)
    try Data("parent-has-returned".utf8).write(to: gate)
    Thread.sleep(forTimeInterval: 0.5)
    #expect(!exists(marker))
    switch result {
    case .success(let run):
        #expect(run.session != nil)
        #expect(run.established.family == .seatbelt)
    case .failure(let error):
        Issue.record("probe must run under Seatbelt, got \(error)")
    }
}

private func compileProbe(_ source: String, named name: String, in workspace: URL) throws -> URL {
    let file = workspace.appendingPathComponent("\(name).c")
    let binary = workspace.appendingPathComponent(name)
    try Data(source.utf8).write(to: file)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compile.arguments = ["-O2", "-o", binary.path, file.path]
    compile.standardOutput = FileHandle.nullDevice
    compile.standardError = FileHandle.nullDevice
    try compile.run()
    compile.waitUntilExit()
    try #require(compile.terminationStatus == 0)
    return binary
}

private let setsidProbeSource = """
#include <fcntl.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    pid_t pid = fork();
    if (pid < 0) return 3;
    if (pid > 0) _exit(0);
    setsid();
    for (int i = 0; i < 400; i++) {
        if (access(argv[2], F_OK) == 0) break;
        usleep(10000);
    }
    int fd = open(argv[1], O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        write(fd, "alive\\n", 6);
        close(fd);
    }
    return 0;
}
"""

private let doubleForkProbeSource = """
#include <fcntl.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    pid_t first = fork();
    if (first < 0) return 3;
    if (first > 0) _exit(0);
    pid_t second = fork();
    if (second < 0) return 4;
    if (second > 0) _exit(0);
    setsid();
    for (int i = 0; i < 400; i++) {
        if (access(argv[2], F_OK) == 0) break;
        usleep(10000);
    }
    int fd = open(argv[1], O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        write(fd, "alive\\n", 6);
        close(fd);
    }
    return 0;
}
"""

private let posixSpawnSetsidProbeSource = """
#include <spawn.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
extern char **environ;
int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "wait") == 0) {
        if (argc < 4) return 2;
        for (int i = 0; i < 400; i++) {
            if (access(argv[3], F_OK) == 0) break;
            usleep(10000);
        }
        int fd = open(argv[2], O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (fd >= 0) {
            write(fd, "alive\\n", 6);
            close(fd);
        }
        return 0;
    }
    if (argc < 3) return 2;
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    pid_t child = 0;
    char *childArgv[] = {argv[0], "wait", argv[1], argv[2], NULL};
    posix_spawn(&child, argv[0], NULL, &attr, childArgv, environ);
    _exit(0);
}
"""

private let lifetimeSyscallProbeSource = """
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    int fd = open(argv[1], O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return 3;
    pid_t child = fork();
    if (child < 0) {
        dprintf(fd, "fork %d\\n", errno);
        return 4;
    }
    if (child == 0) {
        char buf[128];
        errno = 0;
        pid_t sid = setsid();
        int setsidErrno = sid < 0 ? errno : 0;
        errno = 0;
        int pg = setpgid(0, 0);
        int setpgidErrno = pg == 0 ? 0 : errno;
        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
        pid_t spawned = 0;
        char *av[] = {"/usr/bin/true", NULL};
        int spawnedCode = posix_spawn(&spawned, "/usr/bin/true", NULL, &attr, av, environ);
        int n = snprintf(
            buf, sizeof buf, "fork 0\\nsetsid %d\\nsetpgid %d\\nposix_spawn %d\\n",
            setsidErrno, setpgidErrno, spawnedCode
        );
        if (n > 0) write(fd, buf, (size_t)n);
        _exit(0);
    }
    int status = 0;
    waitpid(child, &status, 0);
    close(fd);
    return 0;
}
"""
#endif
