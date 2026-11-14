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
      {"name":"OPENAI_API_KEY","source":{"hostEnvironment":{"variable":"FAKE_OPENAI"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"OPENAI_BASE_URL",
                              "placeholderPrefix":"sk-"}}},
      {"name":"APPROVED","source":{"hostEnvironment":{"variable":"FAKE_OPENAI"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"APPROVED_BASE_URL",
                              "approve":[{"methods":["DELETE"],"path":"/v1/**"}]}}},
      {"name":"CODEX_ONLY","agents":["codex"],"source":{"hostEnvironment":{"variable":"FAKE_OPENAI"}},
       "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"CODEX_BASE_URL"}}},
      {"name":"GH_TOKEN","source":{"hostEnvironment":{"variable":"FAKE_GH"}},"delivery":{"environment":{}}}
    ]}
    """

let placeholderRealValue = "sk-live-REAL-0123456789"

/// Counts every resolution; answers with the one real value.
final class CountingResolver: Sendable {
    let count = Mutex(0)
    var resolver: SecretResolver {
        SecretResolver { _ in
            self.count.withLock { $0 += 1 }
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
func cagingHook(_ definition: MCPServerDefinition, _ launch: MCPUpstreamLaunch) -> Result<MCPUpstreamLaunch, MCPLaunchError> {
    var caged = launch
    caged.executable = MCPSandbox.sandboxExec
    caged.arguments = ["-p", "(version 1)", launch.executable] + launch.arguments
    return .success(caged)
}

private func leasing(
    platformSupported: Bool = true, capability: @escaping @Sendable () -> String? = { nil },
    lease: @escaping @Sendable (String, [String]) -> Result<SecretPlaceholderLease, SecretPlaceholderLeaseError> = { _, _ in
        .failure(.nothingStaged)
    }
) -> MCPPlaceholderLeasing {
    MCPPlaceholderLeasing(platformSupported: platformSupported, capability: capability, lease: lease)
}

private func bound(
    _ name: String = "bound", placeholders: [String] = ["OPENAI_API_KEY"], environment: [String: String] = [:],
    secrets: [String: String] = [:], sandbox: MCPSandboxPolicy? = MCPSandboxPolicy(network: false)
) -> MCPServerDefinition {
    MCPServerDefinition(
        name: name, command: "/bin/sh", args: ["-c", "true"], environment: environment, secrets: secrets,
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
        sandbox: @escaping (MCPServerDefinition, MCPUpstreamLaunch) -> Result<MCPUpstreamLaunch, MCPLaunchError> = cagingHook
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

    @Test func eachReasonRefusesOnlyThatServer() throws {
        #expect(try refusal(bound(), placeholders: leasing(platformSupported: false)) == .unsupportedPlatform)
        #expect(try refusal(bound(), requireSandbox: false) == .cageUnavailable)
        #expect(try refusal(bound(sandbox: nil)) == .noSandbox)
        #expect(try refusal(bound(sandbox: MCPSandboxPolicy(network: true))) == .unconfinedNetwork)
        #expect(try refusal(bound(secrets: ["KEY": "OPENAI_API_KEY"])) == .realValueToo("OPENAI_API_KEY"))
        #expect(try refusal(bound(placeholders: ["MISSING"])) == .unknownSecret("MISSING"))
        #expect(try refusal(bound(placeholders: ["GH_TOKEN"])) == .environmentDelivery("GH_TOKEN"))
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

    @Test func anUntrustedConfigurationGetsNoPlaceholders() throws {
        #expect(MCPPlaceholderPlanning.refusal(
            bound(), untrusted: true, platformSupported: true, cageEnforced: true,
            secrets: try PlaceholderSecretsFixture.definitions()) == .untrustedConfiguration)
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

    @Test func aBoundServerHoldsPlaceholdersAndItsOtherSecretsRealValues() throws {
        let fixture = try PlaceholderSecretsFixture()
        defer { fixture.tearDown() }
        let resolver = CountingResolver()
        let broker = SecretPlaceholderBroker(configDirectory: fixture.directory, resolver: resolver.resolver)
        defer { broker.stop() }
        let planned = try plan(
            [bound(secrets: ["REAL": "GH_TOKEN"])], secrets: PlaceholderSecretsFixture.definitions(), resolver: resolver.resolver,
            placeholders: leasing(lease: { server, names in broker.lease(names, server: server) })).get()
        guard case .placeholderBound(let launch, let binding) = planned.first?.1 else {
            Issue.record("not bound: \(String(describing: planned.first?.1))")
            return
        }
        #expect(launch.executable == MCPSandbox.sandboxExec)
        #expect(launch.gatewayPort == binding.lease.gatewayPort)
        #expect(launch.environment["OPENAI_API_KEY"]?.hasPrefix("sk-rvph_") == true)
        #expect(launch.environment["OPENAI_BASE_URL"] == "http://127.0.0.1:\(binding.lease.gatewayPort)/s/OPENAI_API_KEY")
        // `secrets` keeps its meaning: that one real value, scrubbed from replies.
        #expect(launch.environment["REAL"] == placeholderRealValue)
        #expect(planned.first?.0.secretValues.map { $0.name } == ["GH_TOKEN"])
        #expect(launch.environment.filter { $0.key != "REAL" }.values.contains { $0.contains(placeholderRealValue) } == false)
        #expect(fixture.auditText.contains("\"runtime\":\"mcp:bound\""))
        binding.lease.revoke()
        #expect(broker.broker.liveCount == 0)
    }

    @Test func aLaunchTheHookLeavesUncagedIsRefusedAndItsLeaseRevoked() throws {
        let fixture = try PlaceholderSecretsFixture()
        defer { fixture.tearDown() }
        let broker = SecretPlaceholderBroker(configDirectory: fixture.directory, resolver: CountingResolver().resolver)
        defer { broker.stop() }
        let planned = try plan(
            [bound()], secrets: PlaceholderSecretsFixture.definitions(), resolver: CountingResolver().resolver,
            placeholders: leasing(lease: { server, names in broker.lease(names, server: server) }),
            sandbox: { _, launch in .success(launch) }).get()
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
            placeholders: leasing(lease: { server, names in broker.lease(names, server: server) }))
        else {
            Issue.record("a plan with an undefined secret succeeded")
            return
        }
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
        var shutdown = MCPPlaceholderShutdown()
        #expect(shutdown.signal(exited: false, elapsed: 0) == nil)
        #expect(shutdown.signal(exited: false, elapsed: 1.9) == nil)
        #expect(shutdown.signal(exited: false, elapsed: 2) == SIGTERM)
        #expect(shutdown.signal(exited: false, elapsed: 2.5) == nil)
        #expect(shutdown.signal(exited: false, elapsed: 3) == SIGKILL)
        #expect(shutdown.signal(exited: false, elapsed: 9) == nil)
        var exited = MCPPlaceholderShutdown()
        #expect(exited.signal(exited: true, elapsed: 9) == nil)
    }

    @Test func everyRefusalSaysWhy() {
        let refusals: [MCPPlaceholderRefusal] = [
            .untrustedConfiguration, .unsupportedPlatform, .cageUnavailable, .noSandbox, .unconfinedNetwork,
            .realValueToo("A"), .unknownSecret("A"), .environmentDelivery("A"), .agentScoped(secret: "A", agents: ["codex"]),
            .approvalRules("A"), .variableCollision("A"), .capabilityUnavailable("x"), .leaseFailed("x"), .uncaged,
        ]
        #expect(Set(refusals.map(\.message)).count == refusals.count)
        #expect(MCPPlaceholderRefusal.unsupportedPlatform.message.contains("only macOS"))
    }
}
