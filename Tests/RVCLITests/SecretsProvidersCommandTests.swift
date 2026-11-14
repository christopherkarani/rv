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
            "github", name: "GITHUB_TOKEN", isNew: true, baseURLEnv: nil, placeholderPrefix: "", surfaces: nil,
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
            "github", name: "GITHUB_TOKEN", isNew: true, baseURLEnv: nil, placeholderPrefix: "", surfaces: nil,
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
    }

    @Test func providerCanOnlyNarrow() throws {
        let narrowed = try SecretsRun.definitionForProvider(
            "github", name: "GITHUB_TOKEN", isNew: true, baseURLEnv: nil, placeholderPrefix: "", surfaces: nil,
            allow: try SecretsRun.allowances(["GET /repos/**"]).get()).get()
        #expect(narrowed.definition == .gateway(
            upstream: "https://api.github.com", baseURLEnv: "GITHUB_API_URL", placeholderPrefix: "",
            surfaces: [.header], allow: [.rule(try #require(GatewayAccessRule(methods: ["GET"], path: "/repos/**")))]))
        #expect(SecretsRun.definitionForProvider(
            "github", name: "GITHUB_TOKEN", isNew: true, baseURLEnv: nil, placeholderPrefix: "", surfaces: nil,
            allow: try SecretsRun.allowances(["POST /repos/**"]).get()).map { $0.note }
            == .failure("--allow POST /repos/** is wider than provider github's rules; --provider can only be narrowed"))
        #expect(SecretsRun.definitionForProvider(
            "pypi", name: "TWINE_PASSWORD", isNew: true, baseURLEnv: nil, placeholderPrefix: "", surfaces: [.query],
            allow: []).map { $0.note }
            == .failure("--surface query is wider than provider pypi allows"))
        #expect(SecretsRun.definitionForProvider(
            "github", name: "GITHUB_TOKEN", isNew: false, baseURLEnv: nil, placeholderPrefix: "", surfaces: nil,
            allow: []).map { $0.note }
            == .failure("GITHUB_TOKEN is already defined; edit secrets.json to change its delivery"))
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
