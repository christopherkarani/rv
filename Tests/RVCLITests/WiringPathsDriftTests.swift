import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

/// Every file `rv setup` writes to wire rv in must be one the guard
/// protects (`RVWiringPaths`): adding a host or a unit without extending
/// the table fails here, so setup and the two doors cannot drift.
@Suite("Setup wiring paths are guarded")
struct WiringPathsDriftTests {
    @Test("every OwnedPaths wiring destination is an RVWiringPaths match")
    func ownedPathsAreGuarded() throws {
        let home = try #require(HomeDirectory(validating: "/tmp/rv-wiring-drift"))
        let layout = OwnedPaths(home: home)
        var paths = layout.hostAdapters.map(\.destination)
        paths += [
            layout.claudeSettings, layout.codexHook, layout.codexHooksJSON, layout.cursorHook,
            layout.cursorHooksJSON, layout.antigravityHooksJSON, layout.museSettings, layout.museHooks,
            layout.grokHook, layout.piExtension, layout.openCodePlugin, layout.openCodeTuiPlugin,
            layout.openCodeTuiAskPackage, layout.openCodeConfig, layout.openClawPlugin, layout.hermesPlugin,
            layout.launchAgent, layout.custodianLaunchAgent, layout.auditForwardLaunchAgent,
            layout.custodianAppExecutable, layout.systemdUserUnit,
            layout.localRv, layout.localRvCli, layout.localRvd,
            ClaudeSettingsMerge.adapterPath(settingsPath: layout.claudeSettings),
        ]
        for path in paths {
            #expect(RVWiringPaths.matches(path, home: home.rawValue), "\(path)")
        }
    }
}
