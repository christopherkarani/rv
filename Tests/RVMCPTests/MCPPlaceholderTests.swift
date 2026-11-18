#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
@testable import RVIsolation
import Synchronization
import Testing
@testable import RVMCP

let placeholderSecretsJSON = """
    {"version":1,"secrets":[
      {"name":"OPENAI_API_KEY","source":{"keychain":{"service":"rv.secrets","account":"OPENAI_API_KEY"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"OPENAI_BASE_URL",
                              "placeholderPrefix":"sk-"}}},
      {"name":"APPROVED","source":{"keychain":{"service":"rv.secrets","account":"OPENAI_API_KEY"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"APPROVED_BASE_URL",
                              "approve":[{"methods":["DELETE"],"path":"/v1/**"}]}}},
      {"name":"CODEX_ONLY","agents":["codex"],
       "source":{"keychain":{"service":"rv.secrets","account":"OPENAI_API_KEY"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"CODEX_BASE_URL"}}},
      {"name":"HOST_SOURCED","source":{"hostEnvironment":{"variable":"FAKE_OPENAI"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"HOST_BASE_URL"}}},
      {"name":"ALIAS","source":{"keychain":{"service":"rv.secrets","account":"OPENAI_API_KEY"}},
       "delivery":{"environment":{}}},
      {"name":"GH_TOKEN","source":{"keychain":{"service":"rv.secrets","account":"GH_TOKEN"}},
       "delivery":{"environment":{}}}
    ]}
    """

/// The value behind OPENAI_API_KEY, and so behind ALIAS and APPROVED too.
let placeholderRealValue = "sk-live-REAL-0123456789"
/// The value behind GH_TOKEN.
let otherRealValue = "ghp_realtoken0123456789"

/// Counts every resolution; answers by keychain account.
final class CountingResolver: Sendable {
    let count = Mutex(0)
    var resolver: SecretResolver {
        SecretResolver { source in
            self.count.withLock { $0 += 1 }
            if case .keychain(_, "GH_TOKEN") = source { return .success(SecretValue(otherRealValue)!) }
            return .success(SecretValue(placeholderRealValue)!)
        }
    }
}

/// A temporary config directory holding a 0600 secrets.json.
struct PlaceholderSecretsFixture {
    let directory: URL

    init(_ json: String = placeholderSecretsJSON) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-mcp-placeholders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = SecretsConfiguration.fileURL(configDirectory: directory)
        try Data(json.utf8).write(to: file)
        chmod(file.path, 0o600)
    }

    static func definitions() throws -> SecretsConfiguration {
        try SecretsConfiguration.decode(Data(placeholderSecretsJSON.utf8)).get()
    }

    var auditText: String {
        (try? String(contentsOf: directory.appendingPathComponent("audit.jsonl"), encoding: .utf8)) ?? ""
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Stands in for `MCPSandbox.apply`: runs the launch under sandbox-exec
/// with a placeholder profile. The profile text itself is tested elsewhere.
func cagingHook(
    _ definition: MCPServerDefinition, _ launch: MCPUpstreamLaunch, _ reach: MCPCageReach
) -> Result<MCPUpstreamLaunch, MCPLaunchError> {
    var caged = launch
    caged.executable = MCPSandbox.sandboxExec
    caged.arguments = ["-p", "(version 1)", launch.executable] + launch.arguments
    return .success(caged)
}

private func leasing(
    platformSupported: Bool = true, capability: @escaping @Sendable () -> String? = { nil },
    lease: @escaping @Sendable (String, [String]) -> Result<SecretPlaceholderLease, SecretPlaceholderLeaseError> = { _, _ in
        .failure(.gatewayUnavailable)
    }
) -> MCPPlaceholderLeasing {
    MCPPlaceholderLeasing(platformSupported: platformSupported, capability: capability, lease: lease)
}

private func leasing(_ broker: SecretPlaceholderBroker) -> MCPPlaceholderLeasing {
    leasing(lease: { server, names in broker.lease(names, server: server) })
}

private func bound(
    _ name: String = "bound", placeholders: [String] = ["OPENAI_API_KEY"], args: [String] = ["-c", "true"],
    environment: [String: String] = [:], secrets: [String: String] = [:],
    sandbox: MCPSandboxPolicy? = MCPSandboxPolicy(network: false)
) -> MCPServerDefinition {
    MCPServerDefinition(
        name: name, command: "/bin/sh", args: args, environment: environment, secrets: secrets,
        sandbox: sandbox, placeholders: placeholders)
}

private let plain = MCPServerDefinition(
    name: "plain", command: "/bin/sh", args: ["-c", "true"], sandbox: MCPSandboxPolicy(network: false))

@Suite("MCP server placeholders: configuration")
struct MCPPlaceholderConfigurationTests {
    private func decode(_ text: String) -> Result<MCPConfiguration, MCPConfigurationError> {
        MCPConfiguration.decode(Data(text.utf8))
    }

    private func server(_ body: String) -> String {
        #"{"version":1,"servers":[{"name":"s",\#(body)}]}"#
    }

    @Test func placeholdersRoundTrip() throws {
        let configuration = try decode(server(
            #""command":"x","placeholders":["OPENAI_API_KEY","AWS_MAIN"],"sandbox":{"network":false}"#)).get()
        #expect(configuration.server(named: "s")?.placeholders == ["OPENAI_API_KEY", "AWS_MAIN"])
        let text = configuration.encoded().compactText
        #expect(text.contains(#""placeholders":["OPENAI_API_KEY","AWS_MAIN"]"#))
        #expect(try MCPConfiguration.decode(Data(text.utf8)).get() == configuration)
    }

    /// A file without the field encodes, and so signs and digests, as before.
    @Test func aServerWithoutPlaceholdersEncodesWithoutTheField() throws {
        let configuration = try decode(MCPConfigurationTests.example).get()
        #expect(configuration.servers.allSatisfy { $0.placeholders.isEmpty })
        #expect(configuration.encoded().compactText.contains("placeholders") == false)
        #expect(MCPServerDefinition(name: "a", command: "x") == MCPServerDefinition(name: "a", command: "x", placeholders: []))
    }

    @Test func mistakenPlaceholdersAreRejected() {
        let cases: [(String, String)] = [
            (server(#""command":"x","placeholders":["A","A"]"#), "server s placeholders lists A twice"),
            (server(#""command":"x","placeholders":"A""#), "placeholders must be an array of secret names"),
            (server(#""command":"x","placeholders":["not a name"]"#), "placeholders must be an array of secret names"),
            (server(#""command":"x","secrets":{"TOKEN":"A"},"placeholders":["A"]"#),
             "gets secret A as its real value (secrets or args) and as a placeholder"),
            (server(#""command":"x","args":["--key=${secret:A}"],"placeholders":["A"]"#),
             "gets secret A as its real value (secrets or args) and as a placeholder"),
            (server(#""url":"https://a.example/mcp","placeholders":["A"]"#),
             "server s is remote; placeholders are only for local (command) servers"),
            (server(#""command":"x","placeholder":["A"]"#), "unknown key placeholder"),
        ]
        for (text, expected) in cases {
            guard case .failure(let error) = decode(text) else {
                Issue.record("accepted \(text)")
                continue
            }
            #expect(error.message.contains(expected), "\(error.message)")
        }
        let many = (0...SecretsConfiguration.maximumSecrets).map { "\"S\($0)\"" }.joined(separator: ",")
        guard case .failure(let error) = decode(server(#""command":"x","placeholders":[\#(many)]"#)) else {
            Issue.record("accepted more placeholders than secrets.json can hold")
            return
        }
        #expect(error.message.contains("more than \(SecretsConfiguration.maximumSecrets)"))
    }
}

@Suite("MCP server placeholders: planner")
struct MCPPlaceholderPlannerTests {
    private func plan(
        _ servers: [MCPServerDefinition], secrets: SecretsConfiguration, resolver: SecretResolver,
        requireSandbox: Bool = true, placeholders: MCPPlaceholderLeasing,
        sandbox: @escaping (MCPServerDefinition, MCPUpstreamLaunch, MCPCageReach) -> Result<MCPUpstreamLaunch, MCPLaunchError>
            = cagingHook
    ) -> Result<[(MCPGatewayCore.Upstream, MCPUpstreamConnection)], MCPLaunchError> {
        MCPLaunchPlanner.plan(
            servers: servers.map(\.name), configuration: MCPConfiguration(servers: servers), secrets: secrets,
            resolver: resolver, baseEnvironment: ["PATH": "/usr/bin:/bin"], requireSandbox: requireSandbox,
            sandbox: sandbox, placeholders: placeholders)
    }

    private func refusal(
        _ server: MCPServerDefinition, requireSandbox: Bool = true, placeholders: MCPPlaceholderLeasing = leasing()
    ) throws -> MCPPlaceholderRefusal? {
        let planned = try plan(
            [server, plain], secrets: PlaceholderSecretsFixture.definitions(), resolver: CountingResolver().resolver,
            requireSandbox: requireSandbox, placeholders: placeholders).get()
        // The other server still starts.
        #expect(planned.last?.1.process != nil)
        guard case .refused(let name, let refusal) = planned.first?.1 else { return nil }
        #expect(name == server.name)
        return refusal
    }

    /// `secrets` as decoded, with OPENAI_API_KEY's upstream replaced. The
    /// decoder takes only https; a definition built in code is checked again.
    private func secrets(upstream: String) throws -> SecretsConfiguration {
        var definitions = try PlaceholderSecretsFixture.definitions().secrets
        let index = try #require(definitions.firstIndex { $0.name == "OPENAI_API_KEY" })
        guard case .gateway(var binding) = definitions[index].delivery else {
            Issue.record("OPENAI_API_KEY is not a gateway secret")
            return SecretsConfiguration()
        }
        binding.upstream = try #require(URL(string: upstream))
        definitions[index].delivery = .gateway(binding)
        return SecretsConfiguration(secrets: definitions)
    }

    @Test func eachReasonRefusesOnlyThatServer() throws {
        #expect(try refusal(bound(), placeholders: leasing(platformSupported: false)) == .unsupportedPlatform)
        #expect(try refusal(bound(), requireSandbox: false) == .cageUnavailable)
        #expect(try refusal(bound(sandbox: nil)) == .noSandbox)
        #expect(try refusal(bound(sandbox: MCPSandboxPolicy(network: true))) == .unconfinedNetwork)
        #expect(try refusal(bound(secrets: ["KEY": "OPENAI_API_KEY"])) == .realValueToo("OPENAI_API_KEY"))
        #expect(try refusal(bound(placeholders: ["MISSING"])) == .unknownSecret("MISSING"))
        #expect(try refusal(bound(placeholders: ["GH_TOKEN"])) == .environmentDelivery("GH_TOKEN"))
        #expect(try refusal(bound(placeholders: ["HOST_SOURCED"])) == .hostEnvironmentSource("HOST_SOURCED"))
        #expect(try refusal(bound(placeholders: ["CODEX_ONLY"])) == .agentScoped(secret: "CODEX_ONLY", agents: ["codex"]))
        #expect(try refusal(bound(placeholders: ["APPROVED"])) == .approvalRules("APPROVED"))
        #expect(try refusal(bound(environment: ["OPENAI_BASE_URL": "https://elsewhere.example"]))
            == .variableCollision("OPENAI_BASE_URL"))
        #expect(try refusal(bound(secrets: ["OPENAI_API_KEY": "GH_TOKEN"])) == .variableCollision("OPENAI_API_KEY"))
        #expect(try refusal(bound(), placeholders: leasing(capability: { "no peer binding" }))
            == .capabilityUnavailable("no peer binding"))
        #expect(try refusal(bound(), placeholders: leasing(lease: { _, _ in .failure(.refused("vault locked")) }))
            == .leaseFailed("vault locked"))
    }

    @Test func aPlaintextUpstreamIsRefusedUnlessItIsLoopback() throws {
        func refusal(_ upstream: String) throws -> MCPPlaceholderRefusal? {
            MCPPlaceholderPlanning.refusal(
                bound(), platformSupported: true, cageEnforced: true, secrets: try secrets(upstream: upstream))
        }
        #expect(try refusal("http://api.example.com/v1") == .plaintextUpstream("OPENAI_API_KEY"))
        #expect(try refusal("ftp://api.example.com/v1") == .plaintextUpstream("OPENAI_API_KEY"))
        #expect(try refusal("http://127.0.0.1:8080/v1") == nil)
        #expect(try refusal("http://localhost:8080/v1") == nil)
        #expect(try refusal("http://[::1]:8080/v1") == nil)
        #expect(try refusal("https://api.example.com/v1") == nil)
        // Only the exact loopback names pass; anything that merely looks
        // like one, or reaches loopback by another spelling, is refused.
        for lookalike in [
            "http://localhost.evil.com/v1", "http://127.0.0.1.evil.com/v1", "http://evil.com/127.0.0.1",
            "http://127.0.0.1@evil.com/v1", "http://localhost:x@evil.com/v1", "http://0.0.0.0:8080/v1",
            "http://127.0.0.2/v1", "http://127.1/v1", "http://2130706433/v1", "http://0x7f000001/v1",
            "http://017700000001/v1", "http://localhost./v1", "http://[::ffff:127.0.0.1]/v1",
            "http://[::2]/v1", "http:/127.0.0.1/v1", "http:127.0.0.1/v1",
        ] {
            #expect(try refusal(lookalike) == .plaintextUpstream("OPENAI_API_KEY"), "\(lookalike)")
        }
        // Case does not matter; the host is what is dialled, not the userinfo.
        #expect(try refusal("HTTP://LOCALHOST:8080/v1") == nil)
        #expect(try refusal("Http://127.0.0.1/v1") == nil)
        #expect(try refusal("http://evil.com@127.0.0.1/v1") == nil)
        #expect(try refusal("http://[::1]/v1") == nil)
        // https is protected whatever the host; this one is TLS to evil.com.
        #expect(try refusal("https://127.0.0.1@evil.com/v1") == nil)
        #expect(MCPPlaceholderPlanning.origin(try #require(URL(string: "https://api.example.com/v1"))) == "https://api.example.com")
        #expect(MCPPlaceholderPlanning.origin(try #require(URL(string: "http://127.0.0.1:8080/v1"))) == "http://127.0.0.1:8080")
    }

    /// The probe runs once per plan, and a server that cannot be bound
    /// resolves nothing: no prompt, no unlock.
    @Test func capabilityIsAskedOnceAndBeforeAnySecretResolves() throws {
        let asked = Mutex(0)
        let resolver = CountingResolver()
        let planned = try plan(
            [bound("one", secrets: ["REAL": "GH_TOKEN"]), bound("two", secrets: ["REAL": "GH_TOKEN"])],
            secrets: PlaceholderSecretsFixture.definitions(), resolver: resolver.resolver,
            placeholders: leasing(capability: {
                asked.withLock { $0 += 1 }
                return "no peer binding"
            })).get()
        #expect(asked.withLock { $0 } == 1)
        #expect(resolver.count.withLock { $0 } == 0)
        for entry in planned {
            guard case .refused(_, .capabilityUnavailable) = entry.1 else {
                Issue.record("\(entry.1.server) was not refused")
                continue
            }
        }
    }

    /// Every refusal that needs no value is decided before the server's own
    /// `secrets` are resolved: a server that will not start prompts nothing.
    @Test func aServerRefusedBeforeLaunchResolvesNoneOfItsSecrets() throws {
        let fixture = try PlaceholderSecretsFixture()
        defer { fixture.tearDown() }
        let broker = SecretPlaceholderBroker(configDirectory: fixture.directory, resolver: CountingResolver().resolver)
        defer { broker.stop() }
        let colliding = SecretPlaceholderLease(
            broker: broker.broker, lease: SecretLease(placeholders: [], environment: [(name: "PATH", value: "ph")]),
            gatewayPort: 1)
        let cases: [(MCPServerDefinition, MCPPlaceholderLeasing, MCPPlaceholderRefusal)] = [
            (bound(placeholders: ["HOST_SOURCED"], secrets: ["REAL": "GH_TOKEN"]), leasing(broker),
             .hostEnvironmentSource("HOST_SOURCED")),
            (bound(secrets: ["REAL": "GH_TOKEN"]), leasing(lease: { _, _ in .failure(.refused("vault locked")) }),
             .leaseFailed("vault locked")),
            (bound(secrets: ["REAL": "GH_TOKEN"]), leasing(lease: { _, _ in .success(colliding) }),
             .variableCollision("PATH")),
        ]
        for (server, placeholders, expected) in cases {
            let resolver = CountingResolver()
            let planned = try plan(
                [server], secrets: PlaceholderSecretsFixture.definitions(), resolver: resolver.resolver,
                placeholders: placeholders).get()
            guard case .refused(_, let refusal) = planned.first?.1 else {
                Issue.record("not refused: \(String(describing: planned.first?.1))")
                continue
            }
            #expect(refusal == expected)
            #expect(resolver.count.withLock { $0 } == 0, "\(expected) resolved a secret")
        }
        #expect(broker.broker.liveCount == 0)
    }

    @Test func aBoundServerHoldsPlaceholdersAndItsOtherSecretsRealValues() throws {
        let fixture = try PlaceholderSecretsFixture()
        defer { fixture.tearDown() }
        let broker = SecretPlaceholderBroker(configDirectory: fixture.directory, resolver: CountingResolver().resolver)
        defer { broker.stop() }
        let reaches = Mutex<[String: MCPCageReach]>([:])
        let planned = try plan(
            [bound(secrets: ["REAL": "GH_TOKEN"]), plain], secrets: PlaceholderSecretsFixture.definitions(),
            resolver: CountingResolver().resolver, placeholders: leasing(broker),
            sandbox: { definition, launch, reach in
                reaches.withLock { $0[definition.name] = reach }
                return cagingHook(definition, launch, reach)
            }).get()
        guard case .placeholderBound(let launch, let binding) = planned.first?.1 else {
            Issue.record("not bound: \(String(describing: planned.first?.1))")
            return
        }
        #expect(launch.executable == MCPSandbox.sandboxExec)
        // Only the placeholder server's cage may dial the gateway.
        #expect(reaches.withLock { $0 } == ["bound": .secretsGateway(port: binding.lease.gatewayPort), "plain": .standard])
        #expect(launch.environment["OPENAI_API_KEY"]?.hasPrefix("sk-rvph_") == true)
        #expect(launch.environment["OPENAI_BASE_URL"] == "http://127.0.0.1:\(binding.lease.gatewayPort)/s/OPENAI_API_KEY")
        // `secrets` keeps its meaning: that one real value, scrubbed from replies.
        #expect(launch.environment["REAL"] == otherRealValue)
        #expect(planned.first?.0.secretValues.map { $0.name } == ["GH_TOKEN"])
        #expect(launch.environment.values.contains { $0.contains(placeholderRealValue) } == false)
        #expect(launch.arguments.contains { $0.contains(placeholderRealValue) } == false)
        #expect(fixture.auditText.contains("\"runtime\":\"mcp:bound\""))
        binding.lease.revoke()
        #expect(broker.broker.liveCount == 0)
    }

    /// A placeholder's real value under another secret's name, as a literal
    /// in `env`, or in an argument: the server would hold it after all.
    @Test func aServerThatWouldHoldAPlaceholdersRealValueByAnyNameIsRefused() throws {
        let fixture = try PlaceholderSecretsFixture()
        defer { fixture.tearDown() }
        let broker = SecretPlaceholderBroker(configDirectory: fixture.directory, resolver: CountingResolver().resolver)
        defer { broker.stop() }
        let servers = [
            bound(secrets: ["OTHER": "ALIAS"]),
            bound(environment: ["LITERAL": placeholderRealValue]),
            bound(environment: ["AUTH": "Bearer " + placeholderRealValue]),
            bound(args: ["-c", "true", "--key=" + placeholderRealValue]),
        ]
        for server in servers {
            let planned = try plan(
                [server], secrets: PlaceholderSecretsFixture.definitions(), resolver: CountingResolver().resolver,
                placeholders: leasing(broker)).get()
            guard case .refused(_, let refusal) = planned.first?.1 else {
                Issue.record("bound although it holds the real value: \(server)")
                continue
            }
            #expect(refusal == .realValueToo("OPENAI_API_KEY"))
            #expect(broker.broker.liveCount == 0)
        }
    }

    @Test func aLaunchTheHookLeavesUncagedIsRefusedAndItsLeaseRevoked() throws {
        let fixture = try PlaceholderSecretsFixture()
        defer { fixture.tearDown() }
        let broker = SecretPlaceholderBroker(configDirectory: fixture.directory, resolver: CountingResolver().resolver)
        defer { broker.stop() }
        let planned = try plan(
            [bound()], secrets: PlaceholderSecretsFixture.definitions(), resolver: CountingResolver().resolver,
            placeholders: leasing(broker), sandbox: { _, launch, _ in .success(launch) }).get()
        guard case .refused(_, .uncaged) = planned.first?.1 else {
            Issue.record("an uncaged launch was bound")
            return
        }
        #expect(broker.broker.liveCount == 0)
    }

    /// A plan that fails starts nothing, so the leases it took end with it.
    @Test func aFailedPlanRevokesTheLeasesItTook() throws {
        let fixture = try PlaceholderSecretsFixture()
        defer { fixture.tearDown() }
        let broker = SecretPlaceholderBroker(configDirectory: fixture.directory, resolver: CountingResolver().resolver)
        defer { broker.stop() }
        let unresolvable = MCPServerDefinition(
            name: "broken", command: "/bin/sh", secrets: ["T": "MISSING"], sandbox: MCPSandboxPolicy(network: false))
        guard case .failure = plan(
            [bound(), unresolvable], secrets: try PlaceholderSecretsFixture.definitions(), resolver: CountingResolver().resolver,
            placeholders: leasing(broker))
        else {
            Issue.record("a plan with an undefined secret succeeded")
            return
        }
        #expect(broker.broker.liveCount == 0)
    }

    /// A bound server whose spawn fails never ran: it is not reported bound,
    /// serve logs why, and its lease ends. The runtime spawns at the start of
    /// `run`, before it reads the client, so closing the input at once still
    /// tries the spawn.
    @Test(.timeLimit(.minutes(1)))
    func aBoundServerThatFailsToSpawnIsNotReportedBound() throws {
        let fixture = try PlaceholderSecretsFixture()
        defer { fixture.tearDown() }
        let broker = SecretPlaceholderBroker(configDirectory: fixture.directory, resolver: CountingResolver().resolver)
        defer { broker.stop() }
        let server = bound()
        let planned = try plan(
            [server], secrets: PlaceholderSecretsFixture.definitions(), resolver: CountingResolver().resolver,
            placeholders: leasing(broker)).get()
        guard let upstream = planned.first?.0, case .placeholderBound(var launch, let binding) = planned.first?.1 else {
            Issue.record("not bound: \(String(describing: planned.first?.1))")
            return
        }
        #expect(broker.broker.liveCount == 1)
        launch.executable = "/nonexistent/rv-no-such-server-\(UUID().uuidString)"
        let client = LineClient()
        let core = MCPGatewayCore(
            configuration: MCPConfiguration(servers: [server]), upstreams: [upstream],
            approvals: MCPApprovalGate(consumeGrant: { _, _, _, _, _ in .none }, request: { _, _, _, _, _ in nil }),
            pinning: .unenforced, recordForward: { _ in true })
        let reported = Mutex<[String]>([])
        let logged = Mutex<[String]>([])
        let runtime = MCPGatewayRuntime(
            core: core, connections: [.placeholderBound(launch, binding)],
            input: client.toGateway.fileHandleForReading.fileDescriptor,
            output: client.fromGateway.fileHandleForWriting.fileDescriptor,
            audit: { _ in }, log: { line in logged.withLock { $0.append(line) } },
            placeholdersBound: { name, _ in reported.withLock { $0.append(name) } })
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            runtime.run()
            done.signal()
        }
        try client.toGateway.fileHandleForWriting.close()
        let finished = done.wait(timeout: .now() + 20) == .success
        #expect(finished)
        guard finished else { return }
        #expect(reported.withLock { $0 }.isEmpty)
        #expect(logged.withLock { $0 }.contains { $0.hasPrefix("could not start MCP server \(server.name)") })
        #expect(broker.broker.liveCount == 0)
    }

    @Test func aPlaceholderNeverReplacesAValueNorAValueAPlaceholder() {
        guard case .failure(.variableCollision("A")) = MCPPlaceholderPlanning.merge(
            ["A": "1"], lease: [(name: "A", value: "ph")])
        else {
            Issue.record("a placeholder replaced a value")
            return
        }
        guard case .success(let merged) = MCPPlaceholderPlanning.merge(["A": "1"], lease: [(name: "B", value: "ph")]) else {
            Issue.record("a distinct variable was refused")
            return
        }
        #expect(merged == ["A": "1", "B": "ph"])
    }

    @Test func shutdownWaitsThenTerminatesOnceThenKillsOnce() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var shutdown = MCPPlaceholderShutdown(started: start)
        #expect(shutdown.signal(exited: false, now: start) == nil)
        #expect(shutdown.signal(exited: false, now: start + 1.9) == nil)
        #expect(shutdown.signal(exited: false, now: start + 2) == SIGTERM)
        #expect(shutdown.signal(exited: false, now: start + 2.5) == nil)
        #expect(shutdown.signal(exited: false, now: start + 3) == SIGKILL)
        #expect(shutdown.signal(exited: false, now: start + 9) == nil)
        var exited = MCPPlaceholderShutdown(started: start)
        #expect(exited.signal(exited: true, now: start + 9) == nil)
    }

    /// Each schedule counts from its own start, and `SIGKILL` from when
    /// `SIGTERM` was sent: one that starts late, or is polled late, still
    /// gets `SIGTERM` first and its full grace after it.
    @Test func eachShutdownIsTimedFromItsOwnStart() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var late = MCPPlaceholderShutdown(started: start + 3)
        #expect(late.signal(exited: false, now: start + 4.9) == nil)
        #expect(late.signal(exited: false, now: start + 9) == SIGTERM)
        #expect(late.signal(exited: false, now: start + 9.9) == nil)
        #expect(late.signal(exited: false, now: start + 10) == SIGKILL)
        #expect(late.giveUp == start + 3 + MCPPlaceholderShutdown.grace + MCPPlaceholderShutdown.terminateGrace + 2)
    }

    /// A second shutdown signal skips what is left of the grace: `SIGKILL`
    /// now, whether or not `SIGTERM` went first, and only once.
    @Test func aHurriedShutdownKillsAtOnceAndOnlyOnce() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var waiting = MCPPlaceholderShutdown(started: start)
        #expect(waiting.hurry(exited: false) == SIGKILL)
        #expect(waiting.hurry(exited: false) == nil)
        #expect(waiting.signal(exited: false, now: start + 9) == nil)
        var terminated = MCPPlaceholderShutdown(started: start)
        #expect(terminated.signal(exited: false, now: start + 2) == SIGTERM)
        #expect(terminated.hurry(exited: false) == SIGKILL)
        #expect(terminated.signal(exited: false, now: start + 9) == nil)
        var exited = MCPPlaceholderShutdown(started: start)
        #expect(exited.hurry(exited: true) == nil)
    }

    @Test func everyRefusalSaysWhy() {
        let refusals: [MCPPlaceholderRefusal] = [
            .unsupportedPlatform, .cageUnavailable, .noSandbox, .unconfinedNetwork, .realValueToo("A"),
            .unknownSecret("A"), .environmentDelivery("A"), .hostEnvironmentSource("A"), .plaintextUpstream("A"),
            .agentScoped(secret: "A", agents: ["codex"]), .approvalRules("A"), .variableCollision("A"),
            .capabilityUnavailable("x"), .leaseFailed("x"), .uncaged,
        ]
        #expect(Set(refusals.map(\.message)).count == refusals.count)
        #expect(MCPPlaceholderRefusal.unsupportedPlatform.message.contains("only macOS"))
    }
}
