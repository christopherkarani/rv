import Foundation
import Testing
@testable import RVCLI

func launchdPlist(_ text: String) throws -> [String: Any] {
    let data = try #require(text.data(using: .utf8))
    let object = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(object as? [String: Any])
}

/// The KeepAlive condition: alive while the rvd binary exists, so a deleted
/// rvd (uninstall, a manual rm) is never respawned.
func keepAlivePathState(_ plist: [String: Any]) -> [String: Bool]? {
    (plist["KeepAlive"] as? [String: Any])?["PathState"] as? [String: Bool]
}

/// rvd is always on: launchd starts it at load and relaunches it after any
/// exit, a crash or the clean exit once its binary was replaced, while the
/// binary it runs exists.
func expectAlwaysOnLaunchAgent(
    _ path: String,
    rvdPath: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let plist = try launchdPlist(try String(contentsOfFile: path, encoding: .utf8))
    #expect(keepAlivePathState(plist) == [rvdPath: true], sourceLocation: sourceLocation)
    #expect(plist["RunAtLoad"] as? Bool == true, sourceLocation: sourceLocation)
    #expect(plist["ThrottleInterval"] as? Int == 5, sourceLocation: sourceLocation)
    #expect(plist["ProgramArguments"] as? [String] == [rvdPath], sourceLocation: sourceLocation)
}

@Test(arguments: ["/opt/rvd", "/Users/a b/.local/bin/rvd"])
func launchAgentTemplate_rendersAlwaysOnJob(rvdPath: String) throws {
    let plist = try launchdPlist(try LaunchAgentTemplate.rendered(rvdPath: rvdPath))
    #expect(keepAlivePathState(plist) == [rvdPath: true])
    #expect((plist["KeepAlive"] as? [String: Any])?.count == 1)
    #expect(plist["RunAtLoad"] as? Bool == true)
    #expect(plist["ThrottleInterval"] as? Int == 5)
    #expect(plist["ProgramArguments"] as? [String] == [rvdPath])
    let mach = try #require(plist["MachServices"] as? [String: Any])
    #expect(mach["dev.rv.evaluate"] as? Bool == true)
}

#if !os(Linux)
@Test func setup_writesAlwaysOnLaunchAgentAndLoadsIt() throws {
    try withTempHome { home, layout, launchctl in
        let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
        #expect(outcome.exitCode == 0)
        try expectAlwaysOnLaunchAgent(layout.launchAgent, rvdPath: home.appendingPathComponent("rvd").path)
        #expect(launchctl.bootstraps.isEmpty == false)
    }
}
#endif
