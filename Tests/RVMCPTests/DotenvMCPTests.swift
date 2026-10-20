import Foundation
import RVIsolation
import RVPolicy
import Testing
@testable import RVMCP

@Suite("MCP dotenv secrets")
struct DotenvMCPTests {
    private func plan(policyJSON: String?) throws -> MCPLaunchError? {
        var configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "svc", command: "s", secrets: ["TOKEN": "API_TOKEN"]),
        ])
        if let policyJSON {
            configuration.managed = try ManagedPolicy.decode(Data(policyJSON.utf8)).get()
        }
        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(
                name: "API_TOKEN", source: .dotenv(path: "/proj/.env", variable: "API_TOKEN"),
                delivery: .environment)
        ])
        let resolver = SecretResolver.live(
            environment: [:], home: "/nonexistent",
            dotenvReader: { _ in
                .success(DotenvFileSnapshot(
                    canonicalPath: "/proj/.env", data: Data("API_TOKEN=mcp-secret\n".utf8), identity: "1"))
            })
        switch MCPLaunchPlanner.plan(
            servers: ["svc"], configuration: configuration, secrets: secrets, resolver: resolver, baseEnvironment: [:])
        {
        case .failure(let error): return error
        case .success(let planned):
            let values = planned.flatMap { $0.0.secretValues }
            #expect(values.contains { $0.name == "API_TOKEN" && $0.value == "mcp-secret" })
            return nil
        }
    }

    @Test func dotenvSecretResolvesForMCP() throws {
        #expect(try plan(policyJSON: nil) == nil)
    }

    @Test func dotenvDenyPolicyFailsWithSecretUnavailable() throws {
        let error = try plan(policyJSON: #"{"version":1,"secrets":{"allowedSources":["keychain"]}}"#)
        #expect(error == .secretUnavailable(
            server: "svc", secret: "API_TOKEN",
            reason: "organization policy does not allow dotenv secrets"))
    }

    @Test func environmentDeliveryDenyFailsForMCP() throws {
        let error = try plan(policyJSON: #"{"version":1,"secrets":{"allowEnvironmentDelivery":false}}"#)
        guard case .secretUnavailable(_, _, let reason)? = error else {
            Issue.record("expected secretUnavailable, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("delivered as an environment variable"))
    }
}
