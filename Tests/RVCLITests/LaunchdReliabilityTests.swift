import Foundation
import Testing
@testable import RVCLI

/// Scripted launchctl: per-domain bootstrap failures, bootout that lingers in
/// `print` for a few polls, optional missing gui domain, kickstart recording.
final class ScriptedLaunchctl: LaunchctlApplying {
    var guiExists = true
    /// Exit statuses thrown by successive `bootstrap` calls into a domain.
    var bootstrapFailures: [String: [Int32]] = [:]
    /// Domains where the job is currently registered.
    var loaded: Set<String> = []
    /// `isLoaded` keeps reporting a booted-out job for this many polls.
    var lingerPolls = 0
    var kickstartError: Int32?

    private(set) var events: [String] = []
    private(set) var bootstrapDomains: [String] = []
    private(set) var bootstrapWhileLingering = false
    private var lingering: [String: Int] = [:]

    func bootstrap(domain: String, plist _: URL) throws {
        events.append("bootstrap \(domain)")
        bootstrapDomains.append(domain)
        if lingering.values.contains(where: { $0 > 0 }) {
            bootstrapWhileLingering = true
        }
        if var queue = bootstrapFailures[domain], queue.isEmpty == false {
            let status = queue.removeFirst()
            bootstrapFailures[domain] = queue
            throw LaunchctlError.nonZeroExit(status)
        }
        loaded.insert(domain)
    }

    func bootout(domain: String, label _: String) throws {
        events.append("bootout \(domain)")
        if loaded.remove(domain) != nil, lingerPolls > 0 {
            lingering[domain] = lingerPolls
        }
    }

    func isLoaded(domain: String, label _: String) -> Bool {
        if let remaining = lingering[domain], remaining > 0 {
            lingering[domain] = remaining - 1
            return true
        }
        return loaded.contains(domain)
    }

    func domainExists(_ domain: String) -> Bool {
        domain.hasPrefix("gui/") ? guiExists : true
    }

    func kickstart(domain: String, label: String) throws {
        events.append("kickstart \(domain)/\(label)")
        if let kickstartError {
            throw LaunchctlError.nonZeroExit(kickstartError)
        }
    }
}

private final class SleepLog {
    private(set) var naps: [TimeInterval] = []
    var total: TimeInterval { naps.reduce(0, +) }
    func record(_ seconds: TimeInterval) { naps.append(seconds) }
}

private func scriptedEnv(
    home: URL,
    launchctl: ScriptedLaunchctl,
    sleeps: SleepLog,
    rvdPath: String? = nil
) -> SetupEnvironment {
    var environment = env(home: home, launchctl: launchctl, rvdPath: rvdPath)
    environment.uid = { 501 }
    environment.sleep = { sleeps.record($0) }
    return environment
}

// MARK: - Robust bootstrap

@Test func bootstrap_exit5RightAfterBootout_retriesGuiAndSucceeds() throws {
    try withTempHome { home, layout, _ in
        let launchctl = ScriptedLaunchctl()
        launchctl.loaded = ["gui/501"]
        launchctl.lingerPolls = 2
        launchctl.bootstrapFailures = ["gui/501": [5]]
        let sleeps = SleepLog()

        let outcome = SetupRun.setup(scriptedEnv(home: home, launchctl: launchctl, sleeps: sleeps))

        #expect(outcome.exitCode == 0)
        #expect(outcome.stderr.isEmpty)
        #expect(launchctl.bootstrapDomains == ["gui/501", "gui/501"])
        #expect(launchctl.bootstrapWhileLingering == false)
        #expect(launchctl.loaded == ["gui/501"])
        #expect(sleeps.total <= 3.0 + 1e-9)
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent))
    }
}

@Test func bootstrap_waitsForBootoutButGivesUpWithinThreeSeconds() throws {
    try withTempHome { home, _, _ in
        let launchctl = ScriptedLaunchctl()
        launchctl.loaded = ["gui/501"]
        launchctl.lingerPolls = 10_000
        let sleeps = SleepLog()

        let outcome = SetupRun.setup(scriptedEnv(home: home, launchctl: launchctl, sleeps: sleeps))

        #expect(outcome.exitCode == 0)
        #expect(launchctl.bootstrapDomains.first == "gui/501")
        // Bounded unload wait (≤3 s) plus at most the retry backoff.
        let pollSleeps = sleeps.naps.prefix(while: { $0 < 0.2 })
        #expect(pollSleeps.reduce(0, +) <= 3.0 + 1e-9)
        #expect(pollSleeps.reduce(0, +) >= 2.5)
    }
}

@Test func bootstrap_guiDomainMissing_landsInUserDomain() throws {
    try withTempHome { home, _, _ in
        let launchctl = ScriptedLaunchctl()
        launchctl.guiExists = false
        let sleeps = SleepLog()

        let outcome = SetupRun.setup(scriptedEnv(home: home, launchctl: launchctl, sleeps: sleeps))

        #expect(outcome.exitCode == 0)
        #expect(launchctl.bootstrapDomains == ["user/501"])
    }
}

@Test func bootstrap_guiPresentButPersistentFailure_errorsInsteadOfUserFallback() throws {
    try withTempHome { home, layout, _ in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        let launchctl = ScriptedLaunchctl()
        launchctl.bootstrapFailures = ["gui/501": [5, 5, 5, 5, 5]]
        let sleeps = SleepLog()

        let outcome = SetupRun.setup(scriptedEnv(home: home, launchctl: launchctl, sleeps: sleeps))

        #expect(outcome.exitCode == EX_UNAVAILABLE)
        #expect(launchctl.bootstrapDomains == ["gui/501", "gui/501", "gui/501"])
        #expect(launchctl.bootstrapDomains.contains("user/501") == false)
        #expect(outcome.stderr.hasPrefix("rv setup failed: unable to load LaunchAgent\n"))
        #expect(outcome.stderr.contains("fix: "))
        // Two backoffs between three attempts.
        #expect(sleeps.naps.filter { $0 >= 0.2 }.count == 2)
    }
}

// MARK: - Setup runs from the installed copy

@Test func setup_fromBuildTreeAgainstRealLaunchd_refusesWithInstalledCopyHint() throws {
    try withTempHome { home, layout, _ in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        let launchctl = ScriptedLaunchctl()
        let sleeps = SleepLog()
        var environment = scriptedEnv(home: home, launchctl: launchctl, sleeps: sleeps)
        environment.rvPath = layout.localRv
        environment.runningExecutable = "/src/rv/.build/release/rv-cli"

        let outcome = SetupRun.setup(environment)

        #expect(outcome.exitCode == EX_USAGE)
        #expect(outcome.stderr.contains("/src/rv/.build/release/rv-cli"))
        #expect(outcome.stderr.contains("run \(layout.localRv) setup"))
        #expect(launchctl.events.isEmpty)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent) == false)
    }
}

@Test func setup_fromInstalledBinDir_proceedsAndPlistNamesHookSiblingRvd() throws {
    try withTempHome { home, layout, _ in
        try makeExecutable(URL(fileURLWithPath: layout.localRvd))
        let launchctl = ScriptedLaunchctl()
        let sleeps = SleepLog()
        var environment = scriptedEnv(
            home: home,
            launchctl: launchctl,
            sleeps: sleeps,
            rvdPath: SetupEnvironment.resolveRvd(home: home.path)
        )
        environment.rvPath = layout.localRv
        environment.runningExecutable = layout.localRvCli

        let outcome = SetupRun.setup(environment)

        #expect(outcome.exitCode == 0)
        let plist = try String(contentsOfFile: layout.launchAgent, encoding: .utf8)
        #expect(plist.contains("<string>\(layout.localRvd)</string>"))
    }
}

@Test func setup_fromBuildTreeInTempHome_doesNotTouchLaunchdSoIsAllowed() throws {
    try withTempHome { home, _, _ in
        var environment = env(home: home, launchctl: ScriptedLaunchctl(), touchLaunchd: false)
        environment.runningExecutable = "/src/rv/.build/debug/rv-cli"
        #expect(SetupRun.setup(environment).exitCode == 0)
    }
}

// MARK: - rv service restart

@Test func restart_loadedInGui_kickstartsGui() throws {
    try withTempHome { home, _, _ in
        let launchctl = ScriptedLaunchctl()
        launchctl.loaded = ["gui/501"]
        let outcome = ServiceRestart.run(scriptedEnv(home: home, launchctl: launchctl, sleeps: SleepLog()))
        #expect(outcome.exitCode == 0)
        #expect(launchctl.events.contains("kickstart gui/501/dev.rv.evaluate"))
        #expect(launchctl.bootstrapDomains.isEmpty)
        #expect(outcome.stdout.contains("gui/501"))
    }
}

@Test func restart_loadedInUserWithoutAqua_kickstartsUser() throws {
    try withTempHome { home, _, _ in
        let launchctl = ScriptedLaunchctl()
        launchctl.guiExists = false
        launchctl.loaded = ["user/501"]
        let outcome = ServiceRestart.run(scriptedEnv(home: home, launchctl: launchctl, sleeps: SleepLog()))
        #expect(outcome.exitCode == 0)
        #expect(launchctl.events == ["kickstart user/501/dev.rv.evaluate"])
    }
}

@Test func restart_strandedInUserWhileAquaExists_reloadsIntoGui() throws {
    try withTempHome { home, layout, _ in
        try makeExecutable(URL(fileURLWithPath: layout.localRvd))
        let launchctl = ScriptedLaunchctl()
        launchctl.loaded = ["user/501"]
        let outcome = ServiceRestart.run(
            scriptedEnv(home: home, launchctl: launchctl, sleeps: SleepLog(), rvdPath: layout.localRvd)
        )
        #expect(outcome.exitCode == 0)
        #expect(launchctl.events.contains("bootout user/501"))
        #expect(launchctl.bootstrapDomains == ["gui/501"])
        #expect(launchctl.loaded == ["gui/501"])
        #expect(outcome.stdout.contains("gui/501"))
    }
}

@Test func restart_notLoaded_rewritesPlistAndBootstrapsGui() throws {
    try withTempHome { home, layout, _ in
        try makeExecutable(URL(fileURLWithPath: layout.localRvd))
        let launchctl = ScriptedLaunchctl()
        let outcome = ServiceRestart.run(
            scriptedEnv(home: home, launchctl: launchctl, sleeps: SleepLog(), rvdPath: layout.localRvd)
        )
        #expect(outcome.exitCode == 0)
        #expect(launchctl.bootstrapDomains == ["gui/501"])
        let plist = try String(contentsOfFile: layout.launchAgent, encoding: .utf8)
        #expect(plist.contains("<string>\(layout.localRvd)</string>"))
    }
}

@Test func restart_kickstartFails_fallsBackToReload() throws {
    try withTempHome { home, layout, _ in
        try makeExecutable(URL(fileURLWithPath: layout.localRvd))
        let launchctl = ScriptedLaunchctl()
        launchctl.loaded = ["gui/501"]
        launchctl.kickstartError = 1
        let outcome = ServiceRestart.run(
            scriptedEnv(home: home, launchctl: launchctl, sleeps: SleepLog(), rvdPath: layout.localRvd)
        )
        #expect(outcome.exitCode == 0)
        #expect(launchctl.bootstrapDomains == ["gui/501"])
    }
}

@Test func restart_notLoadedAndRvdMissing_failsWithReinstallHint() throws {
    try withTempHome { home, layout, _ in
        let launchctl = ScriptedLaunchctl()
        let outcome = ServiceRestart.run(
            scriptedEnv(home: home, launchctl: launchctl, sleeps: SleepLog(), rvdPath: layout.localRvd)
        )
        #expect(outcome.exitCode == EX_UNAVAILABLE)
        #expect(outcome.stderr.contains("rvd not found at \(layout.localRvd)"))
        #expect(outcome.stderr.contains("fix: reinstall rv"))
        #expect(launchctl.bootstrapDomains.isEmpty)
    }
}

@Test func restart_reloadBootstrapFails_failsWithFixHint() throws {
    try withTempHome { home, layout, _ in
        try makeExecutable(URL(fileURLWithPath: layout.localRvd))
        let launchctl = ScriptedLaunchctl()
        launchctl.bootstrapFailures = ["gui/501": [5, 5, 5]]
        let outcome = ServiceRestart.run(
            scriptedEnv(home: home, launchctl: launchctl, sleeps: SleepLog(), rvdPath: layout.localRvd)
        )
        #expect(outcome.exitCode == EX_UNAVAILABLE)
        #expect(outcome.stderr.hasPrefix("rv service restart failed: unable to load LaunchAgent\n"))
        #expect(outcome.stderr.contains("fix: "))
    }
}

@Test func restart_foreignHome_refusesWithoutTouchingLaunchd() throws {
    try withTempHome { home, _, _ in
        let launchctl = ScriptedLaunchctl()
        var environment = scriptedEnv(home: home, launchctl: launchctl, sleeps: SleepLog())
        environment.touchLaunchd = false
        let outcome = ServiceRestart.run(environment)
        #expect(outcome.exitCode != 0)
        #expect(outcome.stderr.contains("login"))
        #expect(launchctl.events.isEmpty)
    }
}

// MARK: - ProcessLaunchctl argv

private func recordingTool(exit status: Int32) throws -> (tool: URL, log: URL) {
    let log = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-launchctl-argv-\(UUID().uuidString).log")
    let tool = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-launchctl-\(UUID().uuidString)")
    try writeExecutableScript(
        at: tool,
        source: "#!/bin/sh\necho \"$@\" >> '\(log.path)'\nexit \(status)\n"
    )
    return (tool, log)
}

@Test func processLaunchctl_domainExistsAndKickstartArgv() throws {
    let ok = try recordingTool(exit: 0)
    defer {
        try? FileManager.default.removeItem(at: ok.tool)
        try? FileManager.default.removeItem(at: ok.log)
    }
    let launchctl = ProcessLaunchctl(executableURL: ok.tool)
    #expect(launchctl.domainExists("gui/501"))
    try launchctl.kickstart(domain: "gui/501", label: "dev.rv.evaluate")
    let argv = try String(contentsOf: ok.log, encoding: .utf8)
    #expect(argv == "print gui/501\nkickstart -k gui/501/dev.rv.evaluate\n")

    let failing = try recordingTool(exit: 113)
    defer {
        try? FileManager.default.removeItem(at: failing.tool)
        try? FileManager.default.removeItem(at: failing.log)
    }
    let missing = ProcessLaunchctl(executableURL: failing.tool)
    #expect(missing.domainExists("gui/501") == false)
    #expect(throws: LaunchctlError.nonZeroExit(113)) {
        try missing.kickstart(domain: "gui/501", label: "dev.rv.evaluate")
    }
}
