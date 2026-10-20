import Foundation
import RVPolicy
import Testing
@testable import RVIsolation

@Suite("Dotenv source configuration")
struct DotenvConfigurationTests {
    private func decode(_ json: String) -> Result<SecretsConfiguration, SecretsConfigurationError> {
        SecretsConfiguration.decode(Data(json.utf8))
    }

    private func document(_ source: String) -> String {
        "{\"version\":1,\"secrets\":[{\"name\":\"STRIPE_SECRET_KEY\",\"source\":\(source),\"delivery\":{\"environment\":{}}}]}"
    }

    @Test func decodesDotenvAndRoundTrips() throws {
        let configuration = try decode(document(
            "{\"dotenv\":{\"path\":\"/Users/ada/proj/.env\",\"variable\":\"STRIPE_SECRET_KEY\"}}")).get()
        let secret = try #require(configuration.secret(named: "STRIPE_SECRET_KEY"))
        #expect(secret.source == .dotenv(path: "/Users/ada/proj/.env", variable: "STRIPE_SECRET_KEY"))
        #expect(secret.source.kind == "dotenv")
        #expect(secret.source.locator == "dotenv /Users/ada/proj/.env#STRIPE_SECRET_KEY")
        let reparsed = try SecretsConfiguration.decode(configuration.encoded()).get()
        #expect(reparsed == configuration)
    }

    @Test func decodeDoesNotTouchTheFilesystem() throws {
        // The bound file does not exist; decode must still succeed.
        let configuration = try decode(document(
            "{\"dotenv\":{\"path\":\"/nonexistent-\(UUID().uuidString)/.env\",\"variable\":\"X_KEY\"}}")).get()
        #expect(configuration.secrets.count == 1)
    }

    @Test func rejectsRelativeDotDotAndEmptyComponents() {
        for path in ["relative/.env", "/a/../b/.env", "/a//b/.env", "/", "/a/.env/"] {
            guard case .failure(.invalid) = decode(document(
                "{\"dotenv\":{\"path\":\"\(path)\",\"variable\":\"X_KEY\"}}"))
            else {
                Issue.record("path \(path) must be rejected")
                continue
            }
        }
    }

    @Test func rejectsBadVariableAndUnknownKeys() {
        guard case .failure(.invalid) = decode(document(
            "{\"dotenv\":{\"path\":\"/a/.env\",\"variable\":\"9bad\"}}"))
        else {
            Issue.record("bad variable must be rejected")
            return
        }
        guard case .failure(.invalid) = decode(document(
            "{\"dotenv\":{\"path\":\"/a/.env\",\"variable\":\"OK\",\"extra\":1}}"))
        else {
            Issue.record("unknown key must be rejected")
            return
        }
        guard case .failure(.invalid) = decode(document(
            "{\"dotEnv\":{\"path\":\"/a/.env\",\"variable\":\"OK\"}}"))
        else {
            Issue.record("unknown kind must stay rejected")
            return
        }
    }

    @Test func dotenvLeaseStagesAndPolicyDenies() throws {
        let json = """
            {"version":1,"secrets":[
              {"name":"STRIPE_SECRET_KEY","source":{"dotenv":{"path":"/proj/.env","variable":"STRIPE_SECRET_KEY"}},
               "delivery":{"environment":{}}},
              {"name":"GH_TOKEN","source":{"hostEnvironment":{"variable":"FAKE_GH"}},"delivery":{"environment":{}}}
            ]}
            """
        let fixture = try SecretsFixture(json)
        defer { fixture.tearDown() }
        let resolver = SecretResolver.live(
            environment: ["FAKE_GH": "[REDACTED]"], home: "/nonexistent",
            dotenvReader: { _ in
                .success(DotenvFileSnapshot(
                    canonicalPath: "/proj/.env", data: Data("STRIPE_SECRET_KEY=sk-test-123\n".utf8), identity: "1"))
            })
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: resolver,
            transport: RecordingUpstream().transport, workspace: "W1")
        let lease = try broker.lease(names: ["STRIPE_SECRET_KEY", "GH_TOKEN"], agent: nil).get()
        #expect(lease.environment.contains { $0.name == "STRIPE_SECRET_KEY" && $0.value == "sk-test-123" })
        #expect(lease.environment.contains { $0.name == "GH_TOKEN" && $0.value == "[REDACTED]" })
        broker.stop()

        var policy = ManagedPolicy()
        policy.secrets.allowedSources = ["keychain"]
        let bundle = ManagedPolicyBundle(policy: policy, sha256: "", isSigned: false, directory: "")
        let denied = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: resolver,
            transport: RecordingUpstream().transport, workspace: "W1",
            managed: { .active(bundle) })
        guard case .failure(.organizationPolicy(let reason)) = denied.lease(names: ["STRIPE_SECRET_KEY"], agent: nil) else {
            Issue.record("dotenv-deny policy must fail the lease")
            return
        }
        #expect(reason == "STRIPE_SECRET_KEY uses a dotenv source, which is not allowed")
        denied.stop()
    }
}
