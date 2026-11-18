import ArgumentParser
import Foundation
import RVIsolation
import Testing
@testable import RVCLI

@Suite("SecretsProviders")
struct SecretsProvidersCommandTests {
    @Test func listNamesEverySeededProfile() throws {
        let report = try SecretsRun.providers(nil).get()
        let text = SecretsRun.providersListText(report)
        for id in ["anthropic", "openai", "openrouter", "github", "vercel", "stripe", "npm", "pypi"] {
            #expect(text.contains("\n\(id) ") || text.hasPrefix("\(id) "), "\(id)")
        }
        #expect(text.contains("variables: GITHUB_TOKEN,GH_TOKEN"))
    }

    @Test func showGivesEndpointsRulesAndVariables() throws {
        let report = try SecretsRun.providers("github").get()
        let row = try #require(report.providers.first)
        #expect(report.providers.count == 1)
        #expect(row.endpoints == [
            .init(name: "api", upstream: "https://api.github.com", surfaces: ["header"], allow: ["github-read"]),
            .init(name: "git", upstream: "https://github.com", surfaces: ["header"], allow: ["github-clone"]),
        ])
        let text = SecretsRun.providerShowText(row)
        #expect(text.contains("endpoint git: https://github.com  surfaces: header  allow: github-clone"))
        #expect(text.contains("GH_TOKEN -> api via $GH_API_URL"))
        #expect(text.contains("use: rv secrets set GITHUB_TOKEN --provider github"))
        #expect(SecretsRun.providers("gitlab")
            == .failure("no provider profile gitlab; `rv secrets providers` lists them"))
    }

    @Test func invalidCatalogRefusesToListOrExpand() {
        let broken = ProviderCatalog.decode(Data(#"{"version":1,"providers":[]}"#.utf8))
        guard case .failure(let failure) = SecretsRun.providers(nil, catalog: broken) else {
            Issue.record("an invalid catalog must not list")
            return
        }
        #expect(failure.message.hasPrefix("the provider catalog is invalid:"))
        guard case .failure = SecretsRun.definitionForProvider(
            "github", name: "GITHUB_TOKEN", baseURLEnv: nil, placeholderPrefix: "", surfaces: nil,
            allow: [], catalog: broken)
        else {
            Issue.record("an invalid catalog must not expand")
            return
        }
    }

    @Test func providersCommandPrintsJSONOnRequest() throws {
        let out = CLIOutputCapture()
        try withCLIProcess(home: try isolatedHome(), output: out) {
            try SecretsProviders.parse(["npm", "--json"]).run()
        }
        let json = try #require(try JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        let providers = try #require(json["providers"] as? [[String: Any]])
        #expect(providers.count == 1)
        #expect(providers.first?["id"] as? String == "npm")
        let endpoints = try #require(providers.first?["endpoints"] as? [[String: Any]])
        #expect(endpoints.first?["allow"] as? [String] == ["PUT /*"])
    }

    @Test func providerExpandsIntoAScopedGatewaySecret() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        let expanded = try SecretsRun.definitionForProvider(
            "github", name: "GITHUB_TOKEN", baseURLEnv: nil, placeholderPrefix: "", surfaces: nil,
            allow: []).get()
        #expect(expanded.definition == .gateway(
            upstream: "https://api.github.com", baseURLEnv: "GITHUB_API_URL", placeholderPrefix: "",
            surfaces: [.header], allow: [.preset(.githubRead)]))
        #expect(expanded.note
            == "Using provider github:api for GITHUB_TOKEN: gateway https://api.github.com via $GITHUB_API_URL, allow: github-read.\n")
        let text = try SecretsRun.set(
            name: "GITHUB_TOKEN", value: Data("ghp-1234".utf8), definition: expanded.definition, agents: [],
            description: nil, environment: environment).get()
        #expect(text.contains("note:") == false)
        guard case .gateway(let binding) = try SecretsRun.configuration(environment).get()
            .secret(named: "GITHUB_TOKEN")?.delivery
        else {
            Issue.record("expected gateway delivery")
            return
        }
        #expect(binding.upstream.absoluteString == "https://api.github.com")
        #expect(binding.allow == [.preset(.githubRead)])

        // The same --provider command run again stores a value; a different expansion is refused.
        let defined = try Data(contentsOf: fixture.secretsFile)
        _ = try SecretsRun.set(
            name: "GITHUB_TOKEN", value: Data("ghp-5678".utf8), definition: expanded.definition, agents: [],
            description: nil, environment: environment).get()
        #expect(fixture.keychain.items.withLock { $0["rv.secrets/GITHUB_TOKEN"] } == Data("ghp-5678".utf8))
        let narrowed = try SecretsRun.definitionForProvider(
            "github", name: "GITHUB_TOKEN", baseURLEnv: nil, placeholderPrefix: "", surfaces: nil,
            allow: try SecretsRun.allowances(["GET /repos/**"]).get()).get()
        #expect(SecretsRun.set(
            name: "GITHUB_TOKEN", value: Data("ghp-9999".utf8), definition: narrowed.definition, agents: [],
            description: nil, environment: environment).map { _ in "" }
            == .failure(CommandFailure(
                "GITHUB_TOKEN is already defined; `rv secrets set GITHUB_TOKEN` with no delivery flags replaces its "
                    + "value; edit secrets.json to change its delivery")))
        #expect(fixture.keychain.items.withLock { $0["rv.secrets/GITHUB_TOKEN"] } == Data("ghp-5678".utf8))
        #expect(try Data(contentsOf: fixture.secretsFile) == defined)
    }

    @Test func providerCanOnlyNarrow() throws {
        let narrowed = try SecretsRun.definitionForProvider(
            "github", name: "GITHUB_TOKEN", baseURLEnv: nil, placeholderPrefix: "", surfaces: nil,
            allow: try SecretsRun.allowances(["GET /repos/**"]).get()).get()
        #expect(narrowed.definition == .gateway(
            upstream: "https://api.github.com", baseURLEnv: "GITHUB_API_URL", placeholderPrefix: "",
            surfaces: [.header], allow: [.rule(try #require(GatewayAccessRule(methods: ["GET"], path: "/repos/**")))]))
        #expect(SecretsRun.definitionForProvider(
            "github", name: "GITHUB_TOKEN", baseURLEnv: nil, placeholderPrefix: "", surfaces: nil,
            allow: try SecretsRun.allowances(["POST /repos/**"]).get()).map { $0.note }
            == .failure("--allow POST /repos/** is wider than provider github's rules; --provider can only be narrowed"))
        #expect(SecretsRun.definitionForProvider(
            "pypi", name: "TWINE_PASSWORD", baseURLEnv: nil, placeholderPrefix: "", surfaces: [.query],
            allow: []).map { $0.note }
            == .failure("--surface query is wider than provider pypi allows"))
    }

    @Test func bareSetOfAProviderOnlyNameStillNeedsADelivery() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        for name in ["NPM_TOKEN", "TWINE_PASSWORD", "UV_PUBLISH_TOKEN", "OPENROUTER_API_KEY"] {
            let resolved = SecretsRun.definitionForSet(
                name: name, isNew: true, gateway: nil, baseURLEnv: nil, placeholderPrefix: "", environment: false)
            #expect(resolved.definition == nil, "\(name)")
            #expect(resolved.note == nil, "\(name)")
            #expect(SecretsRun.set(
                name: name, value: Data("token-1234".utf8), definition: resolved.definition, agents: [],
                description: nil, environment: fixture.environment()).map { _ in "" }
                == .failure("\(name) is new: pass --gateway URL --base-url-env VAR, or --environment"), "\(name)")
            #expect(SecretsRun.brokenCatalogFailure(name: name, isNew: true, definition: nil) == nil, "\(name)")
        }
        #expect(fixture.keychain.items.withLock { $0.isEmpty })
    }

    @Test func bareSetOfAWellKnownNameNamesABrokenCatalog() {
        let broken = ProviderCatalog.decode(Data("{}".utf8))
        let failure = SecretsRun.brokenCatalogFailure(name: "GITHUB_TOKEN", isNew: true, definition: nil, catalog: broken)
        #expect(failure?.message.hasPrefix("the provider catalog is invalid:") == true)
        #expect(failure?.message.hasSuffix(
            ", so GITHUB_TOKEN has no default; pass --gateway URL --base-url-env VAR, or --environment") == true)
        #expect(SecretsRun.brokenCatalogFailure(name: "GITHUB_TOKEN", isNew: false, definition: nil, catalog: broken) == nil)
        #expect(SecretsRun.brokenCatalogFailure(
            name: "GITHUB_TOKEN", isNew: true, definition: .environment, catalog: broken) == nil)
        #expect(SecretsRun.brokenCatalogFailure(name: "GITHUB_TOKEN", isNew: true, definition: nil) == nil)
    }

    @Test func providerFlagConflictsWithOtherDeliveries() {
        #expect(throws: (any Error).self) {
            _ = try SecretsSet.parse(["X", "--provider", "github", "--gateway", "https://x.example", "--base-url-env", "X_URL"])
        }
        #expect(throws: (any Error).self) { _ = try SecretsSet.parse(["X", "--provider", "github", "--environment"]) }
        #expect(throws: (any Error).self) { _ = try SecretsSet.parse(["X", "--base-url-env", "X_URL"]) }
        #expect(throws: Never.self) {
            _ = try SecretsSet.parse(["GITHUB_GIT", "--provider", "github:git", "--base-url-env", "GITHUB_GIT_URL"])
        }
    }
}
