#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation
import RVMCP
import RVPolicy
import Testing
@testable import RVCLI

@Suite("onboarding fast path")
struct OnboardingFastPathTests {
    @Test func knownDefaultsCoverWellKnownNames() {
        for name in ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "STRIPE_SECRET_KEY", "GITHUB_TOKEN", "GH_TOKEN"] {
            let known = KnownSecretDefaults.gateway(for: name)
            #expect(known != nil, "missing defaults for \(name)")
            guard let known else { continue }
            let url = URL(string: known.upstream)
            #expect(url?.scheme == "https")
            #expect(SecretsConfiguration.isVariableName(known.baseURLEnv))
            #expect(known.baseURLEnv != name)
        }
        #expect(KnownSecretDefaults.gateway(for: "ACME_KEY") == nil)
    }

    @Test func knownDefaultsSurviveSecretsValidation() throws {
        // Every curated default must decode as a real gateway delivery.
        for name in ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "STRIPE_SECRET_KEY", "GITHUB_TOKEN", "GH_TOKEN"] {
            guard let known = KnownSecretDefaults.gateway(for: name) else {
                Issue.record("missing defaults for \(name)")
                continue
            }
            let document = """
                {"version": 1, "secrets": [{"name": "\(name)",
                  "source": {"keychain": {"service": "rv.secrets", "account": "\(name)"}},
                  "delivery": {"gateway": {"upstream": "\(known.upstream)",
                    "baseURLEnv": "\(known.baseURLEnv)", "placeholderPrefix": "\(known.placeholderPrefix)"}}}]}
                """
            let decoded = SecretsConfiguration.decode(Data(document.utf8))
            _ = try decoded.get()
        }
    }

    @Test func definitionForSetPrefersExplicitFlags() {
        let explicit = SecretsRun.definitionForSet(
            name: "OPENAI_API_KEY", isNew: true, gateway: "https://proxy.example.com",
            baseURLEnv: "PROXY_URL", placeholderPrefix: "", environment: false)
        #expect(explicit.definition == .gateway(
            upstream: "https://proxy.example.com", baseURLEnv: "PROXY_URL", placeholderPrefix: ""))
        #expect(explicit.note == nil)
        let weaker = SecretsRun.definitionForSet(
            name: "OPENAI_API_KEY", isNew: true, gateway: nil, baseURLEnv: nil,
            placeholderPrefix: "", environment: true)
        #expect(weaker.definition == .environment)
        #expect(weaker.note == nil)
    }

    @Test func definitionForSetInfersOnlyForNewKnownSecrets() {
        let inferred = SecretsRun.definitionForSet(
            name: "OPENAI_API_KEY", isNew: true, gateway: nil, baseURLEnv: nil,
            placeholderPrefix: "", environment: false)
        #expect(inferred.definition == .gateway(
            upstream: "https://api.openai.com/v1", baseURLEnv: "OPENAI_BASE_URL",
            placeholderPrefix: "sk-"))
        #expect(inferred.note?.contains("known defaults") == true)
        let prefixed = SecretsRun.definitionForSet(
            name: "GITHUB_TOKEN", isNew: true, gateway: nil, baseURLEnv: nil,
            placeholderPrefix: "ghp-", environment: false)
        #expect(prefixed.definition == .gateway(
            upstream: "https://api.github.com", baseURLEnv: "GITHUB_API_URL",
            placeholderPrefix: "ghp-"))
        let existing = SecretsRun.definitionForSet(
            name: "OPENAI_API_KEY", isNew: false, gateway: nil, baseURLEnv: nil,
            placeholderPrefix: "", environment: false)
        #expect(existing.definition == nil)
        #expect(existing.note == nil)
        let unknown = SecretsRun.definitionForSet(
            name: "ACME_KEY", isNew: true, gateway: nil, baseURLEnv: nil,
            placeholderPrefix: "", environment: false)
        #expect(unknown.definition == nil)
        #expect(unknown.note == nil)
    }

    @Test func inferredDefinitionStoresAGatewaySecret() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        let resolved = SecretsRun.definitionForSet(
            name: "OPENAI_API_KEY", isNew: true, gateway: nil, baseURLEnv: nil,
            placeholderPrefix: "", environment: false)
        let text = try SecretsRun.set(
            name: "OPENAI_API_KEY", value: Data("sk-test".utf8), definition: resolved.definition,
            agents: [], description: nil, environment: environment).get()
        #expect(text.contains("gateway"))
        let reloaded = try SecretsRun.configuration(environment).get()
        guard case .gateway(let binding) = reloaded.secret(named: "OPENAI_API_KEY")?.delivery else {
            Issue.record("inferred secret is not gateway-delivered")
            return
        }
        #expect(binding.upstream.absoluteString == "https://api.openai.com/v1")
        #expect(binding.baseURLEnv == "OPENAI_BASE_URL")
    }

    @Test func fixLineNamesTheNextCommandPerStatus() {
        func row(status: String, name: String = "github") -> MCPRun.Row {
            MCPRun.Row(
                host: "cursor", scope: "user", configPath: "/tmp/mcp.json", name: name, status: status,
                command: "npx", environmentNames: [], headerNames: [], plaintextCredentials: [],
                governedServer: nil)
        }
        #expect(MCPRun.fixLine(status: .bypass, row: row(status: "bypass"))?
            .contains("rv mcp setup --host cursor") == true)
        #expect(MCPRun.fixLine(status: .unreviewed, row: row(status: "unreviewed"))?
            .contains("rv mcp onboard --host cursor") == true)
        #expect(MCPRun.fixLine(status: .dangling, row: row(status: "dangling"))?.contains("--undo") == true)
        #expect(MCPRun.fixLine(status: .blocked, row: row(status: "blocked"))?.contains("\"blocked\"") == true)
        #expect(MCPRun.fixLine(status: .governed, row: row(status: "governed")) == nil)
        #expect(MCPRun.fixLine(status: .direct, row: row(status: "direct")) == nil)
        #expect(MCPRun.fixLine(status: .disabled, row: row(status: "disabled")) == nil)
    }

    @Test func fixLineEscapesAHostileServerName() throws {
        let row = MCPRun.Row(
            host: "cursor", scope: "user", configPath: "/tmp/mcp.json",
            name: "\u{1B}[2J\u{1B}[Howned", status: "unreviewed", command: "npx",
            environmentNames: [], headerNames: [], plaintextCredentials: [], governedServer: nil)
        let fix = try #require(MCPRun.fixLine(status: .unreviewed, row: row))
        #expect(fix.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(fix.contains("rv mcp onboard --host cursor"))
    }

    @Test func fixLineKeepsShellExpansionsInert() throws {
        let row = MCPRun.Row(
            host: "cursor", scope: "user", configPath: "/tmp/mcp.json",
            name: "$(touch pwned)`id`", status: "unreviewed", command: "npx",
            environmentNames: [], headerNames: [], plaintextCredentials: [], governedServer: nil)
        let fix = try #require(MCPRun.fixLine(status: .unreviewed, row: row))
        // Inside the double quotes the expansion must be backslash-escaped.
        #expect(fix.contains("\\$(touch pwned)\\`id\\`"))
    }

    @Test func checkTextShowsFixLinesForFailingRows() {
        let report = MCPRun.Report(
            servers: 0, direct: 0, blocked: 0, integrity: "none",
            integrityProblem: "mcp.json was edited outside rv",
            rows: [
                MCPRun.Row(
                    host: "cursor", scope: "user", configPath: "/tmp/mcp.json", name: "gh",
                    status: "unreviewed", command: "npx", environmentNames: [], headerNames: [],
                    plaintextCredentials: [], governedServer: nil),
            ],
            problems: [])
        let text = MCPRun.checkText(report, home: URL(fileURLWithPath: "/tmp/home"))
        #expect(text.contains("Fix: `rv mcp onboard --host cursor"))
        #expect(text.contains("Fix: review with `rv mcp list`, then `rv mcp trust`"))
    }

    @Test func onboardImportsAndRoutesInOneStep() async throws {
        let fixture = MCPCommandTests.Fixture()
        try fixture.write(
            ".cursor/mcp.json",
            #"{"mcpServers": {"github": {"command": "npx", "args": ["-y", "srv"], "env": {"GITHUB_TOKEN": "ghp_testtoken"}}}}"#)
        let rv = fixture.home.appendingPathComponent("bin/rv")
        try FileManager.default.createDirectory(at: rv.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: rv.path, contents: Data())
        let onboarded = try await MCPRun.onboard(
            host: .cursor, names: [], project: nil, dryRun: false,
            rvPath: rv.path, environment: fixture.environment()).get()
        #expect(onboarded.contains("import github"))
        #expect(onboarded.contains("routed through rv: github"))
        let configuration = try MCPRun.configuration(fixture.environment()).get()
        #expect(configuration.toolMode == .search)
        let report = MCPRun.report(
            fixture.environment(), project: nil, configuration: configuration, rvExecutable: rv.path)
        #if os(macOS)
        // Onboarded local servers carry no sandbox yet: check fails until
        // one is added and the file is re-trusted.
        #expect(report.passes == false)
        #expect(report.problems.contains { $0.message.contains("github has no sandbox") })
        #else
        // No cage off macOS yet: bare servers serve, so check reports no sandbox problem.
        #expect(report.problems.contains { $0.message.contains("sandbox") } == false)
        #endif
    }

    @Test func onboardDryRunWritesNothing() async throws {
        let fixture = MCPCommandTests.Fixture()
        try fixture.write(
            ".cursor/mcp.json", #"{"mcpServers": {"github": {"command": "npx"}}}"#)
        let dry = try await MCPRun.onboard(
            host: .cursor, names: [], project: nil, dryRun: true,
            rvPath: "/bin/rv", environment: fixture.environment()).get()
        #expect(dry.contains("dry run"))
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("mcp.json").path) == false)
        #expect(fixture.text(".cursor/mcp.json").contains("rv mcp serve") == false)
    }

    @Test func importPreservesAnExistingToolMode() async throws {
        let fixture = MCPCommandTests.Fixture()
        try fixture.write(
            ".cursor/mcp.json", #"{"mcpServers": {"one": {"command": "a"}, "two": {"command": "b"}}}"#)
        _ = try await MCPRun.importServers(
            host: .cursor, names: ["one"], project: nil, dryRun: false,
            environment: fixture.environment(), toolModeForFreshConfig: .search, show: { _ in }).get()
        #expect(try MCPRun.configuration(fixture.environment()).get().toolMode == .search)
        // Second import into the now-populated config must not flip an
        // operator-chosen mode back.
        _ = try await MCPRun.importServers(
            host: .cursor, names: ["two"], project: nil, dryRun: false,
            environment: fixture.environment(), toolModeForFreshConfig: .direct, show: { _ in }).get()
        #expect(try MCPRun.configuration(fixture.environment()).get().toolMode == .search)
    }
}
