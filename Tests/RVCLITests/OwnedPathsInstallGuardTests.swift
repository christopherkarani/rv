import Testing
import RVDomain
import RVEngine
import RVPolicy
@testable import RVCLI

/// `RVInstallPathGuard` (RVEngine) spells rv's install by hand; this pins
/// it to what setup actually writes, so a renamed path cannot drift out
/// of the floor.
@Suite("Owned paths stay under the install floor")
struct OwnedPathsInstallGuardTests {
    @Test("every path setup installs rvd or its launcher at is an install file")
    func ownedInstallPathsAreGuarded() throws {
        let home = try #require(HomeDirectory(validating: "/Users/agent"))
        let paths = OwnedPaths(home: home)
        for path in [
            paths.localRv, paths.localRvCli, paths.localRvd, paths.launchAgent, paths.custodianLaunchAgent,
            paths.auditForwardLaunchAgent, paths.systemdUserUnit, paths.custodianAppExecutable,
        ] {
            #expect(RVInstallPathGuard.isInstallFile(path, home: home), "\(path)")
        }
        #expect(RVInstallPathGuard.isInstallFile(
            "/Users/agent/.config/systemd/user/" + SystemdUserTemplate.unitName, home: home
        ))
    }
}
