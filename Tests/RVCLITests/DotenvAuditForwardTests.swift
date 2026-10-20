import Foundation
import RVIsolation
import RVPolicy
import Testing
@testable import RVCLI

@Suite("Audit forward policy gate")
struct DotenvAuditForwardTests {
    private var secrets: SecretsConfiguration {
        SecretsConfiguration(secrets: [
            SecretDefinition(
                name: "SIEM", source: .dotenv(path: "/proj/.env", variable: "SIEM"), delivery: .environment)
        ])
    }

    private var resolver: SecretResolver {
        SecretResolver { _ in .success(SecretValue("tok123")!) }
    }

    @Test func dotenvDenyBlocksHeaderResolution() throws {
        var policy = ManagedPolicy()
        policy.secrets.allowedSources = ["keychain"]
        let state = ManagedPolicyState.active(
            ManagedPolicyBundle(policy: policy, sha256: "", isSigned: false, directory: ""))
        guard case .failure(let failure) = AuditForwardRun.resolveHeaders(
            ["Authorization": "Bearer ${secret:SIEM}"], secrets: { .success(secrets) },
            resolver: resolver, managed: state)
        else {
            Issue.record("denying policy must block off-host header resolution")
            return
        }
        #expect(failure.message.contains("dotenv source"))
    }

    @Test func invalidPolicyFailsClosed() {
        guard case .failure(let failure) = AuditForwardRun.resolveHeaders(
            ["Authorization": "Bearer ${secret:SIEM}"], secrets: { .success(secrets) },
            resolver: resolver, managed: .invalid("bad policy"))
        else {
            Issue.record("invalid policy must fail closed")
            return
        }
        #expect(failure.message.contains("invalid"))
    }

    @Test func noPolicyStillResolves() throws {
        let resolved = try AuditForwardRun.resolveHeaders(
            ["Authorization": "Bearer ${secret:SIEM}"], secrets: { .success(secrets) },
            resolver: resolver, managed: .none).get()
        #expect(resolved == ["Authorization": "Bearer tok123"])
    }
}
