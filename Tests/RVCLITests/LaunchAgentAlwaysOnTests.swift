import Foundation
import Testing
@testable import RVCLI

func launchdPlist(_ text: String) throws -> [String: Any] {
    let data = try #require(text.data(using: .utf8))
    let object = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(object as? [String: Any])
}

/// rvd is always on: launchd starts it at load and relaunches it after any
/// exit, a crash or the clean exit once its binary was replaced.
func expectAlwaysOnLaunchAgent(
    _ path: String,
    rvdPath: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let plist = try launchdPlist(try String(contentsOfFile: path, encoding: .utf8))
    #expect(plist["KeepAlive"] as? Bool == true, sourceLocation: sourceLocation)
    #expect(plist["RunAtLoad"] as? Bool == true, sourceLocation: sourceLocation)
    #expect(plist["ThrottleInterval"] as? Int == 5, sourceLocation: sourceLocation)
    if let rvdPath {
        #expect(plist["ProgramArguments"] as? [String] == [rvdPath], sourceLocation: sourceLocation)
    }
}

@Test func launchAgentTemplate_rendersAlwaysOnJob() throws {
    let plist = try launchdPlist(try LaunchAgentTemplate.rendered(rvdPath: "/opt/rvd"))
    #expect(plist["KeepAlive"] as? Bool == true)
    #expect(plist["RunAtLoad"] as? Bool == true)
    #expect(plist["ThrottleInterval"] as? Int == 5)
    #expect(plist["ProgramArguments"] as? [String] == ["/opt/rvd"])
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
