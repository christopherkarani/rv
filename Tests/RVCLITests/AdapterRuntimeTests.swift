import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

@Suite struct AdapterRuntimeSetupTests {
    @Test func setupRefusesPythonHostsWhenPython3DoesNotRun() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(atPath: layout.claudeDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: layout.codexDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            var environment = env(home: home, launchctl: launchctl)
            var asked: [String] = []
            environment.resolveInterpreter = { asked.append($0); return nil }
            let outcome = SetupRun.setup(environment)
            #expect(asked == ["python3"], "probed once")
            #expect(outcome.exitCode == EX_UNAVAILABLE)
            #expect(outcome.stderr.contains(
                "rv setup: not wiring claude, codex: python3 is not runnable, so the hook would fail open "
                    + "(the host treats a missing interpreter as a non-blocking error)\n"))
            #expect(outcome.stderr.contains("fix: install python3"))
            #expect(outcome.stderr.contains("then rerun rv setup\n"))
            #expect(FileManager.default.fileExists(atPath: layout.claudeSettings) == false)
            #expect(FileManager.default.fileExists(atPath: layout.codexHooksJSON) == false)
            #expect(FileManager.default.fileExists(atPath: layout.grokHook), "non-python hosts still wired")
        }
    }

    @Test func setupDoesNotProbePythonWithoutAPythonHost() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            var environment = env(home: home, launchctl: launchctl)
            var asked = false
            environment.resolveInterpreter = { _ in asked = true; return nil }
            let outcome = SetupRun.setup(environment)
            #expect(outcome.exitCode == 0)
            #expect(asked == false)
        }
    }

    @Test func setupBakesTheProbedInterpreterWithIsolationFlags() throws {
        try withTempHome { home, layout, launchctl in
            for directory in [layout.claudeDirectory, layout.codexDirectory, layout.cursorDirectory] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            var environment = env(home: home, launchctl: launchctl)
            var asked = 0
            environment.resolveInterpreter = { _ in asked += 1; return "/opt/py/bin/python3" }
            #expect(SetupRun.setup(environment).exitCode == 0)
            #expect(asked == 1, "one probe, reused by every write")
            let claude = try String(contentsOfFile: layout.claudeSettings, encoding: .utf8)
            #expect(claude.contains(" /opt/py/bin/python3 -I -S \(layout.claudeDirectory)/hooks/rv-guard.py"))
            #expect(claude.contains(" python3 /") == false)
            let codex = try String(contentsOfFile: layout.codexHooksJSON, encoding: .utf8)
            #expect(codex.contains("\"\(adapterLauncher)/opt/py/bin/python3 -I -S \(layout.codexHook)\""))
            let cursor = try String(contentsOfFile: layout.cursorHooksJSON, encoding: .utf8)
            #expect(cursor.contains("\"\(adapterLauncher)/opt/py/bin/python3 -I -S \(layout.cursorHook)\""))
        }
    }

    @Test func setupRewritesTheEarlierPathCommandWithoutForce() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(atPath: layout.claudeDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: layout.codexDirectory, withIntermediateDirectories: true)
            let rvPath = home.path + "/.local/bin/rv"
            let adapter = ClaudeSettingsMerge.adapterPath(settingsPath: layout.claudeSettings)
            let legacy = "RV_BINARY=\(rvPath) python3 \(adapter)"
            let groups = ClaudeSettingsMerge.matchers.map { matcher in
                "{\"matcher\":\"\(matcher)\",\"hooks\":[{\"type\":\"command\",\"command\":\"\(legacy)\","
                    + "\"timeout\":\(ClaudeSettingsMerge.timeout)}]}"
            }
            try Data("{\"hooks\":{\"PreToolUse\":[\(groups.joined(separator: ","))]}}".utf8)
                .write(to: URL(fileURLWithPath: layout.claudeSettings))
            #expect(ClaudeSettingsMerge.inspectionState(of: FileManager.default.contents(atPath: layout.claudeSettings))
                == .outdated)
            try Data(("{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\","
                + "\"command\":\"python3 \(layout.codexHook)\",\"timeout\":18,\"statusMessage\":\"RV\"}]}]}}").utf8)
                .write(to: URL(fileURLWithPath: layout.codexHooksJSON))

            let outcome = SetupRun.setup(env(home: home, launchctl: launchctl, rvPath: rvPath))
            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            let claude = try String(contentsOfFile: layout.claudeSettings, encoding: .utf8)
            #expect(claude.contains(legacy) == false)
            #expect(claude.components(separatedBy: "/usr/bin/python3 -I -S \(adapter)").count - 1
                == ClaudeSettingsMerge.matchers.count)
            let codex = try String(contentsOfFile: layout.codexHooksJSON, encoding: .utf8)
            #expect(codex.contains("\"python3 ") == false)
            #expect(codex.components(separatedBy: "rv-guard.py").count - 1 == 1)
            #expect(codex.contains("/usr/bin/python3 -I -S \(layout.codexHook)"))
        }
    }

    @Test func onlyCommandHooksNeedAnInterpreter() {
        #expect(AdapterRuntime.interpreter(for: .claude) == "python3")
        #expect(AdapterRuntime.interpreter(for: .codex) == "python3")
        #expect(AdapterRuntime.interpreter(for: .cursor) == "python3")
        #expect(AdapterRuntime.interpreter(for: .antigravity) == "python3")
        for host in [HookHost.grok, .pi, .opencode, .openclaw, .hermes, .muse] {
            #expect(AdapterRuntime.interpreter(for: host) == nil)
        }
    }

    @Test func liveRunnableIsFalseWithoutTheInterpreterOnPath() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("rv-nopy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(AdapterRuntime.liveRunnable("python3", pathEntries: [empty.path]) == false)
        try makeExecutable(empty.appendingPathComponent("python3"), contents: "#!/bin/sh\nexit 127\n")
        #expect(AdapterRuntime.liveRunnable("python3", pathEntries: [empty.path]) == false)
        try makeExecutable(empty.appendingPathComponent("python3"), contents: "#!/bin/sh\nexit 0\n")
        #expect(AdapterRuntime.liveRunnable("python3", pathEntries: [empty.path]))
    }

    @Test func resolveRunnableReturnsTheAbsolutePathProbedWithTheHookFlags() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rv-py-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let python = dir.appendingPathComponent("python3")
        // Runs only when started as the hook command starts it.
        try makeExecutable(python, contents: "#!/bin/sh\n[ \"$1 $2\" = \"-I -S\" ] || exit 2\nexit 0\n")
        #expect(AdapterRuntime.resolveRunnable("python3", pathEntries: ["relative/bin", dir.path]) == python.path)
        #expect(AdapterRuntime.resolveRunnable(python.path, pathEntries: []) == python.path)
        #expect(AdapterRuntime.resolveRunnable("python3", pathEntries: ["relative/bin"]) == nil)
        try makeExecutable(python, contents: "#!/bin/sh\n[ \"$1\" = \"-c\" ] || exit 2\nexit 0\n")
        #expect(AdapterRuntime.resolveRunnable("python3", pathEntries: [dir.path]) == nil, "rejects -I -S")
    }

    /// A miniconda/pyenv python3 first on PATH is one an agent can swap;
    /// setup bakes the system one instead when it is protected and runs.
    @Test func chooseRunnablePrefersAProtectedSystemInterpreterOverPathOrder() throws {
        let root = try realTemporaryDirectory("rv-pick")
        let system = root.appendingPathComponent("usr/bin")
        let user = root.appendingPathComponent("conda/bin")
        for dir in [system, user] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let systemPython = system.appendingPathComponent("python3")
        let userPython = user.appendingPathComponent("python3")
        try makeExecutable(userPython, contents: "#!/bin/sh\nexit 0\n")
        let path = [user.path, system.path]
        let search = SystemInterpreterSearch(direct: [systemPython.path], launchers: [], launchersUsable: { false })
        func choose(protected: Bool) -> String? {
            AdapterRuntime.chooseRunnable(
                "python3", pathEntries: path, search: search,
                identify: { InterpreterIdentity(executable: $0, prefix: "/usr", stdlib: "/usr/lib/os.py") },
                isProtected: { _ in protected })
        }

        #expect(choose(protected: true) == userPython.path, "no system python3: PATH order")
        try makeExecutable(systemPython, contents: "#!/bin/sh\nexit 0\n")
        // In a directory this user can write, so still PATH order.
        #expect(choose(protected: true) == userPython.path, "the baked path itself must be unreplaceable")
        #expect(choose(protected: false) == userPython.path, "a replaceable system python3 earns nothing")
        try FileManager.default.removeItem(at: userPython)
        #expect(choose(protected: true) == systemPython.path, "PATH order still finds it, as before")
        try FileManager.default.removeItem(at: systemPython)
        #expect(choose(protected: true) == nil)
        #expect(AdapterRuntime.chooseRunnable(
            userPython.path, pathEntries: [], search: search, identify: { _ in Issue.record("probed"); return nil },
            isProtected: { _ in true }) == nil,
            "an absolute name is probed as is")
    }

    /// macOS's `/usr/bin/python3` is a root-owned xcrun launcher for the
    /// Python of the developer directory, which may be a user-owned
    /// Xcode.app: what it runs decides, and setup bakes that, not the
    /// launcher.
    @Test func chooseRunnableBakesTheRealInterpreterBehindALauncher() throws {
        let launcher = "/bin/sh" // root-owned, runs -I -S -c as a no-op
        let search = SystemInterpreterSearch(direct: [], launchers: [launcher], launchersUsable: { true })
        let user = try realTemporaryDirectory("rv-xcode")
        defer { try? FileManager.default.removeItem(at: user) }
        let userPython = user.appendingPathComponent("python3")
        try makeExecutable(userPython, contents: "#!/bin/sh\nexit 0\n")
        let xcode = InterpreterIdentity(
            executable: userPython.path, prefix: user.path, stdlib: user.path + "/lib/os.py")
        #expect(AdapterRuntime.chooseRunnable(
            "python3", pathEntries: [], search: search, identify: { _ in xcode }) == nil,
            "a user-writable resolved interpreter is rejected")

        let writableStdlib = InterpreterIdentity(executable: "/bin/sh", prefix: user.path, stdlib: user.path + "/os.py")
        #expect(AdapterRuntime.chooseRunnable(
            "python3", pathEntries: [], search: search, identify: { _ in writableStdlib }) == nil,
            "a user-writable standard library is rejected")

        guard getuid() != 0 else { return }
        let real = "/usr/bin/true" // root-owned, exits 0 for the hook flags
        let commandLineTools = InterpreterIdentity(executable: real, prefix: "/usr", stdlib: "/bin/sh")
        #expect(AdapterRuntime.chooseRunnable(
            "python3", pathEntries: [], search: search, identify: { _ in commandLineTools }) == real,
            "the root-owned real interpreter is baked, not the launcher")
    }

    /// Without the developer tools the launcher pops an install dialog, so
    /// it is never run then; the direct candidate is still tried.
    @Test func noLauncherProbeRunsWhenNoDeveloperDirectoryIsSelected() {
        var identified: [String] = []
        let search = SystemInterpreterSearch(
            direct: ["/bin/sh"], launchers: ["/bin/bash"], launchersUsable: { false })
        let chosen = AdapterRuntime.chooseRunnable(
            "python3", pathEntries: [], search: search,
            identify: { identified.append($0); return nil })
        #expect(identified == ["/bin/sh"])
        #expect(chosen == nil, "nothing qualifies and PATH is empty: no interpreter, so setup refuses to wire")

        var asked = 0
        let usable = SystemInterpreterSearch(direct: [], launchers: ["/bin/bash"], launchersUsable: { asked += 1; return true })
        identified = []
        _ = AdapterRuntime.chooseRunnable(
            "python3", pathEntries: [], search: usable, identify: { identified.append($0); return nil })
        #expect(asked == 1)
        #expect(identified == ["/bin/bash"])
    }

    @Test func liveSearchTriesTheCommandLineToolsBeforeTheLauncher() {
        var asked = false
        let live = SystemInterpreterSearch.live("python3")
        #if os(macOS)
        #expect(live.direct == ["/Library/Developer/CommandLineTools/usr/bin/python3"])
        #expect(live.launchers == ["/usr/bin/python3"])
        #else
        #expect(live.direct == ["/usr/bin/python3"])
        #expect(live.launchers.isEmpty)
        #endif
        let off = SystemInterpreterSearch(direct: live.direct, launchers: live.launchers, launchersUsable: {
            asked = true
            return false
        })
        #expect(off.candidates() == live.direct)
        #expect(asked == (live.launchers.isEmpty == false))
    }

    @Test func identityParsesThreeAbsoluteLines() {
        #expect(InterpreterIdentity.parse("/a/python3.9\n/a\n/a/lib/os.py\n")
            == InterpreterIdentity(executable: "/a/python3.9", prefix: "/a", stdlib: "/a/lib/os.py"))
        #expect(InterpreterIdentity.parse("/a/python3.9\n/a\n") == nil)
        #expect(InterpreterIdentity.parse("/a/python3.9\nrelative\n/a/os.py\n") == nil)
        #expect(InterpreterIdentity.parse("/a\n/b\n/c\n/d\n") == nil)
        #expect(InterpreterIdentity.parse("") == nil)
    }

    /// The probe asks a real Python what it runs (skipped without one): the
    /// Command Line Tools' on macOS (no launcher, so no install prompt),
    /// `/usr/bin/python3` elsewhere. One that exists must answer.
    @Test func identifyReportsTheResolvedInterpreterOfARealPython() throws {
        #if os(macOS)
        let python = AdapterRuntime.commandLineToolsDirectory + "/python3"
        #else
        let python = "/usr/bin/python3"
        #endif
        guard FileManager.default.isExecutableFile(atPath: python) else { return }
        let identity = try #require(AdapterRuntime.identify(python), "\(python) did not say what it runs")
        #expect(identity.executable.hasPrefix("/"))
        #expect(AdapterRuntime.realPath(identity.executable) == identity.executable)
        #expect(identity.stdlib.hasSuffix("os.py") || identity.stdlib.hasSuffix("os.pyc"))
        #expect(AdapterRuntime.identify("/usr/bin/true") == nil, "prints nothing")
    }

    @Test func bakedPathKeepsASymlinkToTheRealInterpreterButNeverALauncher() throws {
        let dir = try realTemporaryDirectory("rv-bake")
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("python3.9")
        try makeExecutable(real, contents: "#!/bin/sh\nexit 0\n")
        let link = dir.appendingPathComponent("python3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let identity = InterpreterIdentity(executable: real.path, prefix: dir.path, stdlib: dir.path + "/os.py")
        #expect(AdapterRuntime.bakedPath(link.path, identity: identity) == link.path, "survives an upgrade behind it")
        #expect(AdapterRuntime.bakedPath("/usr/bin/python3", identity: identity) == real.path, "a launcher is not baked")
    }

    /// The resolved interpreter, not the launcher, must be root-owned, and
    /// neither it nor its standard library replaceable.
    @Test func systemInterpreterProtectionNeedsRootOwnershipAndNoWriteAccess() throws {
        let dir = try realTemporaryDirectory("rv-own")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = dir.appendingPathComponent("python3")
        try makeExecutable(mine, contents: "#!/bin/sh\nexit 0\n")
        func identity(_ executable: String, prefix: String = "/usr", stdlib: String = "/bin/sh") -> InterpreterIdentity {
            InterpreterIdentity(executable: executable, prefix: prefix, stdlib: stdlib)
        }
        #expect(AdapterRuntime.isProtectedSystemInterpreter(identity(mine.path)) == false)
        #expect(AdapterRuntime.isProtectedSystemInterpreter(identity(dir.appendingPathComponent("absent").path)) == false)
        // Launcher-style: a root-owned executable whose standard library
        // this user can write (Xcode.app's Python).
        #expect(AdapterRuntime.isProtectedSystemInterpreter(identity("/bin/sh", prefix: dir.path)) == false)
        #expect(AdapterRuntime.isProtectedSystemInterpreter(identity("/bin/sh", stdlib: mine.path)) == false)
        if getuid() != 0 {
            #expect(AdapterRuntime.isProtectedSystemInterpreter(identity("/bin/sh")))
        } else {
            #expect(AdapterRuntime.isProtectedSystemInterpreter(identity("/bin/sh")) == false, "root can replace anything")
        }
    }

    /// Root must own every directory, link and file on the path; a
    /// read-only directory this user owns is still theirs to chmod back.
    @Test func rootProtectionFollowsEverySymlinkHopAndOwner() throws {
        let dir = try realTemporaryDirectory("rv-hops")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path + "/ro")
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(AdapterRuntime.isRootProtected("relative/python3") == false)
        #expect(AdapterRuntime.isRootProtected(dir.path + "/absent") == false)

        // Two hops through a writable directory to a root-owned file.
        let second = dir.appendingPathComponent("second")
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: "/usr/bin/true")
        let first = dir.appendingPathComponent("first")
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: "second")
        #expect(AdapterRuntime.isRootProtected(first.path) == false)

        // A user-owned 0555 directory.
        let readOnly = dir.appendingPathComponent("ro")
        try makeExecutable(readOnly.appendingPathComponent("python3"), contents: "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        #expect(AdapterRuntime.isRootProtected(readOnly.appendingPathComponent("python3").path) == false)
        #expect(AdapterRuntime.userCanReplace(readOnly.appendingPathComponent("python3").path))

        guard getuid() != 0 else {
            #expect(AdapterRuntime.isRootProtected("/usr/bin/true") == false, "root can replace anything")
            return
        }
        #expect(AdapterRuntime.isRootProtected("/usr/bin/true"))
        #expect(AdapterRuntime.isRootProtected("/usr/bin/../bin/true"))
        // macOS: /etc is a root-owned link to private/etc.
        #expect(AdapterRuntime.isRootProtected("/etc/hosts"))
    }

    /// macOS starts the interpreter through SIP-protected /usr/bin/env, so
    /// dyld strips DYLD_* before the Command Line Tools' Python runs.
    @Test func hookCommandRendersAndParsesTheEnvLauncherForm() throws {
        let wrapped = AdapterCommand.render(interpreter: "/py dir/python3", adapterPath: "/a/rv-guard.py", throughEnv: true)
        #expect(wrapped == "/usr/bin/env '/py dir/python3' -I -S /a/rv-guard.py")
        let parsed = try #require(AdapterCommand.parse(Substring(wrapped)))
        #expect(parsed == AdapterCommand.Parsed(
            interpreter: "/py dir/python3", adapterPath: "/a/rv-guard.py", isolated: true, throughEnv: true))
        #expect(AdapterCommand.bakedInterpreter(in: Substring(wrapped)) == "/py dir/python3")
        #expect(AdapterCommand.adapterPath(in: wrapped) == "/a/rv-guard.py")

        let bare = AdapterCommand.render(interpreter: "/usr/bin/python3", adapterPath: "/a/g.py", throughEnv: false)
        #expect(bare == "/usr/bin/python3 -I -S /a/g.py")
        #expect(AdapterCommand.parse(Substring(bare))?.throughEnv == false)
        #expect(AdapterCommand.parse("/usr/bin/env python3 /a/g.py") == nil, "only the isolated form follows env")
        #if os(macOS)
        #expect(AdapterCommand.render(interpreter: "/p", adapterPath: "/a").hasPrefix("/usr/bin/env "))
        #else
        #expect(AdapterCommand.render(interpreter: "/p", adapterPath: "/a") == "/p -I -S /a")
        #endif
        let rvCommand = SettingsMergePolicy.hookCommand(rvPath: "/r", interpreter: "/p", adapterPath: "/a")
        #expect(SettingsMergePolicy.bakedInterpreter(in: rvCommand) == "/p")
        #expect(SettingsMergePolicy.parseCommand(rvCommand)?.adapterPath == "/a")
    }

    /// The rendered command, run as a host runs it, loads no DYLD_* request
    /// (skipped without the Command Line Tools' Python).
    @Test func renderedHookCommandStripsDyldVariables() throws {
        #if os(macOS)
        let python = AdapterRuntime.commandLineToolsDirectory + "/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else { return }
        let dir = try realTemporaryDirectory("rv-dyld")
        defer { try? FileManager.default.removeItem(at: dir) }
        let adapter = dir.appendingPathComponent("noop.py")
        try "pass\n".write(to: adapter, atomically: true, encoding: .utf8)
        // Exec'd directly, as the host does: a SIP-protected `/bin/sh` in
        // between would strip the variable itself.
        func dyldLines(_ executable: String, _ arguments: [String]) throws -> Int {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ["DYLD_PRINT_LIBRARIES": "1", "PATH": "/usr/bin:/bin"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").count
        }
        let rendered = try #require(
            AdapterCommand.parse(Substring(AdapterCommand.render(interpreter: python, adapterPath: adapter.path))))
        #expect(rendered.throughEnv)
        let flags: [String] = AdapterCommand.isolationFlags.split(separator: " ").map { String($0) }
        #expect(try dyldLines(AdapterCommand.envLauncher, [rendered.interpreter] + flags + [rendered.adapterPath]) == 0)
        #expect(try dyldLines(python, flags + [adapter.path]) > 0, "the variable does reach an unwrapped interpreter")
        #endif
    }

    @Test func doctorWarnsWhenAMacOSHookStartsAnUnprotectedInterpreterWithoutEnv() {
        let clt = AdapterRuntime.BakedInterpreter(
            path: "/Library/Developer/CommandLineTools/usr/bin/python3", throughEnv: false)
        #expect(AdapterRuntime.dyldExposed(clt, launchesThroughEnv: true))
        #expect(AdapterRuntime.dyldExposed(clt, launchesThroughEnv: false) == false, "Linux has no dyld")
        var wrapped = clt
        wrapped.throughEnv = true
        #expect(AdapterRuntime.dyldExposed(wrapped, launchesThroughEnv: true) == false)
        let shim = AdapterRuntime.BakedInterpreter(path: "/usr/bin/python3", throughEnv: false)
        #expect(AdapterRuntime.dyldExposed(shim, launchesThroughEnv: true) == false, "a SIP-protected binary")
        let legacy = AdapterRuntime.BakedInterpreter(path: "python3", throughEnv: false)
        #expect(AdapterRuntime.dyldExposed(legacy, launchesThroughEnv: true) == false)
    }

    @Test func doctorReportsAnUnwrappedHookCommand() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(atPath: layout.codexDirectory, withIntermediateDirectories: true)
            var environment = env(home: home, launchctl: launchctl)
            environment.resolveInterpreter = { _ in "/opt/py/bin/python3" }
            #expect(SetupRun.setup(environment).exitCode == 0)
            // An earlier fix round's command: the interpreter without env.
            let text = try String(contentsOfFile: layout.codexHooksJSON, encoding: .utf8)
                .replacingOccurrences(of: "/usr/bin/env ", with: "")
            try text.write(toFile: layout.codexHooksJSON, atomically: true, encoding: .utf8)
            let hosts = try HostAdapterInstallation.inspect(paths: layout, pathEntries: [], fileManager: .default)
            var probes = DoctorInstallProbes(userID: getuid(), launchd: nil, trustManifest: .notApplicable)
            probes.launchesThroughEnv = true
            let problems = DoctorInstallChecks.adapterRuntime(
                hosts: hosts, paths: layout, fileManager: .default, probes: probes)
            #expect(problems.map(\.id) == ["adapter-runtime-dyld-codex"])
            #expect(problems.first?.fix == "rerun rv setup")
            #expect(problems.first?.severity == .warn)
        }
    }

    /// Doctor applies setup's check to whatever is baked.
    @Test func doctorReplaceableCheckFollowsTheBakedInterpreterToWhatItRuns() throws {
        let dir = try realTemporaryDirectory("rv-doc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = dir.appendingPathComponent("python3")
        try makeExecutable(mine, contents: "#!/bin/sh\nexit 0\n")
        #expect(AdapterRuntime.isReplaceableInterpreter(mine.path, identify: { _ in nil }))
        #expect(AdapterRuntime.isReplaceableInterpreter("/bin/sh", identify: { _ in nil }), "silent: replaceable")
        let xcode = InterpreterIdentity(executable: mine.path, prefix: dir.path, stdlib: dir.path + "/os.py")
        #expect(AdapterRuntime.isReplaceableInterpreter("/bin/sh", identify: { _ in xcode }))
        guard getuid() != 0 else { return }
        let system = InterpreterIdentity(executable: "/bin/sh", prefix: "/usr", stdlib: "/bin/sh")
        #expect(AdapterRuntime.isReplaceableInterpreter("/bin/sh", identify: { _ in system }) == false)
    }

    @Test func doctorFailsEachHookedPythonHostWhenPython3DoesNotRun() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(atPath: layout.claudeDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(env(home: home, launchctl: launchctl)).exitCode == 0)
            let hosts = try HostAdapterInstallation.inspect(
                paths: layout, pathEntries: [], fileManager: .default)
            var probes = DoctorInstallProbes(userID: getuid(), launchd: nil, trustManifest: .notApplicable)
            var asked: [String] = []
            probes.interpreterRunnable = { asked.append($0); return false }
            let problems = DoctorInstallChecks.adapterRuntime(
                hosts: hosts, paths: layout, fileManager: .default, probes: probes)
            #expect(asked == ["/usr/bin/python3"], "the baked interpreter, not PATH")
            #expect(problems.map(\.id) == ["adapter-runtime-claude"])
            #expect(problems.first?.severity == .fail)
            #expect(problems.first?.summary.contains("/usr/bin/python3, which is not runnable") == true)

            probes.interpreterRunnable = { _ in true }
            #expect(DoctorInstallChecks.adapterRuntime(
                hosts: hosts, paths: layout, fileManager: .default, probes: probes).isEmpty)
        }
    }

    @Test func doctorFailsWhenTheBakedInterpreterIsGone() throws {
        try withTempHome { home, layout, launchctl in
            for directory in [layout.claudeDirectory, layout.codexDirectory] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            let python = URL(fileURLWithPath: home.path + "/py/bin/python3")
            try FileManager.default.createDirectory(
                at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
            try makeExecutable(python, contents: "#!/bin/sh\nexit 0\n")
            var environment = env(home: home, launchctl: launchctl)
            environment.resolveInterpreter = { AdapterRuntime.resolveRunnable($0, pathEntries: [python.deletingLastPathComponent().path]) }
            #expect(SetupRun.setup(environment).exitCode == 0)
            let hosts = try HostAdapterInstallation.inspect(paths: layout, pathEntries: [], fileManager: .default)
            var probes = DoctorInstallProbes(userID: getuid(), launchd: nil, trustManifest: .notApplicable)
            // A PATH python3 that runs does not hide a missing baked one.
            probes.interpreterRunnable = { $0 == "python3" || AdapterRuntime.liveRunnable($0, pathEntries: []) }
            #expect(DoctorInstallChecks.adapterRuntime(
                hosts: hosts, paths: layout, fileManager: .default, probes: probes).isEmpty)

            // In a directory this user can write, the interpreter is swappable.
            probes.interpreterReplaceable = AdapterRuntime.userCanReplace
            let swappable = DoctorInstallChecks.adapterRuntime(
                hosts: hosts, paths: layout, fileManager: .default, probes: probes)
            #expect(swappable.map(\.id) == ["adapter-runtime-replaceable-claude", "adapter-runtime-replaceable-codex"])
            #expect(swappable.allSatisfy { $0.severity == .warn })
            #expect(swappable.allSatisfy { $0.fix == DoctorInstallChecks.replaceableFix(python.path, name: "python3", userID: getuid()) })
            if getuid() != 0 {
                #expect(AdapterRuntime.userCanReplace("/bin/sh") == false)
            }

            try FileManager.default.removeItem(at: python)
            let problems = DoctorInstallChecks.adapterRuntime(
                hosts: hosts, paths: layout, fileManager: .default, probes: probes)
            #expect(problems.map(\.id) == ["adapter-runtime-claude", "adapter-runtime-codex"])
            #expect(problems.allSatisfy { $0.severity == .fail && $0.summary.contains(python.path) })
        }
    }

    /// The fix must not tell the user to use the interpreter they already
    /// use: root can replace /usr/bin/python3 itself.
    @Test func replaceableFixFitsWhoCanReplaceWhat() {
        let root = DoctorInstallChecks.replaceableFix("/usr/bin/python3", name: "python3", userID: 0)
        #expect(root.contains("not root"))
        #expect(root.contains("first on PATH") == false)
        let rootElsewhere = DoctorInstallChecks.replaceableFix("/home/u/py/bin/python3", name: "python3", userID: 0)
        #expect(rootElsewhere == root)
        // macOS: setup bakes the Command Line Tools' Python, whatever was
        // baked before (Homebrew, Xcode.app, the launcher).
        let bakes = "it bakes the Command Line Tools' python3 "
            + "(/Library/Developer/CommandLineTools/usr/bin/python3), which this user cannot replace"
        for baked in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3", "/Users/u/py/python3"] {
            let fix = DoctorInstallChecks.replaceableFix(
                baked, name: "python3", userID: 501, macOS: true, commandLineToolsInstalled: false)
            #expect(fix == "install the Command Line Tools (xcode-select --install) and rerun rv setup: " + bakes)
            #expect(fix.contains("chown") == false)
            // Already installed: setup only needs to run again.
            #expect(DoctorInstallChecks.replaceableFix(
                baked, name: "python3", userID: 501, macOS: true, commandLineToolsInstalled: true)
                == "rerun rv setup: " + bakes)
        }
        let linuxUser = DoctorInstallChecks.replaceableFix(
            "/home/u/py/bin/python3", name: "python3", userID: 1000, macOS: false)
        #expect(linuxUser == "install python3 with your package manager (e.g. apt install python3) and rerun "
            + "rv setup: it bakes /usr/bin/python3 when this user cannot replace it")
        let writableSystem = DoctorInstallChecks.replaceableFix(
            "/usr/bin/python3", name: "python3", userID: 1000, macOS: false)
        #expect(writableSystem.contains("first on PATH") == false)
        #expect(writableSystem.contains("writable only by root"))
    }
}

/// A fresh directory under the temporary directory, by its real path
/// (`/var` is a symlink on macOS), so `realpath` comparisons hold.
private func realTemporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: AdapterRuntime.realPath(url.path) ?? url.path)
}
