#if os(macOS)
import Foundation
import Testing
@testable import RVCLI

/// `dev.rv.judge`: the judge pool agent `rv setup` registers beside
/// dev.rv.evaluate, and `rv uninstall` removes.
@Suite struct JudgeLaunchAgentTests {
    private func installJudge(beside rvd: URL) throws -> String {
        let judge = rvd.deletingLastPathComponent().appendingPathComponent("rv-judge").path
        try "#!/bin/sh\n".write(toFile: judge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: judge)
        return judge
    }

    @Test func templateRendersASupervisedMachService() throws {
        let plist = try LaunchAgentTemplate.renderedJudge(judgePath: "/opt/rv/rv-judge")
        #expect(plist.contains("@JUDGE_PATH@") == false)
        let keys = try launchdPlist(plist)
        #expect(keys["Label"] as? String == "dev.rv.judge")
        #expect(keys["ProgramArguments"] as? [String] == ["/opt/rv/rv-judge", "serve"])
        #expect(keys["RunAtLoad"] as? Bool == true)
        #expect(keys["KeepAlive"] as? Bool == true)
        #expect(keys["ThrottleInterval"] as? Int == 5)
        let services = try #require(keys["MachServices"] as? [String: Bool])
        #expect(services == ["dev.rv.judge": true])
        #expect(keys["LimitLoadToSessionType"] as? [String] == ["Aqua", "Background"])
    }

    @Test func setupRegistersTheJudgeOnlyWhenRvJudgeSitsBesideRvd() throws {
        try withTempHome { home, layout, launchctl in
            let absent = SetupRun.setup(env(home: home, launchctl: launchctl))
            #expect(absent.exitCode == 0)
            #expect(FileManager.default.fileExists(atPath: layout.judgeLaunchAgent) == false)

            let judge = try installJudge(beside: home.appendingPathComponent("rvd"))
            let present = SetupRun.setup(env(home: home, launchctl: launchctl))
            #expect(present.exitCode == 0)
            let plist = try String(contentsOfFile: layout.judgeLaunchAgent, encoding: .utf8)
            #expect(plist.contains(judge))
            #expect(launchctl.bootstraps.contains { $0.path == layout.judgeLaunchAgent })
        }
    }

    @Test func restartingRvdLeavesTheJudgeAlone() throws {
        try withTempHome { home, layout, launchctl in
            _ = try installJudge(beside: home.appendingPathComponent("rvd"))
            _ = try SetupRun.writeLaunchAgent(
                env: env(home: home, launchctl: launchctl), layout: layout,
                files: FileOps(fileManager: .default), keepAlive: false)
            #expect(FileManager.default.fileExists(atPath: layout.judgeLaunchAgent) == false)
            #expect(launchctl.bootouts.contains(SetupRun.judgeLaunchAgentLabel) == false)
        }
    }

    @Test func uninstallBootsOutAndRemovesTheJudgeAgent() throws {
        try withTempHome { home, layout, launchctl in
            _ = try installJudge(beside: home.appendingPathComponent("rvd"))
            #expect(SetupRun.setup(env(home: home, launchctl: launchctl)).exitCode == 0)
            #expect(FileManager.default.fileExists(atPath: layout.judgeLaunchAgent))

            let uninstalling = RecordingLaunchctl()
            let outcome = SetupRun.uninstall(env(home: home, launchctl: uninstalling))
            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            #expect(FileManager.default.fileExists(atPath: layout.judgeLaunchAgent) == false)
            // Both domains (user and gui).
            #expect(uninstalling.bootouts.filter { $0 == SetupRun.judgeLaunchAgentLabel }.count == 2)
        }
    }
}
#endif
