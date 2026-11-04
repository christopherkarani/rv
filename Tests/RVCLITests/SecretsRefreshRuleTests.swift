import Foundation
import RVIsolation
import Testing
@testable import RVCLI

@Suite("SecretsRefreshRule")
struct SecretsRefreshRuleTests {
    @Test func refreshOnAnEnvironmentSecretIsRejectedAndChangesNothing() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        _ = try SecretsRun.set(
            name: "GH_TOKEN", value: Data("ghp-original".utf8), definition: .environment, agents: [],
            description: nil, environment: environment).get()
        let before = try Data(contentsOf: fixture.secretsFile)

        let result = SecretsRun.set(
            name: "GH_TOKEN", value: Data("ghp-rotated".utf8), definition: nil, agents: [], description: nil,
            environment: environment, refresh: .some(SecretRefreshInterval("15m")))

        guard case .failure(let failure) = result else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.message == "secrets.json is invalid: GH_TOKEN.refresh applies to gateway delivery; "
            + "a value in the environment cannot change after launch")
        #expect(fixture.keychain.items.withLock { $0["rv.secrets/GH_TOKEN"] } == Data("ghp-original".utf8))
        #expect(try Data(contentsOf: fixture.secretsFile) == before)
    }

    @Test func clearingRefreshOnAnEnvironmentSecretSucceeds() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        _ = try SecretsRun.set(
            name: "GH_TOKEN", value: Data("ghp-original".utf8), definition: .environment, agents: [],
            description: nil, environment: environment).get()
        _ = try SecretsRun.set(
            name: "GH_TOKEN", value: Data("ghp-rotated".utf8), definition: nil, agents: [], description: nil,
            environment: environment, refresh: .some(nil)).get()
        #expect(fixture.keychain.items.withLock { $0["rv.secrets/GH_TOKEN"] } == Data("ghp-rotated".utf8))
    }
}
