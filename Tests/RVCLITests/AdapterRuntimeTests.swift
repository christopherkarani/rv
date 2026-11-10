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
            environment.interpreterRunnable = { asked.append($0); return false }
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
            environment.interpreterRunnable = { _ in asked = true; return false }
            let outcome = SetupRun.setup(environment)
            #expect(outcome.exitCode == 0)
            #expect(asked == false)
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

    @Test func doctorFailsEachHookedPythonHostWhenPython3DoesNotRun() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(atPath: layout.claudeDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(env(home: home, launchctl: launchctl)).exitCode == 0)
            let hosts = try HostAdapterInstallation.inspect(
                paths: layout, pathEntries: [], fileManager: .default)
            var probes = DoctorInstallProbes(userID: getuid(), launchd: nil, trustManifest: .notApplicable)
            probes.interpreterRunnable = { _ in false }
            let problems = DoctorInstallChecks.adapterRuntime(hosts: hosts, probes: probes)
            #expect(problems.map(\.id) == ["adapter-runtime-claude"])
            #expect(problems.first?.severity == .fail)
            #expect(problems.first?.summary.contains("python3, which is not runnable") == true)

            probes.interpreterRunnable = { _ in true }
            #expect(DoctorInstallChecks.adapterRuntime(hosts: hosts, probes: probes).isEmpty)
        }
    }
}
