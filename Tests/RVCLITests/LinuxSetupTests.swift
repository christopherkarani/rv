#if os(Linux)
import Foundation
import Testing
@testable import RVCLI

@Test func setup_linuxWritesSystemdUserUnitNotLaunchd() throws {
    try withTempHome { home, layout, launchctl in
        let systemctl = RecordingSystemctl()
        let outcome = SetupRun.setup(
            env(
                home: home,
                launchctl: launchctl,
                systemctl: systemctl,
                touchSystemd: true,
                supervisor: .systemdUser
            )
        )
        #expect(outcome.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent) == false)
        #expect(FileManager.default.fileExists(atPath: layout.systemdUserUnit))
        let unit = try String(contentsOfFile: layout.systemdUserUnit, encoding: .utf8)
        #expect(unit.contains("Restart=always"))
        #expect(unit.contains("ExecStart=\"\(home.appendingPathComponent("rvd").path)\" --socket"))
        #expect(systemctl.enabled == [SystemdUserTemplate.unitName])
        #expect(launchctl.bootstraps.isEmpty)
        #expect(launchctl.bootouts.isEmpty)
    }
}

@Test func setup_linuxDoesNotTouchLiveSystemdWhenHomeIsNotLogin() throws {
    try withTempHome { home, layout, launchctl in
        let systemctl = RecordingSystemctl()
        let outcome = SetupRun.setup(
            env(
                home: home,
                launchctl: launchctl,
                systemctl: systemctl,
                touchSystemd: false,
                supervisor: .systemdUser
            )
        )
        #expect(outcome.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: layout.systemdUserUnit))
        #expect(systemctl.enabled.isEmpty)
        #expect(launchctl.bootstraps.isEmpty)
    }
}

@Test func uninstall_linuxRemovesSystemdUnitNotLaunchd() throws {
    try withTempHome { home, layout, launchctl in
        let systemctl = RecordingSystemctl()
        let setupEnv = env(
            home: home,
            launchctl: launchctl,
            systemctl: systemctl,
            touchSystemd: true,
            supervisor: .systemdUser
        )
        #expect(SetupRun.setup(setupEnv).exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: layout.systemdUserUnit))

        let outcome = SetupRun.uninstall(setupEnv)
        #expect(outcome.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: layout.systemdUserUnit) == false)
        #expect(systemctl.disabled == [SystemdUserTemplate.unitName])
        #expect(launchctl.bootouts.isEmpty)
    }
}

@Test func setup_linuxSystemctlEnableFails_mapsToUnavailable() throws {
    try withTempHome { home, _, launchctl in
        let outcome = SetupRun.setup(
            env(
                home: home,
                launchctl: launchctl,
                systemctl: FailingSystemctl(),
                touchSystemd: true,
                supervisor: .systemdUser
            )
        )
        #expect(outcome.stdout.isEmpty)
        #expect(outcome.stderr == "rv setup failed: unable to enable systemd unit\n"
            + "no hooks were wired: rv wires agent hooks only once rvd answers\n"
            + "fix: systemctl --user enable --now dev.rv.evaluate.service "
            + "from a login session with a user systemd manager; "
            + "journalctl --user -u dev.rv.evaluate.service and rv doctor show the cause\n"
            + "then rerun rv setup to wire agent hooks\n")
        #expect(outcome.exitCode == EX_UNAVAILABLE)
        #expect(launchctl.bootstraps.isEmpty)
    }
}
@Test func systemdExecStart_quotesSpacesAndEscapesSpecifiers() throws {
    #expect(try SystemdUserTemplate.execStartQuoted("/home/a b/.local/bin/rvd") == "\"/home/a b/.local/bin/rvd\"")
    #expect(try SystemdUserTemplate.execStartQuoted("/home/100%/rvd") == "\"/home/100%%/rvd\"")
    #expect(try SystemdUserTemplate.execStartQuoted("/h/q\"\\/rvd") == "\"/h/q\\\"\\\\/rvd\"")
    #expect(throws: SetupError.systemdUnitWriteFailed) {
        try SystemdUserTemplate.execStartQuoted("/home/x\ny/rvd")
    }
    let unit = try SystemdUserTemplate.rendered(rvdPath: "/home/a b/.local/bin/rvd")
    #expect(unit.contains("ExecStart=\"/home/a b/.local/bin/rvd\" --socket --idle-exit-seconds=31536000"))
}
#endif
