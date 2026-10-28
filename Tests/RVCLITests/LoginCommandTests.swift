import Foundation
import RVIsolation
import Testing
@testable import RVCLI

@Suite("LoginCommand")
struct LoginCommandTests {
    @Test func catalogKnowsVercelAndGitHub() {
        #expect(LoginProvider.named("vercel")?.secretName == "VERCEL_TOKEN")
        #expect(LoginProvider.named("GitHub")?.secretName == "GITHUB_TOKEN")
        #expect(LoginProvider.named("GITHUB_TOKEN")?.id == "github")
        #expect(LoginProvider.named("gitlab") == nil)
        #expect(KnownSecretDefaults.gateway(for: "VERCEL_TOKEN")?.upstream == "https://api.vercel.com")
    }

    @Test func vercelAuthFileParsing() {
        #expect(LoginRun.vercelAuthToken(Data(#"{"token":"  abc-123  "}"#.utf8)) == Data("abc-123".utf8))
        #expect(LoginRun.vercelAuthToken(Data(#"{"token":""}"#.utf8)) == nil)
        #expect(LoginRun.vercelAuthToken(Data("not json".utf8)) == nil)
        #expect(LoginRun.vercelAuthToken(Data(#"{"other":"x"}"#.utf8)) == nil)
    }

    @Test func connectStoresGatewaySecretAndListReportsIt() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        let text = try LoginRun.connect(
            provider: "vercel", value: Data("vercel-token-123".utf8),
            origin: "imported from Vercel CLI login", environment: environment).get()
        #expect(text.hasPrefix("Connected Vercel (imported from Vercel CLI login)."))
        #expect(text.contains("gateway → api.vercel.com via $VERCEL_BASE_URL"))
        #expect(fixture.keychain.items.withLock { $0["rv.secrets/VERCEL_TOKEN"] } == Data("vercel-token-123".utf8))

        let configuration = try SecretsRun.configuration(environment).get()
        let secret = try #require(configuration.secret(named: "VERCEL_TOKEN"))
        #expect(secret.description == "Vercel login (imported from Vercel CLI login)")
        guard case .gateway(let binding) = secret.delivery else {
            Issue.record("expected gateway delivery")
            return
        }
        #expect(binding.upstream.absoluteString == "https://api.vercel.com")
        #expect(binding.baseURLEnv == "VERCEL_BASE_URL")

        let report = LoginRun.list(configuration, profiles: [], environment: environment)
        #expect(report.logins.map(\.provider) == ["vercel", "github"])
        #expect(report.logins[0].connected)
        #expect(report.logins[0].checkOK == true)
        #expect(report.logins[0].fingerprint != nil)
        #expect(report.logins[1].connected == false)
        let listText = LoginRun.listText(report)
        #expect(listText.contains("Vercel"))
        #expect(listText.contains("connected"))
        #expect(listText.contains("GitHub"))
        #expect(listText.contains("not connected  run: rv login connect github"))
        #expect(listText.contains("vercel-token-123") == false)
        let json = SecretsRun.robotJSON(report)
        #expect(json.contains("vercel-token-123") == false)
        #expect(json.contains("\"provider\" : \"vercel\"") || json.contains("\"provider\": \"vercel\""))
    }

    @Test func reconnectUpdatesValueAndLogoutRemovesIt() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        _ = try LoginRun.connect(
            provider: "github", value: Data("gh-old-token".utf8), origin: "pasted token",
            environment: environment).get()
        _ = try LoginRun.connect(
            provider: "github", value: Data("gh-new-token".utf8), origin: "pasted token",
            environment: environment).get()
        #expect(fixture.keychain.items.withLock { $0["rv.secrets/GITHUB_TOKEN"] } == Data("gh-new-token".utf8))

        let text = try LoginRun.logout(provider: "github", environment: environment).get()
        #expect(text.hasPrefix("Disconnected GitHub."))
        #expect(fixture.keychain.items.withLock { $0.isEmpty })
        let report = LoginRun.list(
            try SecretsRun.configuration(environment).get(), profiles: [], environment: environment)
        #expect(report.logins.allSatisfy { $0.connected == false })
    }

    @Test func unknownProviderIsRefusedEverywhere() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        guard case .failure(let connectFailure) = LoginRun.connect(
            provider: "gitlab", value: Data("x-token-123".utf8), origin: "pasted token", environment: environment)
        else {
            Issue.record("unknown provider connected")
            return
        }
        #expect(connectFailure.message.contains("supported: vercel, github"))
        guard case .failure = LoginRun.logout(provider: "gitlab", environment: environment) else {
            Issue.record("unknown provider logged out")
            return
        }
        #expect(fixture.keychain.items.withLock { $0.isEmpty })
    }

    @Test func acquirePrefersEnvironmentThenVercelAuthFile() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let provider = try #require(LoginProvider.named("vercel"))
        let fromEnv = LoginAcquire.value(
            provider: provider, home: fixture.directory, variables: ["VERCEL_TOKEN": "env-token"])
        #expect(fromEnv?.value == Data("env-token".utf8))
        #expect(fromEnv?.origin == "imported from $VERCEL_TOKEN")

        let authFile = LoginRun.vercelAuthFiles(home: fixture.directory)[0]
        try FileManager.default.createDirectory(
            at: authFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"token":"file-token"}"#.utf8).write(to: authFile)
        let fromFile = LoginAcquire.value(provider: provider, home: fixture.directory, variables: [:])
        #expect(fromFile?.value == Data("file-token".utf8))
        #expect(fromFile?.origin == "imported from Vercel CLI login")

        let github = try #require(LoginProvider.named("github"))
        let ghEnv = LoginAcquire.value(
            provider: github, home: fixture.directory, variables: ["GH_TOKEN": "gh-env-token", "PATH": "/nonexistent"])
        #expect(ghEnv?.value == Data("gh-env-token".utf8))
    }
}
