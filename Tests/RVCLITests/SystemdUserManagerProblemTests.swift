import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
import RVPresentation
@testable import RVCLI

struct SystemdUserManagerProblemTests {
    private let paths = OwnedPaths(home: HomeDirectory(validating: "/home/u")!)
    private let local = ServiceHealth.Local(corePacksReady: true, serviceSemver: nil, launchAgent: .installed)

    @Test func downWithoutAUserManagerFailsWithTheStartCommand() throws {
        let problem = try #require(DoctorInstallChecks.systemdUserManager(false, health: .down(.local(local)), paths: paths))
        #expect(problem.id == "systemd-user-manager")
        #expect(problem.severity == .fail)
        #expect(problem.summary.contains("no systemd user manager is running"))
        #expect(problem.fix.hasPrefix("/home/u/.local/bin/rv service start"))
        #expect(problem.fix.contains("/home/u/.local/bin/rvd --socket --idle-exit-seconds=31536000"))
    }

    @Test func runningWithoutAUserManagerWarnsItWillNotSurviveReboot() throws {
        let snapshot = DoctorSnapshotReply(state: .running, idleExitSeconds: 300, packsEnabled: [], checks: [])
        let health = ServiceHealth.reachable(.init(snapshot: snapshot, localCorePacksReady: true, launchAgent: .installed))
        let problem = try #require(DoctorInstallChecks.systemdUserManager(false, health: health, paths: paths))
        #expect(problem.severity == .warn)
        #expect(problem.summary.contains("will not survive logout or reboot"))
        #expect(problem.fix.contains("service start >/dev/null"))
    }

    @Test func silentWithAUserManagerOffLinuxOrBeforeSetup() {
        #expect(DoctorInstallChecks.systemdUserManager(true, health: .down(.local(local)), paths: paths) == nil)
        #expect(DoctorInstallChecks.systemdUserManager(nil, health: .down(.local(local)), paths: paths) == nil)
        #expect(DoctorInstallChecks.systemdUserManager(false, health: .notInstalled(local), paths: paths) == nil)
    }

    @Test func restartCommandIsRvServiceRestartEverywhere() {
        #expect(DoctorRun.restartCommand == "rv service restart")
    }
}
