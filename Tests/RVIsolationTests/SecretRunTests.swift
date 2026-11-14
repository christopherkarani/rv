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
        let selection = try SecretRunSelection.resolve(configuration(), requested: [], all: true).get()
        #expect(selection.names == ["OPENAI_API_KEY"])
        #expect(selection.skipped == [
            SecretRunSkip(name: "CODEX_ONLY", reason: .agentScoped(["codex"])),
            SecretRunSkip(name: "GH_TOKEN", reason: .realValueDelivery),
        ])
    }

    @Test func allWithOnlyUnstageableSecretsIsRefused() throws {
        let config = try configuration("""
            {"version":1,"secrets":[
              {"name":"GH_TOKEN","source":{"hostEnvironment":{"variable":"FAKE_GH"}},"delivery":{"environment":{}}}
            ]}
            """)
        #expect(SecretRunSelection.resolve(config, requested: [], all: true)
            == .failure(.nothingStageable(skipped: [SecretRunSkip(name: "GH_TOKEN", reason: .realValueDelivery)])))
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
        let built = SecretRunEnvironment.build(parent: parent, selected: [openAI, aws], lease: lease, realValues: [])
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
            parent: parent, selected: [openAI], lease: [("OPENAI_API_KEY", "sk-rvph_0123")], realValues: [])
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
        let fromVault = SecretRunEnvironment.build(parent: parent, selected: [vault], lease: [], realValues: [])
        #expect(fromVault == ["PATH": "/usr/bin:/bin", "VAULT_ADDR": "https://vault.example.com"])
        let elsewhere = SecretRunEnvironment.build(parent: parent, selected: [openAI], lease: [], realValues: [])
        #expect(elsewhere == parent)
    }

    /// The real value may sit under any name (a `.env` loader, a copy the
    /// shell made): every variable holding a selected secret's value is
    /// dropped, padded with whitespace or not, and nothing else is.
    @Test func environmentDropsAnyVariableHoldingASelectedSecretsValue() throws {
        let openAI = try #require(try configuration().secret(named: "OPENAI_API_KEY"))
        let parent = [
            "PATH": "/usr/bin:/bin", "DOTENV_OPENAI": realOpenAI, "PADDED": " \(realOpenAI)\n",
            "AWS_KEY_COPY": "AKIAREALREALREAL", "PREFIXED": "x\(realOpenAI)", "OTHER": "sk-live-other",
        ]
        let real = [try #require(SecretValue(realOpenAI)), try #require(SecretValue("AKIAREALREALREAL"))]
        let built = SecretRunEnvironment.build(
            parent: parent, selected: [openAI], lease: [("OPENAI_API_KEY", "sk-rvph_0123")], realValues: real)
        #expect(built == [
            "PATH": "/usr/bin:/bin", "PREFIXED": "x\(realOpenAI)", "OTHER": "sk-live-other",
            "OPENAI_API_KEY": "sk-rvph_0123",
        ])
        #expect(SecretRunEnvironment.copies(parent: parent, realValues: real) == ["AWS_KEY_COPY", "DOTENV_OPENAI", "PADDED"])
    }

    /// rv gives the terminal away only from the foreground and takes it
    /// back only if it gave it: a backgrounded rv leaves it with the shell.
    @Test func terminalIsHandedFromTheForegroundAndReclaimedOnlyIfHanded() {
        var foreground = SecretRunJobControl()
        #expect(foreground.handsTerminal(rvInForeground: true))
        #expect(foreground.reclaimsTerminal())  // Ctrl-Z
        #expect(foreground.reclaimsTerminal() == false)  // nothing left to take back
        #expect(foreground.handsTerminal(rvInForeground: false) == false)  // `bg`
        #expect(foreground.reclaimsTerminal() == false)  // stops or exits in the background
        #expect(foreground.handsTerminal(rvInForeground: true))  // `fg`
        #expect(foreground.reclaimsTerminal())

        var background = SecretRunJobControl()
        #expect(background.handsTerminal(rvInForeground: false) == false)  // `rv run … &`
        #expect(background.reclaimsTerminal() == false)
    }

    /// Once released (before the leader is reaped), no signal reaches the
    /// group id, which may by then be someone else's.
    @Test func signalsStopReachingTheGroupOnceReleased() {
        let sent = Notices()
        let forwarding = SecretRunSignalTarget(send: { group, number in sent.sink("\(group) \(number)") })
        forwarding.deliver(SIGINT)
        #expect(forwarding.target(4242) == SIGINT)  // arrived before: the launch is abandoned
        forwarding.deliver(SIGTERM)
        forwarding.release()
        forwarding.deliver(SIGHUP)
        #expect(sent.all == ["4242 \(SIGTERM)"])
    }

    @Test func waitStatusesMapToShellExitCodes() {
        #expect(SecretRunExit.code(waitStatus: 0) == 0)
        #expect(SecretRunExit.code(waitStatus: 7 << 8) == 7)
        #expect(SecretRunExit.code(waitStatus: SIGINT) == 130)
        #expect(SecretRunExit.code(waitStatus: SIGKILL) == 137)
        #expect(SecretRunExit.code(waitStatus: SIGSEGV | 0x80) == 128 + SIGSEGV)
        #expect(SecretRunExit.isStopped(waitStatus: (SIGTSTP << 8) | 0x7f))
        #expect(SecretRunExit.isStopped(waitStatus: 0) == false)
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

@Suite("SecretRun launch")
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
    @Test(.enabled(if: SecretRunProcess.isAvailable))
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
    @Test(.enabled(if: hostRunsSecretRun))
    func commandSeesPlaceholdersLeadsItsGroupAndSpendsThroughTheGateway() throws {
        let fixture = try SecretsFixture(runSecrets)
        defer { fixture.tearDown() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = RecordingUpstream(status: 200)
        let notices = Notices()
        let script = """
            env > "$1/env"; ps -o pgid= -p $$ | tr -d ' ' > "$1/pgid"; echo $$ > "$1/pid"
            /usr/bin/curl -s --noproxy '*' -o /dev/null -w '%{http_code}' \
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

    @Test(.enabled(if: hostRunsSecretRun))
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
}

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
