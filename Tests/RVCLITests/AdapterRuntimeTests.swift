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
            #expect(codex.contains("\"/opt/py/bin/python3 -I -S \(layout.codexHook)\""))
            let cursor = try String(contentsOfFile: layout.cursorHooksJSON, encoding: .utf8)
            #expect(cursor.contains("\"/opt/py/bin/python3 -I -S \(layout.cursorHook)\""))
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
}
