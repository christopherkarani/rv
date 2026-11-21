import Foundation
import Testing
import RVService
@testable import RVCLI

/// The setup commands announce a deliberate rvd restart in the rvd state
/// marker (`RVDStateMarker`), so observe-mode hooks keep stepping aside
/// while rvd bounces, and `rv uninstall` removes it. A stop that is not
/// announced leaves it as rvd armed it, which the hook treats as stopped.
@Suite("rvd state marker writers")
struct RVDStateMarkerSetupTests {
    private static func state(_ layout: OwnedPaths) -> RVDStateMarker.State {
        RVDStateMarker.read(path: layout.rvdStateMarker, now: RVDStateMarker.now())
    }

    @Test func setupAnnouncesTheRestartBeforeBootingOutRvd() throws {
        try withTempHome { home, layout, _ in
            let launchctl = ScriptedLaunchctl()
            launchctl.loaded = ["gui/501"]
            var environment = env(home: home, launchctl: launchctl)
            environment.uid = { 501 }
            #expect(SetupRun.setup(environment).exitCode == 0)
            #expect(launchctl.events.contains("bootout gui/501"))
            #expect(Self.state(layout) == .restarting)
        }
    }

    @Test func setupWithoutTheRealSupervisorWritesNoMarker() throws {
        try withTempHome { home, layout, launchctl in
            #expect(SetupRun.setup(env(home: home, launchctl: launchctl, touchLaunchd: false)).exitCode == 0)
            #expect(Self.state(layout) == .absent)
        }
    }

    @Test func serviceRestartAnnouncesBeforeKickstart() throws {
        try withTempHome { home, layout, _ in
            RVDStateMarker.writeArmed(path: layout.rvdStateMarker)
            let launchctl = ScriptedLaunchctl()
            launchctl.loaded = ["gui/501"]
            var environment = env(home: home, launchctl: launchctl)
            environment.uid = { 501 }
            #expect(ServiceRestart.run(environment).exitCode == 0)
            #expect(launchctl.events.contains("kickstart gui/501/dev.rv.evaluate"))
            #expect(Self.state(layout) == .restarting)
        }
    }

    @Test func serviceRestartOnAForeignHomeLeavesTheMarker() throws {
        try withTempHome { home, layout, launchctl in
            RVDStateMarker.writeArmed(path: layout.rvdStateMarker)
            #expect(ServiceRestart.run(env(home: home, launchctl: launchctl, touchLaunchd: false)).exitCode != 0)
            #expect(Self.state(layout) == .armed)
        }
    }

    @Test func systemdRestartAnnouncesButStartDoesNot() throws {
        try withTempHome { home, layout, launchctl in
            let systemctl = RecordingSystemctl(reachable: true)
            let environment = env(
                home: home, launchctl: launchctl, touchLaunchd: false, systemctl: systemctl,
                touchSystemd: true, supervisor: .systemdUser)
            RVDStateMarker.writeArmed(path: layout.rvdStateMarker)
            #expect(ServiceRestart.run(environment, onlyIfStopped: true).exitCode == 0)
            #expect(Self.state(layout) == .armed, "starting a stopped rvd needs no window")
            #expect(ServiceRestart.run(environment).exitCode == 0)
            #expect(systemctl.restarted == [SystemdUserTemplate.unitName])
            #expect(Self.state(layout) == .restarting)
        }
    }

    @Test func uninstallRemovesTheMarker() throws {
        try withTempHome { home, layout, launchctl in
            let environment = env(home: home, launchctl: launchctl)
            #expect(SetupRun.setup(environment).exitCode == 0)
            RVDStateMarker.writeArmed(path: layout.rvdStateMarker)
            #expect(SetupRun.uninstall(environment).exitCode == 0)
            #expect(Self.state(layout) == .absent)
        }
    }
}
