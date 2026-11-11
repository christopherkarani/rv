#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import RVCLI

/// Linux with no systemd user manager (WSL without systemd, containers,
/// OpenRC/runit, logins without logind): setup and `rv service` run rvd
/// directly instead of failing on `systemctl --user`.
@Suite struct LinuxNoSystemdTests {
    private func linuxEnv(
        home: URL,
        launchctl: RecordingLaunchctl,
        systemctl: RecordingSystemctl,
        direct: RecordingDirectRvd,
        answersNow: Bool = false
    ) -> SetupEnvironment {
        var environment = env(
            home: home, launchctl: launchctl, touchLaunchd: false,
            systemctl: systemctl, touchSystemd: true, supervisor: .systemdUser)
        environment.directRvd = direct
        environment.serviceAnswersNow = { answersNow }
        return environment
    }

    @Test func setupWithoutUserManagerStartsRvdDirectlyAndSaysItWillNotSurviveReboot() throws {
        try withTempHome { home, layout, launchctl in
            let systemctl = RecordingSystemctl(reachable: false)
            let direct = RecordingDirectRvd()
            let environment = linuxEnv(home: home, launchctl: launchctl, systemctl: systemctl, direct: direct)
            let outcome = SetupRun.setup(environment)
            #expect(outcome.exitCode == 0)
            #expect(systemctl.enabled.isEmpty)
            // The unit stays written for a later login that has systemd.
            #expect(FileManager.default.fileExists(atPath: layout.systemdUserUnit))
            let rvd = environment.rvdPath
            #expect(direct.events == ["stop \(rvd)", "start \(rvd)"])
            #expect(outcome.stderr.contains("rv setup: no systemd user manager is running"))
            #expect(outcome.stderr.contains("rv started rvd directly"))
            #expect(outcome.stderr.contains("will not survive logout or reboot"))
            #expect(outcome.stderr.contains("/tmp/rv-bin/rv service start >/dev/null"))
            #expect(outcome.stderr.contains("\(rvd) --socket --idle-exit-seconds=31536000"))
        }
    }

    @Test func setupKeepsAnRvdThatAlreadyAnswers() throws {
        try withTempHome { home, _, launchctl in
            let direct = RecordingDirectRvd()
            let environment = linuxEnv(
                home: home, launchctl: launchctl, systemctl: RecordingSystemctl(reachable: false),
                direct: direct, answersNow: true)
            #expect(SetupRun.setup(environment).exitCode == 0)
            #expect(direct.events.isEmpty)
        }
    }

    @Test func setupWithAUserManagerNeverRunsRvdDirectly() throws {
        try withTempHome { home, _, launchctl in
            let systemctl = RecordingSystemctl(reachable: true)
            let direct = RecordingDirectRvd()
            let outcome = SetupRun.setup(
                linuxEnv(home: home, launchctl: launchctl, systemctl: systemctl, direct: direct))
            #expect(outcome.exitCode == 0)
            #expect(systemctl.enabled == [SystemdUserTemplate.unitName])
            #expect(direct.events.isEmpty)
            #expect(outcome.stderr.contains("no systemd user manager") == false)
        }
    }

    @Test func directStartFailureWiresNothingAndNamesTheCommand() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(atPath: layout.claudeDirectory, withIntermediateDirectories: true)
            let direct = RecordingDirectRvd()
            direct.startError = DirectRvdError.spawnFailed(ENOEXEC)
            var environment = linuxEnv(
                home: home, launchctl: launchctl, systemctl: RecordingSystemctl(reachable: false), direct: direct)
            environment.resolveInterpreter = { "/usr/bin/" + $0 }
            let outcome = SetupRun.setup(environment)
            #expect(outcome.exitCode == EX_UNAVAILABLE)
            #expect(outcome.stderr.hasPrefix(
                "rv setup failed: unable to start rvd (no systemd user manager is running, so rv starts rvd itself)\n"))
            #expect(outcome.stderr.contains("no hooks were wired"))
            #expect(outcome.stderr.contains("\(environment.rvdPath) --socket --idle-exit-seconds=31536000"))
            #expect(FileManager.default.fileExists(atPath: layout.claudeSettings) == false)
        }
    }

    @Test func aDirectRvdThatDoesNotAnswerPointsAtItsLog() throws {
        try withTempHome { home, _, launchctl in
            var environment = linuxEnv(
                home: home, launchctl: launchctl, systemctl: RecordingSystemctl(reachable: false),
                direct: RecordingDirectRvd())
            environment.serviceAnswers = { false }
            let outcome = SetupRun.setup(environment)
            #expect(outcome.exitCode == EX_UNAVAILABLE)
            #expect(outcome.stderr.contains("rvd did not answer within 10 seconds of starting it"))
            #expect(outcome.stderr.contains(home.path + "/.local/state/rv/rvd.log"))
            #expect(outcome.stderr.contains("systemctl") == false)
        }
    }

    @Test func setupJSONReportsTheDirectService() throws {
        try withTempHome { home, _, launchctl in
            let environment = linuxEnv(
                home: home, launchctl: launchctl, systemctl: RecordingSystemctl(reachable: false),
                direct: RecordingDirectRvd())
            let outcome = SetupRun.setup(environment, json: true)
            #expect(outcome.exitCode == 0)
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any])
            #expect(object["schema"] as? String == "rv.setup.v1")
            #expect(object["service"] as? String == "direct")
        }
    }

    @Test func uninstallStopsADirectRvd() throws {
        try withTempHome { home, _, launchctl in
            let direct = RecordingDirectRvd()
            let environment = linuxEnv(
                home: home, launchctl: launchctl, systemctl: RecordingSystemctl(reachable: false), direct: direct)
            #expect(SetupRun.setup(environment).exitCode == 0)
            #expect(SetupRun.uninstall(environment).exitCode == 0)
            #expect(direct.events.last == "stop \(environment.rvdPath)")
        }
    }

    @Test func restartWithoutUserManagerBouncesTheDirectRvd() throws {
        try withTempHome { home, _, launchctl in
            let direct = RecordingDirectRvd()
            let environment = linuxEnv(
                home: home, launchctl: launchctl, systemctl: RecordingSystemctl(reachable: false),
                direct: direct, answersNow: true)
            let outcome = ServiceRestart.run(environment)
            #expect(outcome.exitCode == 0)
            #expect(outcome.stdout == "rv service restart: rvd is running\n")
            #expect(outcome.stderr.contains("rv service restart: no systemd user manager is running"))
            #expect(direct.events == ["stop \(environment.rvdPath)", "start \(environment.rvdPath)"])
        }
    }

    @Test func startLeavesAnAnsweringRvdAloneAndStartsAMissingOne() throws {
        try withTempHome { home, _, launchctl in
            let running = RecordingDirectRvd()
            let up = ServiceRestart.run(
                linuxEnv(
                    home: home, launchctl: launchctl, systemctl: RecordingSystemctl(reachable: false),
                    direct: running, answersNow: true),
                onlyIfStopped: true)
            #expect(up == SetupOutcome(stdout: "rv service start: rvd is already running\n", exitCode: 0))
            #expect(running.events.isEmpty)

            let stopped = RecordingDirectRvd()
            let down = ServiceRestart.run(
                linuxEnv(
                    home: home, launchctl: launchctl, systemctl: RecordingSystemctl(reachable: false),
                    direct: stopped, answersNow: false),
                onlyIfStopped: true)
            #expect(down.exitCode == 0)
            #expect(down.stdout == "rv service start: rvd is running\n")
            #expect(stopped.events.count == 2)
        }
    }

    @Test func restartWithAUserManagerUsesSystemctl() throws {
        try withTempHome { home, _, launchctl in
            let systemctl = RecordingSystemctl(reachable: true)
            let direct = RecordingDirectRvd()
            let environment = linuxEnv(home: home, launchctl: launchctl, systemctl: systemctl, direct: direct)
            let restart = ServiceRestart.run(environment)
            #expect(restart == SetupOutcome(
                stdout: "rv service restart: restarted dev.rv.evaluate.service (systemctl --user)\n", exitCode: 0))
            let start = ServiceRestart.run(environment, onlyIfStopped: true)
            #expect(start.stdout == "rv service start: started dev.rv.evaluate.service (systemctl --user)\n")
            #expect(systemctl.restarted == [SystemdUserTemplate.unitName])
            #expect(systemctl.started == [SystemdUserTemplate.unitName])
            #expect(direct.events.isEmpty)
        }
    }

    @Test func restartFailuresAreWordedForTheirPath() throws {
        try withTempHome { home, _, launchctl in
            var environment = linuxEnv(
                home: home, launchctl: launchctl, systemctl: RecordingSystemctl(reachable: true),
                direct: RecordingDirectRvd())
            environment.systemctl = FailingSystemctl()
            let failed = ServiceRestart.run(environment)
            #expect(failed.exitCode == EX_UNAVAILABLE)
            #expect(failed.stderr.hasPrefix("rv service restart failed: unable to restart systemd unit\n"))

            environment.touchSystemd = false
            let foreign = ServiceRestart.run(environment)
            #expect(foreign.exitCode == EX_USAGE)
            #expect(foreign.stderr.contains("refusing to touch the service"))
        }
    }

    /// `ProcessDirectRvd` finds this user's copies of the installed rvd,
    /// including one an upgrade replaced, and nothing else.
    @Test func directRvdMatchesTheInstalledBinaryAndItsReplacedCopy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-proc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rvd = "/home/u/.local/bin/rvd"
        for (pid, target) in [("101", rvd), ("102", rvd + " (deleted)"), ("103", "/usr/bin/python3")] {
            let directory = root.appendingPathComponent(pid, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: directory.appendingPathComponent("exe").path, withDestinationPath: target)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("self", isDirectory: true), withIntermediateDirectories: true)
        let pids = ProcessDirectRvd.matchingPIDs(rvdPath: rvd, procRoot: root.path, uid: getuid())
        #expect(pids.sorted() == [101, 102])
        #expect(ProcessDirectRvd.matchingPIDs(rvdPath: rvd, procRoot: root.path, uid: getuid() + 1).isEmpty)
    }

    /// The spawned daemon gets its own session (it outlives the terminal)
    /// and rvd's resident arguments.
    @Test func directRvdStartsInItsOwnSessionWithTheResidentArguments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-direct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("out")
        let fake = root.appendingPathComponent("rvd")
        try writeExecutableScript(
            at: fake,
            source: "#!/bin/sh\n{ echo \"$*\"; echo $$; cut -d' ' -f6 /proc/$$/stat; } > '\(out.path).tmp'\n"
                + "mv '\(out.path).tmp' '\(out.path)'\n")
        try ProcessDirectRvd().start(rvdPath: fake.path)
        let deadline = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: out.path) == false, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.first == DirectRvd.arguments.joined(separator: " "))
        #expect(lines.count == 3)
        #expect(lines[1] == lines[2], "the daemon leads its own session")
    }
}
#endif
