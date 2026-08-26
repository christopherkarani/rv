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
        #expect(unit.contains("Restart=no"))
        #expect(unit.contains("Restart=always") == false)
        #expect(unit.contains("\(home.appendingPathComponent("rvd").path) --socket"))
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
        #expect(outcome.stderr == "rv setup failed: unable to enable systemd unit\n")
        #expect(outcome.exitCode == EX_UNAVAILABLE)
        #expect(launchctl.bootstraps.isEmpty)
    }
}
#endif
