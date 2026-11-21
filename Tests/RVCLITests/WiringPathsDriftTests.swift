import Testing
import RVDomain
import RVPolicy
import RVService
@testable import RVCLI

/// Every file `rv setup` writes to wire rv in must be one the guard
/// protects (`RVWiringPaths`): adding a host or a unit without extending
/// the table fails here, so setup and the two doors cannot drift.
@Suite("Setup wiring paths are guarded")
struct WiringPathsDriftTests {
    /// setup's LaunchAgent label is the Mach service rvd listens on, which
    /// is the label `StartupBackoff.isSupervised` trusts.
    @Test("setup's LaunchAgent label is rvd's Mach service")
    func launchAgentLabelIsTheMachService() {
        #expect(SetupRun.launchAgentLabel == RVService.machServiceName)
        #expect(StartupBackoff.isSupervised(environment: ["XPC_SERVICE_NAME": SetupRun.launchAgentLabel]))
    }

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
            layout.launchAgent, layout.custodianLaunchAgent, layout.auditForwardLaunchAgent, layout.judgeLaunchAgent,
            layout.custodianAppExecutable, layout.systemdUserUnit,
            layout.localRv, layout.localRvCli, layout.localRvd,
            ClaudeSettingsMerge.adapterPath(settingsPath: layout.claudeSettings),
            layout.claudeAgentSkill, layout.codexAgentSkill, layout.openCodeAgentSkill,
        ]
        paths += HookHost.setupSlotOrder.compactMap(layout.agentSkill(for:))
        // rvd's startup backoff record and its mkstemp temp files, on both
        // platforms' log directories.
        let backoff = StartupBackoffStore.live(home: home.rawValue).path
        paths += [backoff, backoff + ".a1B2c3.tmp"]
        for logs in ["/Library/Logs/rv", "/.local/state/rv"] {
            paths += [home.rawValue + logs + "/rvd-backoff/rvd-starts.json",
                      home.rawValue + logs + "/rvd-backoff/rvd-starts.json.a1B2c3.tmp"]
        }
        for path in paths {
            #expect(RVWiringPaths.matches(path, home: home.rawValue), "\(path)")
        }
    }
}
