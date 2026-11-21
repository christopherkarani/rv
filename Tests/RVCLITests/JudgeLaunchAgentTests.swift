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

    @Test func setupRegistersTheJudgeBeforeRvd() throws {
        try withTempHome { home, layout, launchctl in
            _ = try installJudge(beside: home.appendingPathComponent("rvd"))
            #expect(SetupRun.setup(env(home: home, launchctl: launchctl)).exitCode == 0)
            let judge = try #require(launchctl.bootstraps.firstIndex { $0.path == layout.judgeLaunchAgent })
            let rvd = try #require(launchctl.bootstraps.firstIndex { $0.path == layout.launchAgent })
            #expect(judge < rvd, "rvd's first judged call should find the pool already registered")
        }
    }

    @Test func setupWarnsWhenABundleIsInstalledButRvJudgeIsMissing() throws {
        try withTempHome { home, _, launchctl in
            var environment = env(home: home, launchctl: launchctl)
            environment.judgeBundleInstalled = { _ in true }
            let outcome = SetupRun.setup(environment)
            #expect(outcome.exitCode == 0, "rvd and the hooks are still installed")
            #expect(outcome.stderr.contains("rv-judge"))
            #expect(outcome.stderr.contains("review"))
        }
    }

    @Test func setupWarnsWhenTheJudgeAgentDoesNotLoad() throws {
        try withTempHome { home, layout, _ in
            _ = try installJudge(beside: home.appendingPathComponent("rvd"))
            let refusing = RefusingLaunchctl(refusedPlist: layout.judgeLaunchAgent)
            var environment = env(home: home, launchctl: refusing)
            environment.judgeBundleInstalled = { _ in true }
            let outcome = SetupRun.setup(environment)
            #expect(outcome.exitCode == 0, "\(outcome.stderr)")
            #expect(outcome.stderr.contains("dev.rv.judge"))
            #expect(refusing.bootstraps.contains { $0.path == layout.launchAgent }, "rvd is still installed")
        }
    }

    @Test func setupJSONCarriesTheJudgeWarning() throws {
        try withTempHome { home, _, launchctl in
            var environment = env(home: home, launchctl: launchctl)
            environment.judgeBundleInstalled = { _ in true }
            let outcome = SetupRun.setup(environment, json: true)
            #expect(outcome.stdout.contains(#""judge_agent":"rv_judge_missing""#), "\(outcome.stdout)")
            environment.judgeBundleInstalled = { _ in false }
            let quiet = SetupRun.setup(environment, json: true)
            #expect(!quiet.stdout.contains("judge_agent"), "\(quiet.stdout)")
        }
    }

    @Test func noJudgeWarningWithoutABundle() throws {
        try withTempHome { home, _, launchctl in
            let outcome = SetupRun.setup(env(home: home, launchctl: launchctl))
            #expect(outcome.stderr.contains("rv-judge") == false)
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

/// Records bootstraps and refuses the one plist it names.
private final class RefusingLaunchctl: LaunchctlApplying {
    let refusedPlist: String
    private(set) var bootstraps: [URL] = []

    init(refusedPlist: String) { self.refusedPlist = refusedPlist }

    func bootstrap(domain _: String, plist: URL) throws {
        guard plist.path != refusedPlist else { throw LaunchctlError.nonZeroExit(5) }
        bootstraps.append(plist)
    }

    func bootout(domain _: String, label _: String) throws {}
}
#endif
