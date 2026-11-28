import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPolicy
import RVTerm
@testable import RVCLI

/// H4 `rv pause 10m`: owner check, a visible countdown, back on its own,
/// and never by an agent.
struct PauseCommandTests {
    static let utc = TimeZone(identifier: "UTC")!
    /// 14:12 UTC.
    static let t0 = Date(timeIntervalSince1970: 1_764_252_720)
    static let owner = HostModeRequester(atTerminal: true, callingHosts: [])

    /// Counts owner checks; `allow` decides them.
    private final class OwnerProbe: @unchecked Sendable {
        private(set) var summaries: [String] = []
        let allow: Bool

        init(allow: Bool) {
            self.allow = allow
        }

        func check(_ summary: String) async throws -> String {
            summaries.append(summary)
            guard allow else { throw AllowOnceAuthError.required }
            return OwnerConfirmation.testAuthorization
        }
    }

    @Test func registeredWithHelpTopic() {
        let names = RV.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("pause"))
        #expect(HelpDispatch.topic(arguments: ["pause", "--help"]) == .pause)
    }

    @Test(arguments: [("10m", 600.0), ("30min", 1800.0), ("1h", 3600.0), ("60m", 3600.0), ("1m", 60.0)])
    func duration_acceptsMinutesAndHoursUpToAnHour(text: String, seconds: Double) {
        #expect(PauseRun.duration(text) == seconds)
    }

    @Test(arguments: ["0m", "61m", "2h", "10", "10s", "m", "-5m", "ten"])
    func duration_refusesAnythingElse(_ text: String) {
        #expect(PauseRun.duration(text) == nil)
        #expect(throws: (any Error).self) { _ = try PauseCommand.parse([text]) }
    }

    @Test func endAndADuration_doNotParseTogether() {
        #expect(throws: (any Error).self) { _ = try PauseCommand.parse(["10m", "--end"]) }
    }

    /// Acceptance: agents can never pause rv. Without a terminal the owner
    /// check is not even shown, and nothing is written.
    @Test func agentWithoutATerminal_cannotPause_andIsNeverPrompted() async throws {
        try await withHome { home, environment in
            let probe = OwnerProbe(allow: true)
            for requester in [
                HostModeRequester.unattended,
                HostModeRequester(atTerminal: false, callingHosts: [.claude]),
            ] {
                let outcome = await PauseRun.pause(
                    for: 600, env: environment, requester: requester, now: { Self.t0 }, timeZone: Self.utc,
                    authenticate: probe.check)
                #expect(outcome.exitCode == 77)
                #expect(outcome.stdout.isEmpty)
                #expect(outcome.stderr == "rv pause needs you at your terminal with Touch ID or your password; an agent can't pause rv\n")
            }
            #expect(probe.summaries.isEmpty)
            #expect(FileManager.default.fileExists(atPath: store(home).configFile.path) == false)
        }
    }

    /// An agent with a pty reaches the owner check, and cannot pass it: the
    /// real seam fails closed without the owner.
    @Test func agentWithAPty_failsTheOwnerCheck_andNothingIsWritten() async throws {
        try await withHome { home, environment in
            // Both TTYs and no marker: the requester counts as at a terminal,
            // so the real owner seam is what refuses.
            let outcome = await CLIProcess.$context.withValue(CLIProcess.Context(stdinIsTTY: true, stdoutIsTTY: true)) {
                await PauseRun.pause(
                    for: 600, env: environment, requester: .live(), now: { Self.t0 },
                    authenticate: { try await CLIOwnerAuth.requireAuthenticated(reason: $0) })
            }
            #expect(outcome.exitCode == 77)
            #expect(outcome.stderr == "rv pause failed: device-owner authentication required; rv was not paused\n")
            #expect(store(home).readGuardConfig()?.pause == nil)
        }
    }

    @Test func owner_pausesWithACountdown_andRvComesBackOnItsOwn() async throws {
        try await withHome { home, environment in
            try store(home).save(.block, for: .claude)
            let probe = OwnerProbe(allow: true)
            let outcome = await PauseRun.pause(
                for: 600, env: environment, requester: Self.owner, now: { Self.t0 }, timeZone: Self.utc,
                authenticate: probe.check)
            #expect(outcome.exitCode == 0)
            #expect(probe.summaries == ["pause rv for 10 min"])
            #expect(outcome.stdout == """
                ◐ Paused until 14:22.
                  still stopped   rm -rf ~ and /, rv's own files
                  rv comes back on its own. To come back now:
                → rv pause --end

                """)

            let during = PauseRun.status(environment, json: false, now: Self.t0.addingTimeInterval(121), timeZone: Self.utc)
            #expect(during.stdout == """
                ◐ Paused until 14:22 · 8 min left
                  rv comes back on its own. To come back now:
                → rv pause --end

                """)
            let json = PauseRun.status(environment, json: true, now: Self.t0.addingTimeInterval(121))
            #expect(json.stdout == #"{"paused":true,"schema":"rv.pause.v1","until":"2025-11-27T14:22:00Z"}"# + "\n")
            let list = HostModeRun.list(environment, json: false, now: Self.t0.addingTimeInterval(121), timeZone: Self.utc)
            #expect(list.stdout.hasPrefix("◐ Paused until 14:22 · 8 min left\n"))

            // Every host watched while paused, from a fresh read (rvd
            // restarted or not); the owner's stored block is untouched.
            let config = GuardConfig.read(home: environment.home)
            for host in HookHost.allCases {
                #expect(GuardModeResolution.resolve(config, host: host, environment: [:], now: Self.t0.addingTimeInterval(1)) == .observe)
            }
            #expect(store(home).read() == .entries([.claude: .block]))

            // Back on its own, with nothing written.
            let back = Self.t0.addingTimeInterval(600)
            #expect(GuardModeResolution.resolve(config, host: .claude, environment: [:], now: back) == .enforce)
            #expect(PauseRun.status(environment, json: false, now: back, timeZone: Self.utc).stdout
                == "◆ rv is back. It was paused until 14:22.\n")
            #expect(PauseRun.status(environment, json: true, now: back).stdout
                == #"{"paused":false,"schema":"rv.pause.v1"}"# + "\n")
        }
    }

    /// An agent holding a pty keeps its marker, so it is never prompted.
    @Test func agentWithAPtyAndItsMarker_isNeverPrompted() async throws {
        try await withHome { home, environment in
            let probe = OwnerProbe(allow: true)
            let context = CLIProcess.Context(environment: ["CLAUDECODE": "1"], stdinIsTTY: true, stdoutIsTTY: true)
            let outcome = await CLIProcess.$context.withValue(context) {
                await PauseRun.pause(
                    for: 600, env: environment, requester: .live(), now: { Self.t0 }, authenticate: probe.check)
            }
            #expect(outcome.exitCode == 77)
            #expect(probe.summaries.isEmpty)
            #expect(store(home).readGuardConfig()?.pause == nil)
        }
    }

    /// Setup's rvd-down warning while paused says the pause does not hold.
    @Test func setupWarning_whilePaused_saysHooksStillBlock() {
        let text = SetupServiceWarning.pausedText(until: Self.t0.addingTimeInterval(600), timeZone: Self.utc)
        #expect(text.contains("rv is paused (watching) until 14:22"))
        #expect(text.contains("block or prompt on every command"))
    }

    @Test func term_whilePaused_isWatchingWithTheCountdown() async throws {
        try await withHome { home, environment in
            let now = Date()
            try store(home).savePause(GuardWindow(startingAt: now.addingTimeInterval(-60), lasting: 600))
            let sources = TermSources(home: environment.home)
            #expect(sources.mode(now: now) == .watching)
            var state = TermState(now: now, mode: sources.mode(now: now))
            state.pausedUntil = sources.pausedUntil(now: now)
            let top = TermScreen.render(state, width: 80, height: 24)[0].map(\.text).joined()
            #expect(top.contains(" ◐ paused · 9 min "))
            #expect(sources.mode(now: now.addingTimeInterval(600)) == .guarding)
            #expect(sources.pausedUntil(now: now.addingTimeInterval(600)) == nil)
        }
    }

    @Test func ownerRefusesTheCheck_nothingIsPaused() async throws {
        try await withHome { home, environment in
            let probe = OwnerProbe(allow: false)
            let outcome = await PauseRun.pause(
                for: 3600, env: environment, requester: Self.owner, now: { Self.t0 }, authenticate: probe.check)
            #expect(outcome.exitCode == 77)
            #expect(probe.summaries == ["pause rv for 1 hour"])
            #expect(store(home).readGuardConfig()?.pause == nil)
        }
    }

    /// Coming back early tightens: anyone may, with no owner check.
    @Test func end_comesBackNow() async throws {
        try await withHome { home, environment in
            _ = await PauseRun.pause(
                for: 600, env: environment, requester: Self.owner, now: { Self.t0 },
                authenticate: OwnerProbe(allow: true).check)
            let end = PauseRun.end(environment)
            #expect(end.exitCode == 0)
            #expect(end.stdout == "✓ ◆ rv is back.\n")
            #expect(store(home).readGuardConfig()?.pause == nil)
            #expect(PauseRun.end(environment).stdout == "◆ rv is guarding.\n")
            #expect(PauseRun.end(environment, json: true).stdout == #"{"paused":false,"schema":"rv.pause.v1"}"# + "\n")
            _ = await PauseRun.pause(
                for: 600, env: environment, requester: Self.owner, now: { Self.t0 },
                authenticate: OwnerProbe(allow: true).check)
            let endJSON = PauseRun.end(environment, json: true)
            #expect(endJSON.exitCode == 0)
            #expect(endJSON.stdout == #"{"paused":false,"schema":"rv.pause.v1"}"# + "\n")
            #expect(store(home).readGuardConfig()?.pause == nil)
            #expect(PauseRun.status(environment, json: false, now: Self.t0).stdout == """
                ◆ rv is guarding.
                  To pause it for ten minutes, you type:
                → rv pause 10m

                """)
        }
    }

    @Test func organizationGate_refusesBeforeAnyPrompt() async throws {
        try await withHome { home, base in
            var environment = base
            environment.managedEnforce = { _ in true }
            let probe = OwnerProbe(allow: true)
            let outcome = await PauseRun.pause(
                for: 600, env: environment, requester: Self.owner, now: { Self.t0 }, authenticate: probe.check)
            #expect(outcome.exitCode == 77)
            #expect(outcome.stderr == "rv pause failed: organization policy keeps rv guarding this Mac\n")
            #expect(probe.summaries.isEmpty)
            #expect(store(home).readGuardConfig()?.pause == nil)
        }
    }

    @Test func unreadableConfig_refusesBeforeAnyPrompt() async throws {
        try await withHome { home, environment in
            let file = store(home).configFile
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = Data(#"{"guard":{"mode":"observe"},"guard":{"mode":"enforce"}}"#.utf8)
            try text.write(to: file)
            let probe = OwnerProbe(allow: true)
            let outcome = await PauseRun.pause(
                for: 600, env: environment, requester: Self.owner, now: { Self.t0 }, authenticate: probe.check)
            #expect(outcome.exitCode == EX_DATAERR)
            #expect(outcome.stderr.hasPrefix("rv pause failed: config.json cannot be rewritten safely"))
            #expect(probe.summaries.isEmpty)
            #expect(try Data(contentsOf: file) == text)
        }
    }

    private func store(_ home: URL) -> HostModeStore {
        HostModeStore(configDirectory: home.appendingPathComponent(".config/rv", isDirectory: true))
    }

    private func withHome(_ body: (URL, SetupEnvironment) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-pause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try makeExecutable(bin.appendingPathComponent("rv"))
        var environment = env(home: root, launchctl: RecordingLaunchctl(), rvPath: bin.appendingPathComponent("rv").path)
        environment.managedEnforce = { _ in false }
        try await body(root, environment)
    }
}
