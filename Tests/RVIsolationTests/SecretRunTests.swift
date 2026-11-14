#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import RVIsolation

private let runSecrets = """
    {"version":1,"secrets":[
      {"name":"OPENAI_API_KEY","source":{"hostEnvironment":{"variable":"FAKE_OPENAI"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"OPENAI_BASE_URL",
                              "placeholderPrefix":"sk-"}}},
      {"name":"CODEX_ONLY","agents":["codex"],"source":{"hostEnvironment":{"variable":"FAKE_OPENAI"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"CODEX_BASE_URL"}}},
      {"name":"GH_TOKEN","source":{"hostEnvironment":{"variable":"FAKE_GH"}},"delivery":{"environment":{}}}
    ]}
    """

private let realOpenAI = "sk-live-REAL-0123456789"

private func configuration(_ json: String = runSecrets) throws -> SecretsConfiguration {
    try SecretsConfiguration.decode(Data(json.utf8)).get()
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-run-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private final class Notices: Sendable {
    let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    var sink: @Sendable (String) -> Void { { line in self.lines.withLock { $0.append(line) } } }
}

extension GatewayPeerCheck {
    /// Answers `member` for every peer: a check that binds nothing.
    static let alwaysMember = GatewayPeerCheck(verify: { _, _ in .member })
    static let neverAnswers = GatewayPeerCheck(verify: { _, _ in .unverifiable })
}

/// Lets a stub peer check through, so the logic after the capability probe runs.
private let capable: @Sendable (GatewayPeerCheck) -> SecretRunRefusal? = { _ in nil }

/// Whether the real spawn and kernel peer check work here.
private let hostRunsSecretRun = SecretRunCapability.check(.runtime) == nil

private func context(
    _ fixture: SecretsFixture, directory: URL, peers: GatewayPeerCheck,
    capability: @escaping @Sendable (GatewayPeerCheck) -> SecretRunRefusal? = capable,
    transport: SecretUpstreamTransport = RecordingUpstream().transport, notices: Notices = Notices(),
    environment: [String: String] = ["PATH": "/usr/bin:/bin"]
) -> SecretRunContext {
    SecretRunContext(
        configDirectory: fixture.directory, resolver: fakeResolver, transport: transport, peers: peers,
        capability: capability, environment: environment, directory: directory.path,
        manageTerminal: false, notice: notices.sink)
}

@Suite("SecretRun selection and environment")
struct SecretRunPlanTests {
    @Test func explicitSecretsAreKeptInOrderWithoutDuplicates() throws {
        let selection = try SecretRunSelection.resolve(
            configuration(), requested: ["OPENAI_API_KEY", "OPENAI_API_KEY"], all: false).get()
        #expect(selection.names == ["OPENAI_API_KEY"])
        #expect(selection.skipped.isEmpty)
    }

    @Test func explicitSecretsThatCannotBePlaceholdersAreRefused() throws {
        let config = try configuration()
        #expect(SecretRunSelection.resolve(config, requested: ["NOPE"], all: false) == .failure(.unknownSecret("NOPE")))
        #expect(SecretRunSelection.resolve(config, requested: ["OPENAI_API_KEY", "GH_TOKEN"], all: false)
            == .failure(.realValueDelivery("GH_TOKEN")))
        #expect(SecretRunSelection.resolve(config, requested: ["CODEX_ONLY"], all: false)
            == .failure(.agentScoped(secret: "CODEX_ONLY", agents: ["codex"])))
    }

    @Test func nothingSelectedIsRefused() throws {
        #expect(SecretRunSelection.resolve(try configuration(), requested: [], all: false) == .failure(.noSecretsSelected))
        #expect(SecretRunSelection.resolve(.empty, requested: [], all: true) == .failure(.noSecretsSelected))
    }

    @Test func allTakesEveryPlaceholderSecretAndNamesTheRest() throws {
        let config = try configuration()
        let selection = try SecretRunSelection.resolve(config, requested: [], all: true).get()
        #expect(selection.names == ["OPENAI_API_KEY"])
        #expect(selection.skipped == [
            SecretRunSkip(
                name: "CODEX_ONLY", reason: .agentScoped(["codex"]),
                definition: try #require(config.secret(named: "CODEX_ONLY"))),
            SecretRunSkip(
                name: "GH_TOKEN", reason: .realValueDelivery, definition: try #require(config.secret(named: "GH_TOKEN"))),
        ])
    }

    @Test func allWithOnlyUnstageableSecretsIsRefused() throws {
        let config = try configuration("""
            {"version":1,"secrets":[
              {"name":"GH_TOKEN","source":{"hostEnvironment":{"variable":"FAKE_GH"}},"delivery":{"environment":{}}}
            ]}
            """)
        let skip = SecretRunSkip(
            name: "GH_TOKEN", reason: .realValueDelivery, definition: try #require(config.secret(named: "GH_TOKEN")))
        #expect(SecretRunSelection.resolve(config, requested: [], all: true)
            == .failure(.nothingStageable(skipped: [skip])))
    }

    @Test func environmentDropsTheParentsRealValuesAndCarriesOnlyTheLease() throws {
        let openAI = try #require(try configuration().secret(named: "OPENAI_API_KEY"))
        let aws = SecretDefinition(
            name: "AWS_MAIN", source: .hostEnvironment(variable: "FAKE_AWS"),
            delivery: .awsSigV4(AWSSigningBinding(
                upstream: URL(string: "https://s3.us-east-1.amazonaws.com")!, region: "us-east-1", service: "s3",
                endpointEnv: "AWS_ENDPOINT_URL_S3")))
        let parent = [
            "PATH": "/usr/bin:/bin", "KEEP": "1",
            "OPENAI_API_KEY": realOpenAI, "OPENAI_BASE_URL": "https://real.example.com",
            "AWS_ACCESS_KEY_ID": "AKIAREALREALREAL", "AWS_SECRET_ACCESS_KEY": "real-secret-key",
            "AWS_SESSION_TOKEN": "real-session-token", "AWS_SECURITY_TOKEN": "real-security-token",
            "AWS_REGION": "eu-west-1",
        ]
        let lease: [(name: String, value: String)] = [
            ("OPENAI_API_KEY", "sk-rvph_0123"), ("OPENAI_BASE_URL", "http://127.0.0.1:9/s/OPENAI_API_KEY"),
            ("AWS_ACCESS_KEY_ID", "rvph_4567"), ("AWS_SECRET_ACCESS_KEY", "rv-unused-00"),
            ("AWS_REGION", "us-east-1"), ("AWS_ENDPOINT_URL_S3", "http://127.0.0.1:9/s/AWS_MAIN"),
        ]
        let built = SecretRunEnvironment.build(
            parent: parent, selected: [openAI, aws], skipped: [], lease: lease, realValues: [])
        #expect(built == [
            "PATH": "/usr/bin:/bin", "KEEP": "1",
            "OPENAI_API_KEY": "sk-rvph_0123", "OPENAI_BASE_URL": "http://127.0.0.1:9/s/OPENAI_API_KEY",
            "AWS_ACCESS_KEY_ID": "rvph_4567", "AWS_SECRET_ACCESS_KEY": "rv-unused-00",
            "AWS_REGION": "us-east-1", "AWS_ENDPOINT_URL_S3": "http://127.0.0.1:9/s/AWS_MAIN",
        ])
        let entries = SecretRunEnvironment.entries(built).joined(separator: "\n")
        #expect(entries.contains("REAL") == false)
        #expect(entries.contains("real") == false)
    }

    /// A secret read from the host environment has its real value in a
    /// variable of its own: the child must not inherit that one either.
    @Test func environmentDropsTheVariableAHostEnvironmentSourceReads() throws {
        let openAI = try #require(try configuration().secret(named: "OPENAI_API_KEY"))
        let parent = ["PATH": "/usr/bin:/bin", "FAKE_OPENAI": realOpenAI, "FAKE_GH": "gh-unselected"]
        let built = SecretRunEnvironment.build(
            parent: parent, selected: [openAI], skipped: [], lease: [("OPENAI_API_KEY", "sk-rvph_0123")], realValues: [])
        #expect(built == ["PATH": "/usr/bin:/bin", "FAKE_GH": "gh-unselected", "OPENAI_API_KEY": "sk-rvph_0123"])
    }

    /// A store login lets the command fetch the real value itself: the token
    /// rv's Vault provider reads goes when a selected secret comes from
    /// Vault, and stays when none does. The server address is no secret.
    @Test func environmentDropsTheLoginOfAProviderBackingASelectedSecret() throws {
        let vault = SecretDefinition(
            name: "VAULTED", source: .vault(path: "secret/data/app", field: "key", address: nil),
            delivery: .gateway(SecretGatewayBinding(
                upstream: URL(string: "https://api.example.com")!, baseURLEnv: "VAULTED_BASE_URL")))
        let openAI = try #require(try configuration().secret(named: "OPENAI_API_KEY"))
        let parent = ["PATH": "/usr/bin:/bin", "VAULT_TOKEN": "hvs.real", "VAULT_ADDR": "https://vault.example.com"]
        let fromVault = SecretRunEnvironment.build(parent: parent, selected: [vault], skipped: [], lease: [], realValues: [])
        #expect(fromVault == ["PATH": "/usr/bin:/bin", "VAULT_ADDR": "https://vault.example.com"])
        let elsewhere = SecretRunEnvironment.build(parent: parent, selected: [openAI], skipped: [], lease: [], realValues: [])
        #expect(elsewhere == parent)
    }

    /// The real value may sit under any name (a `.env` loader, a copy the
    /// shell made): every variable holding a selected secret's value is
    /// dropped, padded with whitespace, or inside a longer value (an
    /// `Authorization` line), and nothing else is.
    @Test func environmentDropsAnyVariableHoldingASelectedSecretsValue() throws {
        let openAI = try #require(try configuration().secret(named: "OPENAI_API_KEY"))
        let parent = [
            "PATH": "/usr/bin:/bin", "DOTENV_OPENAI": realOpenAI, "PADDED": " \(realOpenAI)\n",
            "AWS_KEY_COPY": "AKIAREALREALREAL", "PREFIXED": "x\(realOpenAI)", "OTHER": "sk-live-other",
        ]
        let real = [try #require(SecretValue(realOpenAI)), try #require(SecretValue("AKIAREALREALREAL"))]
        let built = SecretRunEnvironment.build(
            parent: parent, selected: [openAI], skipped: [], lease: [("OPENAI_API_KEY", "sk-rvph_0123")],
            realValues: real)
        #expect(built == ["PATH": "/usr/bin:/bin", "OTHER": "sk-live-other", "OPENAI_API_KEY": "sk-rvph_0123"])
        #expect(SecretRunEnvironment.copies(parent: parent, realValues: real)
            == ["AWS_KEY_COPY", "DOTENV_OPENAI", "PADDED", "PREFIXED"])
    }

    /// A value of 12 bytes or more also drops a variable it appears inside;
    /// a shorter one (a PIN, a short id) only an exact copy, so it does not
    /// take unrelated variables with it.
    @Test func onlyValuesOfTwelveBytesOrMoreDropVariablesContainingThem() throws {
        let twelve = try #require(SecretValue("abcdef123456"))
        let eleven = try #require(SecretValue("abcdef12345"))
        let parent = [
            "PATH": "/usr/bin:/bin", "HEADER": "Bearer abcdef123456", "SHORT_INSIDE": "x-abcdef12345-y",
            "SHORT_EXACT": "abcdef12345",
        ]
        #expect(SecretRunEnvironment.copies(parent: parent, realValues: [twelve]) == ["HEADER"])
        #expect(SecretRunEnvironment.copies(parent: parent, realValues: [eleven]) == ["SHORT_EXACT"])
    }

    /// `--all` passes over environment-delivered and agent-scoped secrets;
    /// whatever they would have set, and the variable a host-environment
    /// source reads, is not inherited either.
    @Test func environmentDropsWhatSkippedSecretsWouldHaveSetOrBeenReadFrom() throws {
        let config = try configuration()
        let openAI = try #require(config.secret(named: "OPENAI_API_KEY"))
        let skipped = [try #require(config.secret(named: "GH_TOKEN")), try #require(config.secret(named: "CODEX_ONLY"))]
        let parent = [
            "PATH": "/usr/bin:/bin", "KEEP": "1", "GH_TOKEN": "ghp_realtoken", "FAKE_GH": "ghp_realtoken",
            "CODEX_ONLY": "sk-codex-real", "CODEX_BASE_URL": "https://real.example.com",
        ]
        let built = SecretRunEnvironment.build(
            parent: parent, selected: [openAI], skipped: skipped, lease: [("OPENAI_API_KEY", "sk-rvph_0123")],
            realValues: [])
        #expect(built == ["PATH": "/usr/bin:/bin", "KEEP": "1", "OPENAI_API_KEY": "sk-rvph_0123"])
    }

    /// rv gives the terminal away only from the foreground and takes it
    /// back only if it gave it: a backgrounded rv leaves it with the shell.
    @Test func terminalIsHandedFromTheForegroundAndReclaimedOnlyIfHanded() {
        var job = SecretRunJobControl()
        #expect(job.handsTerminal(rvInForeground: true, sharesGroup: false, to: 100) == true)
        #expect(job.reclaimsTerminal(foreground: 100, foregroundAlive: true) == true)  // Ctrl-Z
        #expect(job.reclaimsTerminal(foreground: 100, foregroundAlive: true) == false)  // nothing left to take back
        #expect(job.handsTerminal(rvInForeground: false, sharesGroup: false, to: 100) == false)  // `bg`
        #expect(job.reclaimsTerminal(foreground: 7, foregroundAlive: true) == false)  // stops in the background
        #expect(job.handsTerminal(rvInForeground: true, sharesGroup: false, to: 100) == true)  // `fg`
        #expect(job.reclaimsTerminal(foreground: 100, foregroundAlive: false) == true)  // the command's group is gone

        var background = SecretRunJobControl()
        #expect(background.handsTerminal(rvInForeground: false, sharesGroup: false, to: 100) == false)  // `rv run … &`
        #expect(background.reclaimsTerminal(foreground: 100, foregroundAlive: true) == false)
    }

    /// While rv was stopped the shell gave the terminal to another job: rv
    /// leaves it there. It takes it only from its command's group, from a
    /// group nobody is in any more, and never when the foreground is unknown.
    @Test func terminalAnotherJobHoldsIsNotTakenBack() {
        var job = SecretRunJobControl()
        #expect(job.handsTerminal(rvInForeground: true, sharesGroup: false, to: 100) == true)
        #expect(job.reclaimsTerminal(foreground: 200, foregroundAlive: true) == false)
        #expect(job.handedTo == nil)

        #expect(job.handsTerminal(rvInForeground: true, sharesGroup: false, to: 100) == true)
        #expect(job.reclaimsTerminal(foreground: 200, foregroundAlive: false) == true)

        #expect(job.handsTerminal(rvInForeground: true, sharesGroup: false, to: 100) == true)
        #expect(job.reclaimsTerminal(foreground: nil, foregroundAlive: false) == false)
    }

    /// In a pipeline (`rv run -- x | less`) rv's group holds the other
    /// commands, which must keep the terminal: rv hands nothing. rv's own
    /// parent chain (a shell without job control) does not count.
    @Test func terminalIsNotHandedWhenRvSharesItsGroup() {
        let rv: pid_t = 500
        #expect(SecretRunJobControl.sharesGroup(members: [rv, 400], rv: rv, ancestors: [400, 1]) == false)
        #expect(SecretRunJobControl.sharesGroup(members: [rv, 400, 501], rv: rv, ancestors: [400]))
        #expect(SecretRunJobControl.sharesGroup(members: [], rv: rv, ancestors: []))  // unreadable: shared
        var job = SecretRunJobControl()
        #expect(job.handsTerminal(rvInForeground: true, sharesGroup: true, to: 100) == false)
        #expect(job.reclaimsTerminal(foreground: 100, foregroundAlive: true) == false)
    }

    /// Once released (before the leader is reaped), no signal reaches the
    /// group id, which may by then be someone else's. Each forwarded signal
    /// is followed by `SIGCONT`, so a stopped group still gets it.
    @Test func signalsStopReachingTheGroupOnceReleased() {
        let sent = Notices()
        let forwarding = SecretRunSignalTarget(send: { group, number in sent.sink("\(group) \(number)") })
        forwarding.deliver(SIGINT)
        #expect(forwarding.target(4242) == SIGINT)  // arrived before: the launch is abandoned
        forwarding.deliver(SIGTERM)
        forwarding.release()
        forwarding.deliver(SIGHUP)
        #expect(sent.all == ["4242 \(SIGTERM)", "4242 \(SIGCONT)"])
    }

    @Test func rvForwardsQuitAsWellAsInterruptTerminateAndHangup() {
        #if os(macOS)
        #expect(Set(SecretRunSignals.forwarded) == [SIGINT, SIGQUIT, SIGTERM, SIGHUP])
        #endif
    }

    @Test func waitStatusesMapToShellExitCodes() {
        #expect(SecretRunExit.code(waitStatus: 0) == 0)
        #expect(SecretRunExit.code(waitStatus: 7 << 8) == 7)
        #expect(SecretRunExit.code(waitStatus: SIGINT) == 130)
        #expect(SecretRunExit.code(waitStatus: SIGKILL) == 137)
        #expect(SecretRunExit.code(waitStatus: SIGSEGV | 0x80) == 128 + SIGSEGV)
    }

    @Test func commandsResolveOnAbsolutePathEntriesOrAsPaths() {
        let present: Set<String> = ["/opt/tools/claude", "/work/bin/run.sh", "/usr/bin/env"]
        let exists: (String) -> Bool = { present.contains($0) }
        #expect(SecretRunCommand.resolve("claude", path: "bin:/opt/tools", directory: "/work", isExecutable: exists)
            == "/opt/tools/claude")
        #expect(SecretRunCommand.resolve("run.sh", path: "bin", directory: "/work", isExecutable: exists) == nil)
        #expect(SecretRunCommand.resolve("./bin/run.sh", path: nil, directory: "/work", isExecutable: exists)
            == "/work/bin/run.sh")
        #expect(SecretRunCommand.resolve("env", path: nil, directory: "/", isExecutable: exists) == "/usr/bin/env")
        #expect(SecretRunCommand.resolve("", path: nil, directory: "/", isExecutable: exists) == nil)
    }

    @Test func refusalsUseRunnerExitCodes() {
        #expect(SecretRunRefusal.commandNotFound("x").exitCode == 127)
        #expect(SecretRunRefusal.spawnFailed("x").exitCode == 126)
        #expect(SecretRunRefusal.peerBindingUnavailable.exitCode == 125)
        #expect(SecretRunRefusal.unknownSecret("x").exitCode == 125)
    }
}

/// Serialized: a signal guard is process-wide, so two launches at once
/// would each forward the other's signals.
@Suite("SecretRun launch", .serialized)
struct SecretRunLaunchTests {
    @Test func placeholdersOnlyLeaseRefusesRealValueAndAgentScopedSecrets() throws {
        let fixture = try SecretsFixture(runSecrets)
        defer { fixture.tearDown() }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: fakeResolver, transport: RecordingUpstream().transport,
            workspace: nil)
        defer { broker.stop() }
        guard case .failure(.realValueDelivery("GH_TOKEN")) =
            broker.lease(names: ["OPENAI_API_KEY", "GH_TOKEN"], agent: nil, placeholdersOnly: true)
        else { Issue.record("environment delivery was staged"); return }
        guard case .failure(.agentScoped(secret: "CODEX_ONLY", agents: ["codex"])) =
            broker.lease(names: ["CODEX_ONLY"], agent: nil, placeholdersOnly: true)
        else { Issue.record("agent-scoped secret was not refused"); return }
        #expect(broker.liveCount == 0)
    }

    @Test func leaseCarriesTheRealValuesOnlyForScrubbing() throws {
        let fixture = try SecretsFixture(runSecrets)
        defer { fixture.tearDown() }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: fakeResolver, transport: RecordingUpstream().transport,
            workspace: nil)
        defer { broker.stop() }
        let lease = try broker.lease(names: ["OPENAI_API_KEY"], agent: nil, placeholdersOnly: true).get()
        defer { broker.revoke(lease) }
        #expect(lease.realValues == [try #require(SecretValue(realOpenAI))])
        #expect(lease.environment.contains { $0.value == realOpenAI } == false)
        // What rv run strips is built from the definitions staged, not reread from disk.
        #expect(lease.definitions.map(\.name) == ["OPENAI_API_KEY"])
    }

    #if os(macOS)
    /// The stop a supervisor observed may be followed at once by the
    /// leader's exit. Consuming the stop must not reap that exit: the zombie
    /// is what keeps the group id from being reused before the group kill.
    @Test func consumingAStopNeverReapsAnExitedLeader() throws {
        let pid = try SecretRunProcess.spawnSuspended(
            executable: "/usr/bin/true", arguments: ["true"], environment: [], descriptors: [:]).get()
        #expect(kill(pid, SIGCONT) == 0)
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
        #expect(info.si_code == CLD_EXITED)
        #expect(SecretRunProcess.consumeStop(pid) == nil)
        #expect(kill(pid, 0) == 0)  // still an unreaped zombie
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
    }

    /// A real child stops itself (as Ctrl-Z would stop it): rv takes the
    /// terminal back, stops itself so the shell sees the job stop, hands the
    /// terminal on when continued in the foreground, continues the group,
    /// and takes the terminal back once more when the command exits.
    @Test(.timeLimit(.minutes(1)))
    func aStoppedCommandStopsRvAndGetsTheTerminalBackWhenContinued() {
        let terminal = RecordingTerminal()
        let signals = SecretRunSignals()
        defer { signals.restore() }
        let result = SecretRunProcess.launch(
            executable: "/bin/sh", arguments: ["sh", "-c", "kill -STOP $$; exit 3"],
            environment: ["PATH=/usr/bin:/bin"], terminal: terminal, signals: signals
        ) { _ in .success(()) }
        #expect(result == .success(3 << 8))
        #expect(terminal.events == ["hand", "reclaim", "stopSelf", "hand", "reclaim"])
    }

    /// A signal that lands after the spawn but before the resume abandons
    /// the launch: the command never runs and its group is gone.
    @Test(.timeLimit(.minutes(1)))
    func aSignalBeforeTheResumeAbandonsTheLaunch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = RecordingTerminal()
        let signals = SecretRunSignals()
        defer { signals.restore() }
        let bound = Mutex<pid_t>(0)
        let result = SecretRunProcess.launch(
            executable: "/bin/sh", arguments: ["sh", "-c", "touch \"$1/ran\"", "sh", directory.path],
            environment: ["PATH=/usr/bin:/bin"], terminal: terminal, signals: signals
        ) { group in
            bound.withLock { $0 = group.pgid.rawValue }
            _ = kill(getpid(), SIGINT)
            let deadline = Date().addingTimeInterval(10)
            while signals.interrupted == nil, Date() < deadline { usleep(1_000) }
            return .success(())
        }
        #expect(result == .success(SIGINT))
        #expect(terminal.events.isEmpty)
        let pgid = bound.withLock { $0 }
        #expect(pgid > 1)
        #expect(kill(-pgid, 0) == -1 && errno == ESRCH)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path) == false)
    }

    /// A signal rv receives reaches the command's whole group, even while
    /// the group is stopped (rv continues it after the signal).
    @Test(.timeLimit(.minutes(1)), arguments: [SIGTERM, SIGQUIT])
    func signalsToRvReachTheCommandsGroupEvenWhenStopped(number: Int32) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("pid").path
        let signals = SecretRunSignals()
        defer { signals.restore() }
        Thread.detachNewThread {
            let deadline = Date().addingTimeInterval(20)
            var pid: pid_t = 0
            while pid == 0, Date() < deadline {
                let text = (try? String(contentsOfFile: marker, encoding: .utf8)) ?? ""
                pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                usleep(10_000)
            }
            while isStopped(pid) == false, Date() < deadline { usleep(10_000) }
            _ = kill(getpid(), number)
        }
        let script = "echo $$ > \"$1/pid.tmp\"; mv \"$1/pid.tmp\" \"$1/pid\"; kill -STOP $$; exit 0"
        let result = SecretRunProcess.launch(
            executable: "/bin/sh", arguments: ["sh", "-c", script, "sh", directory.path],
            environment: ["PATH=/usr/bin:/bin"], terminal: nil, signals: signals
        ) { _ in .success(()) }
        let status = try result.get()
        #expect(SecretRunExit.code(waitStatus: status) == 128 + number)
    }

    /// Under `nohup` rv inherits SIGHUP ignored; the command keeps it
    /// ignored instead of getting the default back.
    @Test(.timeLimit(.minutes(1)))
    func aSignalRvInheritedIgnoredStaysIgnoredForTheCommand() {
        let previous = signal(SIGHUP, SIG_IGN)
        defer { _ = signal(SIGHUP, previous) }
        let signals = SecretRunSignals()
        defer { signals.restore() }
        #expect(signals.inheritedIgnored.contains(SIGHUP))
        let result = SecretRunProcess.launch(
            executable: "/bin/sh", arguments: ["sh", "-c", "kill -HUP $$; exit 4"],
            environment: ["PATH=/usr/bin:/bin"], terminal: nil, signals: signals
        ) { _ in .success(()) }
        #expect(result == .success(4 << 8))
    }

    /// Dispositions are process-wide: every guard shares one installation,
    /// which the last one out restores, whichever order they leave in.
    /// While installed, SIGCHLD is default so nothing reaps behind rv.
    @Test func signalGuardsShareOneInstallationThatTheLastOutRestores() {
        let watched = [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGTTOU, SIGCHLD]
        let noted: sig_t = { _ in }
        let previousChild = signal(SIGCHLD, noted)
        defer { _ = signal(SIGCHLD, previousChild) }
        let before = watched.map(disposition)
        for lastOut in [0, 1] {
            let guards = [SecretRunSignals(), SecretRunSignals()]
            #expect(SecretRunSignals.installed)
            #expect(disposition(SIGINT) == ignoredDisposition)
            #expect(disposition(SIGCHLD) == 0)
            guards[1 - lastOut].restore()
            guards[1 - lastOut].restore()  // idempotent: it does not leave on the other's behalf
            #expect(SecretRunSignals.installed)
            #expect(disposition(SIGTERM) == ignoredDisposition)
            guards[lastOut].restore()
            #expect(SecretRunSignals.installed == false)
            #expect(watched.map(disposition) == before)
        }
    }
    #endif

    /// Every refusal comes before the command could run: a marker it would
    /// write is never written.
    @Test(arguments: [
        (SecretRunRequest(secrets: ["OPENAI_API_KEY"], all: false, command: []), SecretRunRefusal.emptyCommand),
        (SecretRunRequest(secrets: [], all: false, command: ["/bin/sh"]), .noSecretsSelected),
        (SecretRunRequest(secrets: ["NOPE"], all: false, command: ["/bin/sh"]), .unknownSecret("NOPE")),
        (SecretRunRequest(secrets: ["GH_TOKEN"], all: false, command: ["/bin/sh"]), .realValueDelivery("GH_TOKEN")),
        (SecretRunRequest(secrets: ["OPENAI_API_KEY"], all: false, command: ["no-such-command-rv"]),
         .commandNotFound("no-such-command-rv")),
    ])
    func refusedLaunchesNeverStartTheCommand(request: SecretRunRequest, refusal: SecretRunRefusal) throws {
        let fixture = try SecretsFixture(runSecrets)
        defer { fixture.tearDown() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = request
        if request.command == ["/bin/sh"] { request.command += ["-c", "touch ran"] }
        let result = SecretRun.execute(request, context: context(fixture, directory: directory, peers: .alwaysMember))
        #expect(result == .failure(refusal))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path) == false)
    }

    /// The probe is the real spawn and the given peer check: a check that
    /// calls everything a member, or answers nothing, binds nothing. Where
    /// no no-window spawn exists the probe cannot even start.
    @Test func capabilityProbeRefusesAPeerCheckThatBindsNothing() {
        let unavailable: SecretRunRefusal? = SecretRunProcess.isAvailable ? .peerBindingUnavailable : .spawnUnavailable
        #expect(SecretRunCapability.check(.alwaysMember) == unavailable)
        #expect(SecretRunCapability.check(.neverAnswers) == unavailable)
        #if os(macOS)
        // The kernel check (libproc) binds here; elsewhere it is whatever that platform offers.
        #expect(SecretRunCapability.check(.runtime) == nil)
        #endif
    }

    /// Linux today: the real capability check refuses in one line, exit
    /// 125, and nothing runs or resolves.
    @Test(.enabled(if: SecretRunProcess.isAvailable == false))
    func aHostWithoutASuspendedSpawnRefusesInOneLine() throws {
        let fixture = try SecretsFixture(runSecrets)
        defer { fixture.tearDown() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = SecretRunRequest(secrets: ["OPENAI_API_KEY"], all: false, command: ["/bin/sh", "-c", "touch ran"])
        let result = SecretRun.execute(request, context: context(
            fixture, directory: directory, peers: .runtime, capability: SecretRunCapability.check))
        #expect(result == .failure(.spawnUnavailable))
        #expect(SecretRunRefusal.spawnUnavailable.message.contains("\n") == false)
        #expect(SecretRunRefusal.spawnUnavailable.exitCode == 125)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path) == false)
        #expect(fixture.auditText.isEmpty)
    }

    @Test(arguments: [SecretRunRefusal.peerBindingUnavailable, .spawnUnavailable])
    func anIncapableHostRefusesBeforeAnythingResolves(refusal: SecretRunRefusal) throws {
        let fixture = try SecretsFixture(runSecrets)
        defer { fixture.tearDown() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = SecretRunRequest(secrets: ["OPENAI_API_KEY"], all: false, command: ["/bin/sh", "-c", "touch ran"])
        let result = SecretRun.execute(request, context: context(
            fixture, directory: directory, peers: .runtime, capability: { _ in refusal }))
        #expect(result == .failure(refusal))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path) == false)
        #expect(fixture.auditText.isEmpty)
    }

    /// If binding fails after the spawn, the suspended child is killed
    /// before it runs, its group is gone, and the launch fails.
    @Test(.enabled(if: SecretRunProcess.isAvailable), .timeLimit(.minutes(1)))
    func aFailedBindKillsTheSuspendedChildBeforeItRuns() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bound = Mutex<pid_t>(0)
        let result = SecretRunProcess.launch(
            executable: "/bin/sh", arguments: ["sh", "-c", "touch \"$1/ran\"", "sh", directory.path],
            environment: ["PATH=/usr/bin:/bin"], manageTerminal: false
        ) { group in
            bound.withLock { $0 = group.pgid.rawValue }
            return .failure(.bindFailed("test"))
        }
        #expect(result == .failure(.bindFailed("test")))
        let pgid = bound.withLock { $0 }
        #expect(pgid > 1)
        #expect(kill(-pgid, 0) == -1 && errno == ESRCH)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path) == false)
    }

    /// The real spawn and kernel peer check: the child leads its own group,
    /// sees only a placeholder, spends it through the gateway, and the
    /// gateway is gone once it exits.
    @Test(.enabled(if: hostRunsSecretRun), .timeLimit(.minutes(1)))
    func commandSeesPlaceholdersLeadsItsGroupAndSpendsThroughTheGateway() throws {
        let fixture = try SecretsFixture(runSecrets)
        defer { fixture.tearDown() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = RecordingUpstream(status: 200)
        let notices = Notices()
        let script = """
            env > "$1/env"; ps -o pgid= -p $$ | tr -d ' ' > "$1/pgid"; echo $$ > "$1/pid"
            /usr/bin/curl -s --max-time 10 --noproxy '*' -o /dev/null -w '%{http_code}' \
              -H "Authorization: Bearer $OPENAI_API_KEY" "$OPENAI_BASE_URL/models" > "$1/status"
            exit 7
            """
        let request = SecretRunRequest(
            secrets: ["OPENAI_API_KEY"], all: false, command: ["/bin/sh", "-c", script, "sh", directory.path])
        let result = SecretRun.execute(request, context: context(
            fixture, directory: directory, peers: .runtime, capability: SecretRunCapability.check,
            transport: upstream.transport, notices: notices,
            environment: [
                "PATH": "/usr/bin:/bin", "KEEP": "1", "OPENAI_API_KEY": realOpenAI, "FAKE_OPENAI": realOpenAI,
                "DOTENV_COPY": realOpenAI,
            ]))
        #expect(result == .success(7))

        func read(_ name: String) -> String {
            let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let environment = read("env")
        #expect(environment.contains("OPENAI_API_KEY=sk-rvph_"))
        #expect(environment.contains("REAL") == false)
        #expect(environment.contains("FAKE_OPENAI") == false)
        #expect(environment.contains("DOTENV_COPY") == false)
        #expect(notices.all.contains { $0.contains("DOTENV_COPY") && $0.contains(realOpenAI) == false })
        #expect(environment.contains("KEEP=1"))
        #expect(read("pid").isEmpty == false)
        #expect(read("pgid") == read("pid"))
        #expect(read("status") == "200")
        #expect(upstream.requests.first?.headers["authorization"] == "Bearer \(realOpenAI)")
        #expect(notices.all.contains { $0.contains("Not a sandbox") })

        let baseURL = environment.split(separator: "\n").first { $0.hasPrefix("OPENAI_BASE_URL=") }
        let port = try #require(baseURL.flatMap { URL(string: String($0.dropFirst("OPENAI_BASE_URL=".count)))?.port })
        #expect(loopbackAccepts(port: port) == false)
    }

    @Test(.enabled(if: hostRunsSecretRun), .timeLimit(.minutes(1)))
    func signalExitsAreReportedAndLeftoverGroupMembersKilled() throws {
        let fixture = try SecretsFixture(runSecrets)
        defer { fixture.tearDown() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = SecretRunRequest(
            secrets: ["OPENAI_API_KEY"], all: false,
            command: ["/bin/sh", "-c", "sleep 30 & echo $! > \"$1/bg\"; kill -TERM $$", "sh", directory.path])
        let result = SecretRun.execute(request, context: context(fixture, directory: directory, peers: .runtime))
        #expect(result == .success(128 + SIGTERM))
        let text = try String(contentsOf: directory.appendingPathComponent("bg"), encoding: .utf8)
        let leftover = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = Date().addingTimeInterval(5)
        while kill(leftover, 0) == 0, Date() < deadline { usleep(20_000) }
        #expect(kill(leftover, 0) == -1 && errno == ESRCH)
    }

    /// `--all` names what it passes over, and the command inherits none of
    /// it: not the variables those secrets would set, not the variable a
    /// host-environment source reads.
    @Test(.enabled(if: hostRunsSecretRun), .timeLimit(.minutes(1)))
    func allKeepsSkippedSecretsOutOfTheCommandsEnvironment() throws {
        let fixture = try SecretsFixture(runSecrets)
        defer { fixture.tearDown() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notices = Notices()
        let request = SecretRunRequest(
            secrets: [], all: true, command: ["/bin/sh", "-c", "env > \"$1/env\"", "sh", directory.path])
        let result = SecretRun.execute(request, context: context(
            fixture, directory: directory, peers: .runtime, notices: notices,
            environment: [
                "PATH": "/usr/bin:/bin", "KEEP": "1", "GH_TOKEN": "ghp_realtoken", "FAKE_GH": "ghp_realtoken",
                "CODEX_ONLY": "sk-codex-real", "CODEX_BASE_URL": "https://real.example.com",
            ]))
        #expect(result == .success(0))
        let environment = try String(contentsOf: directory.appendingPathComponent("env"), encoding: .utf8)
        for name in ["GH_TOKEN=", "FAKE_GH=", "CODEX_ONLY=", "CODEX_BASE_URL="] {
            #expect(environment.split(separator: "\n").contains { $0.hasPrefix(name) } == false)
        }
        #expect(environment.contains("KEEP=1"))
        for name in ["GH_TOKEN", "CODEX_ONLY"] {
            #expect(notices.all.contains {
                $0.contains("not staging \(name)") && $0.contains("removed from the command's environment")
            })
        }
    }

    /// A Ctrl-C while rv probes the host lands in rv's guard, not in the
    /// default action that would leave the suspended probe child behind:
    /// rv reports it as the exit code and starts nothing.
    @Test(.enabled(if: SecretRunProcess.isAvailable), .timeLimit(.minutes(1)))
    func anInterruptDuringTheCapabilityProbeEndsTheRunBeforeAnythingResolves() throws {
        let fixture = try SecretsFixture(runSecrets)
        defer { fixture.tearDown() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probed = Notices()
        let interrupting: @Sendable (GatewayPeerCheck) -> SecretRunRefusal? = { _ in
            probed.sink("guarded=\(SecretRunSignals.installed)")
            _ = kill(getpid(), SIGINT)
            usleep(200_000)  // the guard's signal source runs on its own queue
            return nil
        }
        let request = SecretRunRequest(secrets: ["OPENAI_API_KEY"], all: false, command: ["/bin/sh", "-c", "touch ran"])
        let result = SecretRun.execute(request, context: context(
            fixture, directory: directory, peers: .runtime, capability: interrupting))
        #expect(probed.all == ["guarded=true"])
        #expect(result == .success(128 + SIGINT))
        #expect(SecretRunSignals.installed == false)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran").path) == false)
        #expect(fixture.auditText.isEmpty)
    }
}

#if os(macOS)
/// Stands in for rv's terminal: models which group holds the foreground and
/// records what `supervise` asks of it. rv never stops itself here.
private final class RecordingTerminal: SecretRunTerminalControl {
    private(set) var events: [String] = []
    private var foreground = getpgrp()

    var rvInForeground: Bool { foreground == getpgrp() }
    var foregroundGroup: pid_t? { foreground }
    var sharesGroup: Bool { false }

    func hand(to group: pid_t) -> Bool {
        events.append("hand")
        foreground = group
        return true
    }

    func reclaim() {
        events.append("reclaim")
        foreground = getpgrp()
    }

    func stopSelf() { events.append("stopSelf") }
}

/// The handler installed for `number`, as a number: 0 is `SIG_DFL`.
private func disposition(_ number: Int32) -> Int {
    var action = sigaction()
    _ = sigaction(number, nil, &action)
    return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
}

private let ignoredDisposition = unsafeBitCast(SIG_IGN as sig_t?, to: Int.self)

/// Whether `pid` is stopped (`SSTOP` in `<sys/proc.h>`).
private func isStopped(_ pid: pid_t) -> Bool {
    guard pid > 1, case .found(let info) = ProcessGroupRecovery.lookup(pid) else { return false }
    return info.pbi_status == 4
}
#endif

/// Whether anything listens on 127.0.0.1:`port`.
private func loopbackAccepts(port: Int) -> Bool {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}
