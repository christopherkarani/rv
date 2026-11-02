#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIsolation
import RVPolicy
import Synchronization
import Testing
@testable import RVCLI

final class FakeKeychain: Sendable {
    let items = Mutex<[String: Data]>([:])

    var writer: SecretKeychainWriter {
        SecretKeychainWriter(
            store: { service, account, value in
                self.items.withLock { $0["\(service)/\(account)"] = value }
                return true
            },
            delete: { service, account in
                _ = self.items.withLock { $0.removeValue(forKey: "\(service)/\(account)") }
                return true
            })
    }

    /// Resolves rv.secrets items from this store, host variables from `host`.
    func resolver(host: [String: String] = [:]) -> SecretResolver {
        SecretResolver { source in
            let missing = SecretResolutionError.notFound(source.locator)
            switch source {
            case .keychain(let service, let account):
                guard let data = self.items.withLock({ $0["\(service)/\(account)"] }) else { return .failure(missing) }
                return SecretResolver.live(environment: ["V": String(decoding: data, as: UTF8.self)], home: "/")
                    .resolve(.hostEnvironment(variable: "V"))
            case .hostEnvironment(let variable):
                guard host[variable] != nil else { return .failure(missing) }
                return SecretResolver.live(environment: host, home: "/").resolve(source)
            default:
                return .failure(.providerUnavailable("fake"))
            }
        }
    }
}

struct SecretsCLIFixture {
    let directory: URL
    let keychain = FakeKeychain()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-secrets-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func environment(host: [String: String] = [:]) -> SecretsEnvironment {
        SecretsEnvironment(configDirectory: directory, resolver: keychain.resolver(host: host), keychain: keychain.writer)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func writeProfiles(_ json: String) throws {
        let file = directory.appendingPathComponent("runtime-resources.json")
        try Data(json.utf8).write(to: file)
        chmod(file.path, 0o600)
    }

    var secretsFile: URL { directory.appendingPathComponent("secrets.json") }
}

@Suite("SecretsCommand")
struct SecretsCommandTests {
    @Test func listWithNothingConfiguredExplainsHowToStart() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let configuration = try SecretsRun.configuration(fixture.environment()).get()
        let text = SecretsRun.listText(SecretsRun.list(configuration, profiles: []))
        #expect(text.hasPrefix("No secrets configured."))
        #expect(text.contains("rv secrets set NAME --gateway"))
    }

    @Test func setDefinesANewGatewaySecretAndStoresTheValueInTheKeychain() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        let text = try SecretsRun.set(
            name: "OPENAI_API_KEY", value: Data("sk-real-value-123".utf8),
            definition: .gateway(upstream: "https://api.openai.com/v1/", baseURLEnv: "OPENAI_BASE_URL",
                                 placeholderPrefix: "sk-"),
            agents: ["codex"], description: "model calls", environment: environment
        ).get()
        #expect(text.hasPrefix("Stored OPENAI_API_KEY in the Keychain (rv.secrets). Delivery: gateway → api.openai.com via $OPENAI_BASE_URL."))
        #expect(fixture.keychain.items.withLock { $0["rv.secrets/OPENAI_API_KEY"] } == Data("sk-real-value-123".utf8))

        var info = stat()
        #expect(stat(fixture.secretsFile.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        let saved = try String(contentsOf: fixture.secretsFile, encoding: .utf8)
        #expect(saved.contains("sk-real-value-123") == false)
        let configuration = try SecretsRun.configuration(environment).get()
        let secret = try #require(configuration.secret(named: "OPENAI_API_KEY"))
        #expect(secret.source == .keychain(service: "rv.secrets", account: "OPENAI_API_KEY"))
        #expect(secret.agents == ["codex"])
        guard case .gateway(let binding) = secret.delivery else {
            Issue.record("expected gateway delivery")
            return
        }
        #expect(binding.upstream.absoluteString == "https://api.openai.com/v1")
        #expect(binding.placeholderPrefix == "sk-")

        let update = SecretsRun.set(
            name: "OPENAI_API_KEY", value: Data("sk-rotated".utf8), definition: nil, agents: [], description: nil,
            environment: environment)
        #expect((try? update.get()) != nil)
        #expect(fixture.keychain.items.withLock { $0["rv.secrets/OPENAI_API_KEY"] } == Data("sk-rotated".utf8))
    }

    @Test func setStoresGatewaySurfacesFromFlagsOrDefaults() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        #expect(SecretsRun.surfaces(["query", "header"]) == .success([.header, .query]))
        #expect(SecretsRun.surfaces([]) == .success(nil))
        #expect(SecretsRun.surfaces(["body"])
            == .failure("--surface must be header, query, or path, not body"))
        let explicit = SecretsRun.definitionForSet(
            name: "ACME_KEY", isNew: true, gateway: "https://api.acme.example", baseURLEnv: "ACME_URL",
            placeholderPrefix: "", environment: false, surfaces: [.query])
        #expect(explicit.definition == .gateway(
            upstream: "https://api.acme.example", baseURLEnv: "ACME_URL", placeholderPrefix: "", surfaces: [.query]))
        let known = SecretsRun.definitionForSet(
            name: "GITHUB_TOKEN", isNew: true, gateway: nil, baseURLEnv: nil, placeholderPrefix: "",
            environment: false, surfaces: [.header, .path])
        _ = try SecretsRun.set(
            name: "ACME_KEY", value: Data("acme-1234".utf8), definition: explicit.definition, agents: [],
            description: nil, environment: environment).get()
        _ = try SecretsRun.set(
            name: "GITHUB_TOKEN", value: Data("ghp-1234".utf8), definition: known.definition, agents: [],
            description: nil, environment: environment).get()
        _ = try SecretsRun.set(
            name: "OPENAI_API_KEY", value: Data("sk-1234".utf8),
            definition: SecretsRun.definitionForSet(
                name: "OPENAI_API_KEY", isNew: true, gateway: nil, baseURLEnv: nil, placeholderPrefix: "",
                environment: false).definition,
            agents: [], description: nil, environment: environment).get()
        let configuration = try SecretsRun.configuration(environment).get()
        func surfaces(_ name: String) -> Set<GatewaySurface>? {
            guard case .gateway(let binding) = configuration.secret(named: name)?.delivery else { return nil }
            return binding.surfaces
        }
        #expect(surfaces("ACME_KEY") == [.query])
        #expect(surfaces("GITHUB_TOKEN") == [.header, .path])
        #expect(surfaces("OPENAI_API_KEY") == [.header])
    }

    @Test func setStoresAllowRulesAndNotesWhenThereAreNone() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        let allow = try SecretsRun.allowances(["github-read", "POST /graphql"]).get()
        #expect(allow == [.preset(.githubRead), .rule(try #require(GatewayAccessRule(methods: ["POST"], path: "/graphql")))])
        guard case .failure(let failure) = SecretsRun.allowances(["GET /a/../b"]) else {
            Issue.record("a traversal glob must be refused")
            return
        }
        #expect(failure.message.contains("--allow must be a preset (read-only, github-clone, github-read)"))
        let scoped = SecretsRun.definitionForSet(
            name: "GITHUB_TOKEN", isNew: true, gateway: nil, baseURLEnv: nil, placeholderPrefix: "",
            environment: false, allow: allow)
        let text = try SecretsRun.set(
            name: "GITHUB_TOKEN", value: Data("ghp-1234".utf8), definition: scoped.definition, agents: [],
            description: nil, environment: environment).get()
        #expect(text.contains("note:") == false)
        guard case .gateway(let binding) = try SecretsRun.configuration(environment).get()
            .secret(named: "GITHUB_TOKEN")?.delivery
        else {
            Issue.record("expected gateway delivery")
            return
        }
        #expect(binding.allow == allow)

        let open = try SecretsRun.set(
            name: "ACME_KEY", value: Data("acme-1234".utf8),
            definition: .gateway(upstream: "https://api.acme.example", baseURLEnv: "ACME_URL", placeholderPrefix: ""),
            agents: [], description: nil, environment: environment).get()
        #expect(open.hasSuffix(
            "note: ACME_KEY may be used with any method and path on api.acme.example; narrow it with --allow, e.g. --allow read-only.\n"))
        let rotated = try SecretsRun.set(
            name: "ACME_KEY", value: Data("acme-5678".utf8), definition: nil, agents: [], description: nil,
            environment: environment).get()
        #expect(rotated.contains("note:") == false)
    }

    @Test func setRefusesAmbiguousOrForeignSecrets() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        #expect(SecretsRun.set(
            name: "NEW", value: Data("v-12345678".utf8), definition: nil, agents: [], description: nil,
            environment: environment) == .failure("NEW is new: pass --gateway URL --base-url-env VAR, or --environment"))
        #expect(SecretsRun.set(
            name: "NEW", value: Data(), definition: .environment, agents: [], description: nil,
            environment: environment) == .failure("the value must be 1 byte to 16 KiB with no NUL bytes"))
        guard case .failure(let failure) = SecretsRun.set(
            name: "BAD", value: Data("v".utf8),
            definition: .gateway(upstream: "http://plain.example", baseURLEnv: "BAD_URL", placeholderPrefix: ""),
            agents: [], description: nil, environment: environment)
        else {
            Issue.record("http upstream must be refused")
            return
        }
        #expect(failure.message.contains("must be an https URL"))
        #expect(fixture.keychain.items.withLock { $0.isEmpty })

        try Data(#"{"version":1,"secrets":[{"name":"GH","source":{"hostEnvironment":{"variable":"GH"}},"delivery":{"environment":{}}}]}"#.utf8)
            .write(to: fixture.secretsFile)
        chmod(fixture.secretsFile.path, 0o600)
        #expect(SecretsRun.set(
            name: "GH", value: Data("v".utf8), definition: nil, agents: [], description: nil,
            environment: environment)
            == .failure("GH reads from host $GH; rv secrets set only stores values it reads from rv.secrets"))
    }

    @Test func setStoresExpiryAndRefreshAndUpdatesThemWhenTheValueRotates() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        let now = try #require(SecretExpiry.parse("2026-11-01T12:00:00Z"))
        let gateway = SecretsRun.Definition.gateway(
            upstream: "https://api.acme.example", baseURLEnv: "ACME_URL", placeholderPrefix: "")
        let december = try #require(SecretExpiry.parse("2026-12-31"))
        _ = try SecretsRun.set(
            name: "ACME_KEY", value: Data("acme-12345678".utf8), definition: gateway, agents: [], description: nil,
            environment: environment, expires: .some(december), refresh: .some(SecretRefreshInterval("15m")), now: now
        ).get()
        var secret = try #require(try SecretsRun.configuration(environment).get().secret(named: "ACME_KEY"))
        #expect(secret.expires == december)
        #expect(secret.refresh?.text == "15m")

        // Rotating the value may move the expiry; flags left out keep what is on file.
        let january = try #require(SecretExpiry.parse("2027-01-31T09:00:00Z"))
        _ = try SecretsRun.set(
            name: "ACME_KEY", value: Data("acme-87654321".utf8), definition: nil, agents: [], description: nil,
            environment: environment, expires: .some(january), now: now
        ).get()
        secret = try #require(try SecretsRun.configuration(environment).get().secret(named: "ACME_KEY"))
        #expect(secret.expires == january)
        #expect(secret.refresh?.text == "15m")
        #expect(fixture.keychain.items.withLock { $0["rv.secrets/ACME_KEY"] } == Data("acme-87654321".utf8))

        _ = try SecretsRun.set(
            name: "ACME_KEY", value: Data("acme-87654321".utf8), definition: nil, agents: [], description: nil,
            environment: environment, expires: .some(nil), refresh: .some(nil), now: now
        ).get()
        secret = try #require(try SecretsRun.configuration(environment).get().secret(named: "ACME_KEY"))
        #expect(secret.expires == nil)
        #expect(secret.refresh == nil)

        let past = try #require(SecretExpiry.parse("2026-10-31"))
        #expect(SecretsRun.set(
            name: "ACME_KEY", value: Data("acme-0000".utf8), definition: nil, agents: [], description: nil,
            environment: environment, expires: .some(past), now: now)
            == .failure("--expires 2026-10-31 is already past"))
        #expect(fixture.keychain.items.withLock { $0["rv.secrets/ACME_KEY"] } == Data("acme-87654321".utf8))
        guard case .failure(let failure) = SecretsRun.set(
            name: "GH_TOKEN", value: Data("ghp-12345678".utf8), definition: .environment, agents: [],
            description: nil, environment: environment, refresh: .some(SecretRefreshInterval("1h")), now: now)
        else {
            Issue.record("refresh must be refused for environment delivery")
            return
        }
        #expect(failure.message.contains("refresh applies to gateway delivery"))
        #expect(fixture.keychain.items.withLock { $0["rv.secrets/GH_TOKEN"] } == nil)
    }

    @Test func expiresAndRefreshFlagsParseStrictly() throws {
        #expect(SecretsRun.expiry(nil) == .success(nil))
        #expect(SecretsRun.expiry("none") == .success(.some(nil)))
        #expect(SecretsRun.expiry("2026-12-31") == .success(.some(SecretExpiry.parse("2026-12-31"))))
        #expect(SecretsRun.expiry("12/31/2026") == .failure(
            "--expires must be an ISO-8601 date (2026-12-31), a date-time with a zone (2026-12-31T18:00:00Z), or none"))
        #expect(SecretsRun.refresh(nil) == .success(nil))
        #expect(SecretsRun.refresh("none") == .success(.some(nil)))
        #expect(SecretsRun.refresh("15m") == .success(.some(SecretRefreshInterval("15m"))))
        #expect(SecretsRun.refresh("10s") == .failure(
            "--refresh must be a whole number of s, m, h, or d from 1m to 30d, such as 15m, or none"))

        let parsed = try SecretsSet.parse(["ACME_KEY", "--expires", "2026-12-31", "--refresh", "15m"])
        #expect(parsed.expires == "2026-12-31")
        #expect(parsed.refresh == "15m")
        #expect(throws: (any Error).self) { try SecretsSet.parse(["ACME_KEY", "--expires", "soon"]) }
        #expect(throws: (any Error).self) { try SecretsSet.parse(["ACME_KEY", "--refresh", "5s"]) }
        #expect(throws: (any Error).self) { try SecretsSet.parse(["ACME_KEY", "--environment", "--refresh", "15m"]) }
    }

    @Test func listAndDescribeShowExpiryAndWarnWithinAWeek() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        let now = try #require(SecretExpiry.parse("2026-11-01T12:00:00Z"))
        for (name, expires) in [("SOON", "2026-11-04"), ("LATER", "2026-12-31"), ("TODAY", "2026-11-02")] {
            let gateway = SecretsRun.Definition.gateway(
                upstream: "https://api.acme.example", baseURLEnv: "\(name)_URL", placeholderPrefix: "")
            _ = try SecretsRun.set(
                name: name, value: Data("value-12345678".utf8), definition: gateway, agents: [], description: nil,
                environment: environment, expires: .some(SecretExpiry.parse(expires)),
                refresh: name == "SOON" ? .some(SecretRefreshInterval("15m")) : nil, now: now
            ).get()
        }
        _ = try SecretsRun.set(
            name: "GONE", value: Data("value-12345678".utf8), definition: .environment, agents: [], description: nil,
            environment: environment, now: now
        ).get()
        var configuration = try SecretsRun.configuration(environment).get()
        configuration.secrets[3].expires = SecretExpiry.parse("2026-10-30")
        _ = configuration.write(configDirectory: fixture.directory)

        let report = SecretsRun.list(configuration, profiles: [], now: now)
        #expect(report.secrets.map(\.expires) == ["2026-11-04", "2026-12-31", "2026-11-02", "2026-10-30"])
        #expect(report.secrets.map(\.refresh) == ["15m", nil, nil, nil])
        #expect(report.warnings == [
            "SOON expires in 2 days (2026-11-04); rotate it with rv secrets set SOON --expires DATE",
            "TODAY expires within a day (2026-11-02); rotate it with rv secrets set TODAY --expires DATE",
            "GONE expired at 2026-10-30; launches that use it fail until it is rotated",
        ])
        let text = SecretsRun.listText(report)
        #expect(text.contains("expires: 2026-11-04  refresh: 15m"))
        #expect(text.contains("warning: SOON expires in 2 days"))

        let described = SecretsRun.describe(configuration, now: now)
        #expect(described.secrets.map(\.expires) == ["2026-11-04", "2026-12-31", "2026-11-02", "2026-10-30"])
        #expect(described.warnings == report.warnings)
        let describedText = SecretsRun.describeText(described)
        #expect(describedText.contains("SOON  keychain  gateway\n  surfaces: header\n  allow: any method and path\n"
            + "  expires: 2026-11-04\n  refresh: 15m\n"))
        #expect(describedText.contains("warning: GONE expired at 2026-10-30"))
    }

    @Test func listShowsSourcesDeliveryProfilesAndDanglingReferences() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        _ = SecretsRun.set(
            name: "OPENAI_API_KEY", value: Data("sk-x-12345678".utf8),
            definition: .gateway(upstream: "https://api.openai.com", baseURLEnv: "OPENAI_BASE_URL", placeholderPrefix: ""),
            agents: [], description: nil, environment: environment)
        _ = SecretsRun.set(
            name: "GH_TOKEN", value: Data("ghp-12345678".utf8), definition: .environment, agents: [],
            description: nil, environment: environment)
        try fixture.writeProfiles("""
            {"version":1,"profiles":[{"id":"default","projects":["/tmp"],"executableLinks":[],"readFiles":[],"readTrees":[],"writeTrees":[],"credentials":[],"environment":[],"secrets":["OPENAI_API_KEY","MISSING"]}]}
            """)
        let report = SecretsRun.list(
            try SecretsRun.configuration(environment).get(), profiles: SecretsRun.profiles(environment))
        #expect(report.secrets.map(\.name) == ["OPENAI_API_KEY", "GH_TOKEN"])
        #expect(report.secrets[0].profiles == ["default"])
        #expect(report.secrets[0].weaker == false)
        #expect(report.secrets[1].weaker)
        #expect(report.warnings == ["profile default lists MISSING, which secrets.json does not define"])
        let text = SecretsRun.listText(report)
        #expect(text.contains("OPENAI_API_KEY  keychain rv.secrets/OPENAI_API_KEY  gateway → api.openai.com via $OPENAI_BASE_URL  profiles: default"))
        #expect(text.contains("GH_TOKEN        keychain rv.secrets/GH_TOKEN  environment (real value in the cage)  profiles: -  [weaker]"))
        #expect(text.contains("warning: profile default lists MISSING"))
        #expect(text.contains("sk-x-12345678") == false)
    }

    @Test func listAndDescribeShowGatewaySurfacesAndAllowRules() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        _ = SecretsRun.set(
            name: "GITHUB_TOKEN", value: Data("ghp-12345678".utf8),
            definition: .gateway(
                upstream: "https://api.github.com", baseURLEnv: "GITHUB_API_URL", placeholderPrefix: "",
                surfaces: [.header, .query], allow: try SecretsRun.allowances(["github-read", "POST,PUT /graphql"]).get()),
            agents: [], description: nil, environment: environment)
        _ = SecretsRun.set(
            name: "ACME_KEY", value: Data("acme-12345678".utf8),
            definition: .gateway(upstream: "https://api.acme.example", baseURLEnv: "ACME_URL", placeholderPrefix: ""),
            agents: [], description: nil, environment: environment)
        _ = SecretsRun.set(
            name: "GH_TOKEN", value: Data("ghp-87654321".utf8), definition: .environment, agents: [],
            description: nil, environment: environment)
        let configuration = try SecretsRun.configuration(environment).get()
        let report = SecretsRun.list(configuration, profiles: [])
        #expect(report.secrets.map(\.surfaces) == [["header", "query"], ["header"], nil])
        #expect(report.secrets.map(\.allow) == [["github-read", "POST,PUT /graphql"], [], nil])
        let text = SecretsRun.listText(report)
        #expect(text.contains("profiles: -  surfaces: header,query  allow: github-read; POST,PUT /graphql\n"))
        #expect(text.contains("profiles: -  surfaces: header  allow: any method and path\n"))
        #expect(text.contains("GH_TOKEN") && text.contains("[weaker]\n"))

        let described = SecretsRun.describe(configuration)
        #expect(described.secrets.map(\.surfaces) == [["header", "query"], ["header"], nil])
        #expect(described.secrets.map(\.allow) == [["github-read", "POST,PUT /graphql"], [], nil])
        let describedText = SecretsRun.describeText(described)
        #expect(describedText.contains("GITHUB_TOKEN  keychain  gateway\n  surfaces: header,query\n  allow: github-read; POST,PUT /graphql\n"))
        #expect(describedText.contains("ACME_KEY  keychain  gateway\n  surfaces: header\n  allow: any method and path\n"))
        #expect(describedText.contains("ghp-") == false)
    }

    @Test func checkShowsFingerprintsNeverValues() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        try Data("""
            {"version":1,"secrets":[
              {"name":"GOOD","source":{"hostEnvironment":{"variable":"GOOD_SRC"}},"delivery":{"environment":{}}},
              {"name":"GONE","source":{"hostEnvironment":{"variable":"GONE_SRC"}},"delivery":{"environment":{}}}
            ]}
            """.utf8).write(to: fixture.secretsFile)
        chmod(fixture.secretsFile.path, 0o600)
        let environment = fixture.environment(host: ["GOOD_SRC": "value-good-123"])
        let configuration = try SecretsRun.configuration(environment).get()
        let rows = try SecretsRun.check(configuration, names: [], environment: environment).get()
        #expect(rows.map(\.ok) == [true, false])
        #expect(rows[0].fingerprint?.count == 16)
        #expect(rows[1].error == "not found: host $GONE_SRC")
        let text = SecretsRun.checkText(rows)
        #expect(text.contains("ok    GOOD  fingerprint \(rows[0].fingerprint ?? "")  host $GOOD_SRC"))
        #expect(text.contains("FAIL  GONE  not found: host $GONE_SRC  host $GONE_SRC"))
        #expect(text.contains("value-good-123") == false)
        let again = try SecretsRun.check(configuration, names: ["GOOD"], environment: environment).get()
        #expect(again.first?.fingerprint == rows[0].fingerprint)
        #expect(SecretsRun.check(configuration, names: ["NOPE"], environment: environment)
            == .failure("NOPE is not defined in secrets.json"))
    }

    @Test func removeDeletesTheDefinitionAndTheStoredValue() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        _ = SecretsRun.set(
            name: "GH_TOKEN", value: Data("ghp-12345678".utf8), definition: .environment, agents: [],
            description: nil, environment: environment)
        try fixture.writeProfiles(#"{"version":1,"profiles":[{"id":"ci","projects":["/tmp"],"executableLinks":[],"readFiles":[],"readTrees":[],"writeTrees":[],"credentials":[],"environment":[],"secrets":["GH_TOKEN"]}]}"#)
        let text = try SecretsRun.remove(name: "GH_TOKEN", environment: environment).get()
        #expect(text == """
            Deleted GH_TOKEN from the Keychain (rv.secrets).
            Removed GH_TOKEN from secrets.json.
            warning: profiles ci still list GH_TOKEN; their launches will fail until you remove it.

            """)
        #expect(fixture.keychain.items.withLock { $0.isEmpty })
        #expect(try SecretsRun.configuration(environment).get().secrets.isEmpty)
    }

    @Test func scanReportsFileAndLineButNeverTheValue() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        _ = SecretsRun.set(
            name: "GH_TOKEN", value: Data("ghp-leaky-12345678".utf8), definition: .environment, agents: [],
            description: nil, environment: environment)
        let tree = fixture.directory.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tree.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try Data("line one\nexport GH=ghp-leaky-12345678\n".utf8).write(to: tree.appendingPathComponent(".env"))
        try Data("ghp-leaky-12345678".utf8).write(to: tree.appendingPathComponent(".git/config"))
        try Data("clean".utf8).write(to: tree.appendingPathComponent("README"))
        let report = try SecretsRun.scan(
            root: tree, configuration: try SecretsRun.configuration(environment).get(), environment: environment).get()
        #expect(report.findings == [SecretLeakFinding(path: ".env", line: 2, secret: "GH_TOKEN")])
        let text = SecretsRun.scanText(report)
        #expect(text == ".env:2  GH_TOKEN\n")
    }

    @Test func describeAndVarlockImportNeverCarryAValue() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let schema = fixture.directory.appendingPathComponent("app.env.schema")
        let literal = "sk-live-abcdefghijklmnopqrstuvwxyz"
        try Data("""
            # @defaultSensitive=false
            # ---
            # OpenAI
            # @sensitive @type=string(startsWith=sk-)
            OPENAI_API_KEY=op(op://Eng/OpenAI/credential)
            # @sensitive
            LITERAL=\(literal)
            PORT=3000
            """.utf8).write(to: schema)
        let imported = try SecretsRun.importVarlock(path: schema, dryRun: true, environment: fixture.environment()).get()
        #expect(imported.contains(
            "import OPENAI_API_KEY: provider onePassword, delivery environment (real value in the cage), "
                + "type string(startsWith=sk-)"))
        #expect(imported.contains("dry run: nothing written"))
        #expect(imported.contains(literal) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.secretsFile.path) == false)
        _ = try SecretsRun.importVarlock(path: schema, dryRun: false, environment: fixture.environment()).get()
        let stored = try String(contentsOf: fixture.secretsFile, encoding: .utf8)
        #expect(stored.contains(literal) == false)
        #expect(stored.contains("op://Eng/OpenAI/credential"))
        let again = try SecretsRun.importVarlock(path: schema, dryRun: false, environment: fixture.environment()).get()
        #expect(again.contains("already defines it"))
        let report = SecretsRun.describe(try SecretsRun.configuration(fixture.environment()).get())
        #expect(report.secrets == [
            SecretsRun.DescribeRow(
                name: "OPENAI_API_KEY", description: "OpenAI", type: "string(startsWith=sk-)",
                delivery: "environment", source: "onePassword"),
        ])
        let text = SecretsRun.describeText(report)
        #expect(text.contains("op://") == false)
        #expect(text.contains("OPENAI_API_KEY  onePassword  environment"))
        let json = SecretsRun.json(report)
        #expect(json.contains("\"source\" : \"onePassword\"") || json.contains("\"source\": \"onePassword\""))
    }

    @Test func varlockProxyImportsAsGatewayDelivery() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let schema = fixture.directory.appendingPathComponent("app.env.schema")
        try Data("""
            # @proxy(domain=api.example.com) @type=string(startsWith=ak_)
            ACME_KEY=op(op://Eng/Acme/key)
            """.utf8).write(to: schema)
        let text = try SecretsRun.importVarlock(path: schema, dryRun: false, environment: fixture.environment()).get()
        #expect(text.contains("import ACME_KEY: provider onePassword, delivery gateway → api.example.com via $ACME_KEY_BASE_URL"))
        #expect(text.contains("wrote secrets.json (1 secret)\n"))
        let stored = try #require(try SecretsRun.configuration(fixture.environment()).get().secret(named: "ACME_KEY"))
        #expect(stored.delivery == .gateway(SecretGatewayBinding(
            upstream: URL(string: "https://api.example.com")!, baseURLEnv: "ACME_KEY_BASE_URL", placeholderPrefix: "ak_")))
    }

    @Test func varlockImportWiresEveryNameIntoAnExistingProfile() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let schema = fixture.directory.appendingPathComponent("app.env.schema")
        try Data("""
            NEW_KEY=op(op://Eng/New/credential)
            OLD_KEY=op(op://Eng/Old/credential)
            """.utf8).write(to: schema)
        try SecretsConfiguration(secrets: [
            SecretDefinition(name: "OLD_KEY", source: .onePassword(reference: "op://Eng/Old/credential"), delivery: .environment),
        ]).write(configDirectory: fixture.directory).get()
        let missing = SecretsRun.importVarlock(
            path: schema, dryRun: false, profile: "main", environment: fixture.environment())
        #expect(missing.failureMessage?.contains("profile main does not exist") == true)
        #expect(try SecretsRun.configuration(fixture.environment()).get().secret(named: "NEW_KEY") == nil)
        try fixture.writeProfiles(#"{"version":1,"profiles":[{"id":"main","projects":["/tmp"],"executableLinks":[],"readFiles":[],"readTrees":[],"writeTrees":[],"credentials":[],"environment":[],"secrets":[]}]}"#)
        let text = try SecretsRun.importVarlock(
            path: schema, dryRun: false, profile: "main", environment: fixture.environment()).get()
        #expect(text.contains("wired NEW_KEY, OLD_KEY into profile main"))
        #expect(SecretsRun.profiles(fixture.environment()).first?.secrets == ["NEW_KEY", "OLD_KEY"])
    }

    @Test func hookInstallKeepsTheExistingHookAndScansTheIndex() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let work = fixture.directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(work, ["init", "-q"])
        let foreign = work.appendingPathComponent(".git/hooks/pre-commit")
        let original = "#!/bin/sh\necho foreign\n"
        try Data(original.utf8).write(to: foreign)
        chmod(foreign.path, 0o755)
        let installed = try SecretGitHook.install(workTree: work, rvPath: "/usr/bin/true").get()
        #expect(installed.contains("installed"))
        let hook = try String(contentsOf: foreign, encoding: .utf8)
        #expect(hook.hasPrefix("#!/bin/sh\n# >>> rv secrets >>>\n"))
        #expect(hook.contains("'/usr/bin/true' secrets hook run"))
        #expect(hook.hasSuffix("# <<< rv secrets <<<\necho foreign\n"))
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent(".git/hooks/pre-commit.rv-saved").path) == false)
        _ = try SecretGitHook.install(workTree: work, rvPath: "/opt/rv/bin/rv").get()
        let reinstalled = try String(contentsOf: foreign, encoding: .utf8)
        #expect(reinstalled.components(separatedBy: SecretGitHook.beginMarker).count == 2)
        #expect(reinstalled.contains("'/opt/rv/bin/rv' secrets hook run"))
        #expect(reinstalled.contains("/usr/bin/true") == false)

        let value = "hook-secret-value-xyz"
        var configuration = SecretsConfiguration(secrets: [
            SecretDefinition(name: "GH_TOKEN", source: .hostEnvironment(variable: "GH_TOKEN"), delivery: .environment),
        ])
        _ = try configuration.write(configDirectory: fixture.directory).get()
        let environment = fixture.environment(host: ["GH_TOKEN": value])
        try Data("clean\n".utf8).write(to: work.appendingPathComponent("clean.txt"))
        try Data("\(value)\n".utf8).write(to: work.appendingPathComponent("leak.txt"))
        try git(work, ["add", "clean.txt"])
        let clean = try SecretsRun.hookRun(workTree: work, environment: environment).get()
        #expect(clean.failed == false)
        #expect(clean.text.contains(value) == false)
        try git(work, ["add", "leak.txt"])
        // The index is scanned, not the worktree: cleaning the file on disk does not hide the staged leak.
        try Data("clean now\n".utf8).write(to: work.appendingPathComponent("leak.txt"))
        let leaked = try SecretsRun.hookRun(workTree: work, environment: environment).get()
        #expect(leaked.failed)
        #expect(leaked.text.contains("leak.txt:1:GH_TOKEN"))
        #expect(leaked.text.contains("rv.secretsScan"))
        #expect(leaked.text.contains(value) == false)

        let removed = try SecretGitHook.uninstall(workTree: work).get()
        #expect(removed.contains("removed rv's block"))
        #expect(try String(contentsOf: foreign, encoding: .utf8) == original)
    }

    @Test func hookFindsPatternsPastTheFirstMebibyteAndReportsOversizedFiles() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let work = fixture.directory.appendingPathComponent("repo-large")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(work, ["init", "-q"])
        let token = "AK" + "IA" + "Q3MZ7XK2LP5VN4RT"
        let padding = String(repeating: "filler line\n", count: 120_000)
        try Data((padding + "key: \(token)\n").utf8).write(to: work.appendingPathComponent("big.txt"))
        let huge = work.appendingPathComponent("huge.bin")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(SecretLeakScanner.maximumFileBytes + 1))
        try handle.close()
        try git(work, ["add", "big.txt", "huge.bin"])
        let result = try SecretsRun.hookRun(workTree: work, environment: fixture.environment()).get()
        #expect(result.failed)
        #expect(result.text.contains("big.txt:120001:aws-access-key-id"))
        #expect(result.text.contains("not scanned (over 8 MiB): huge.bin"))
        #expect(result.text.contains(token) == false)

        try git(work, ["rm", "-q", "--cached", "big.txt"])
        let oversizedOnly = try SecretsRun.hookRun(workTree: work, environment: fixture.environment()).get()
        #expect(oversizedOnly.failed == false)
        #expect(oversizedOnly.text.contains("not scanned (over 8 MiB): huge.bin"))
    }

    @Test func hookKillSwitchSkipsTheScanWithANotice() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let work = fixture.directory.appendingPathComponent("repo-kill")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(work, ["init", "-q"])
        let finding = fixture.directory.appendingPathComponent("rv-finds")
        try Data("#!/bin/sh\necho finding\nexit 1\n".utf8).write(to: finding)
        chmod(finding.path, 0o755)
        _ = try SecretGitHook.install(workTree: work, rvPath: finding.path).get()
        func runHook() throws -> (status: Int32, stderr: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [work.appendingPathComponent(".git/hooks/pre-commit").path]
            process.currentDirectoryURL = work
            let err = Pipe()
            process.standardError = err
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (process.terminationStatus, stderr)
        }
        #expect(try runHook().status == 1)
        try git(work, ["config", "rv.secretsScan", "false"])
        let skipped = try runHook()
        #expect(skipped.status == 0)
        #expect(skipped.stderr.contains("scan skipped"))
    }

    @Test func scanAndHookRunRefuseWhatOrganizationPolicyForbidsWithoutResolvingIt() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let work = fixture.directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(work, ["init", "-q"])
        let configuration = SecretsConfiguration(secrets: [
            SecretDefinition(name: "HOST_TOKEN", source: .hostEnvironment(variable: "HOST_TOKEN"), delivery: .environment)
        ])
        _ = try configuration.write(configDirectory: fixture.directory).get()
        let resolved = Mutex(0)
        var environment = fixture.environment()
        environment.resolver = SecretResolver { _ in
            resolved.withLock { $0 += 1 }
            return .success(SecretValue("policy-value-12345678")!)
        }
        environment.managed = .active(ManagedPolicyBundle(
            policy: try ManagedPolicy.decode(Data(#"{"version":1,"secrets":{"allowedSources":["keychain"]}}"#.utf8)).get(),
            sha256: "abc", isSigned: true, directory: "/managed"))
        let reason = "organization policy: HOST_TOKEN uses a hostEnvironment source, which is not allowed"

        let report = try SecretsRun.scan(root: work, configuration: configuration, environment: environment).get()
        #expect(report.skipped == ["HOST_TOKEN: \(reason)"])
        let hook = try SecretsRun.hookRun(workTree: work, environment: environment).get()
        #expect(hook.text.contains("could not check HOST_TOKEN: \(reason)"))
        #expect(resolved.withLock { $0 } == 0, "a disallowed source must not be resolved")

        environment.managed = .invalid("policy.json.sig does not verify")
        let invalid = "organization policy is invalid: policy.json.sig does not verify"
        guard case .failure(let scanFailure) = SecretsRun.scan(root: work, configuration: configuration, environment: environment),
            case .failure(let hookFailure) = SecretsRun.hookRun(workTree: work, environment: environment)
        else {
            Issue.record("an invalid organization policy must fail scan and hook run")
            return
        }
        #expect(scanFailure.message == invalid)
        #expect(hookFailure.message == invalid)
        #expect(resolved.withLock { $0 } == 0)
    }

    @Test func scanAndHookRunStillResolveEnvironmentDeliveredSecretsWhenOnlyTheDeliveryRuleIsSet() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let work = fixture.directory.appendingPathComponent("repo-delivery-rule")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(work, ["init", "-q"])
        let configuration = SecretsConfiguration(secrets: [
            SecretDefinition(name: "HOST_TOKEN", source: .hostEnvironment(variable: "HOST_TOKEN"), delivery: .environment)
        ])
        _ = try configuration.write(configDirectory: fixture.directory).get()
        let value = "policy-value-12345678"
        try Data("token=\(value)\n".utf8).write(to: work.appendingPathComponent("leak.txt"))
        try git(work, ["add", "leak.txt"])
        var environment = fixture.environment()
        environment.resolver = SecretResolver { _ in .success(SecretValue(value)!) }
        environment.managed = .active(ManagedPolicyBundle(
            policy: try ManagedPolicy.decode(Data(#"{"version":1,"secrets":{"allowEnvironmentDelivery":false}}"#.utf8)).get(),
            sha256: "abc", isSigned: true, directory: "/managed"))

        let report = try SecretsRun.scan(root: work, configuration: configuration, environment: environment).get()
        #expect(report.skipped.isEmpty, "scan resolves host-side; the delivery rule does not apply")
        #expect(report.findings.map(\.secret) == ["HOST_TOKEN"])
        let hook = try SecretsRun.hookRun(workTree: work, environment: environment).get()
        #expect(hook.text.contains("could not check") == false)
        #expect(hook.failed, "a staged real value must still block the commit")
    }

    private func git(_ work: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", work.path] + args
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func hookInstallHonorsHooksPathAndLinkedWorktrees() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let work = fixture.directory.appendingPathComponent("repo-hooks-path")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(work, ["init", "-q"])
        let custom = fixture.directory.appendingPathComponent("custom-hooks")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try git(work, ["config", "core.hooksPath", custom.path])
        _ = try SecretGitHook.install(workTree: work, rvPath: "/usr/bin/true").get()
        #expect(FileManager.default.fileExists(atPath: custom.appendingPathComponent("pre-commit").path))
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent(".git/hooks/pre-commit").path) == false)

        let main = fixture.directory.appendingPathComponent("repo-worktree")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try git(main, ["init", "-q"])
        try git(main, ["-c", "user.email=a@b.c", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"])
        let linked = fixture.directory.appendingPathComponent("linked")
        try git(main, ["worktree", "add", "-q", linked.path])
        _ = try SecretGitHook.install(workTree: linked, rvPath: "/usr/bin/true").get()
        #expect(FileManager.default.fileExists(atPath: main.appendingPathComponent(".git/hooks/pre-commit").path))
    }

    @Test func hookInstallRefusesHooksItCannotEditSafely() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let work = fixture.directory.appendingPathComponent("repo-foreign")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(work, ["init", "-q"])
        let hook = work.appendingPathComponent(".git/hooks/pre-commit")
        let python = "#!/usr/bin/env python3\nprint('foreign')\n"
        try Data(python.utf8).write(to: hook)
        #expect(throws: SecretGitHookError.self) { try SecretGitHook.install(workTree: work, rvPath: "/usr/bin/true").get() }
        #expect(try String(contentsOf: hook, encoding: .utf8) == python)
        #expect(throws: SecretGitHookError.self) { try SecretGitHook.uninstall(workTree: work).get() }

        try FileManager.default.removeItem(at: hook)
        let target = fixture.directory.appendingPathComponent("shared-hook")
        try Data("#!/bin/sh\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: hook, withDestinationURL: target)
        #expect(throws: SecretGitHookError.self) { try SecretGitHook.install(workTree: work, rvPath: "/usr/bin/true").get() }
        #expect(try String(contentsOf: target, encoding: .utf8) == "#!/bin/sh\n")
    }

    @Test func hookInstallReplacesTheOldWholeFileHook() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let work = fixture.directory.appendingPathComponent("repo-legacy")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(work, ["init", "-q"])
        let hook = work.appendingPathComponent(".git/hooks/pre-commit")
        let saved = work.appendingPathComponent(".git/hooks/pre-commit.rv-saved")
        try Data("#!/bin/sh\n# rv-secrets-hook\n'/usr/bin/true' secrets hook run\n".utf8).write(to: hook)
        try Data("#!/bin/bash\necho previous\n".utf8).write(to: saved)
        _ = try SecretGitHook.install(workTree: work, rvPath: "/usr/bin/true").get()
        let text = try String(contentsOf: hook, encoding: .utf8)
        #expect(text.hasPrefix("#!/bin/bash\n# >>> rv secrets >>>"))
        #expect(text.hasSuffix("echo previous\n"))
        #expect(text.contains("# rv-secrets-hook") == false)
        #expect(FileManager.default.fileExists(atPath: saved.path) == false)
        _ = try SecretGitHook.uninstall(workTree: work).get()
        #expect(try String(contentsOf: hook, encoding: .utf8) == "#!/bin/bash\necho previous\n")
    }

    @Test func hookUninstallDeletesAHookThatOnlyHeldRvsBlock() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let work = fixture.directory.appendingPathComponent("repo-fresh")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(work, ["init", "-q"])
        _ = try SecretGitHook.install(workTree: work, rvPath: "/usr/bin/true").get()
        let hook = work.appendingPathComponent(".git/hooks/pre-commit")
        #expect(try String(contentsOf: hook, encoding: .utf8).hasPrefix("#!/bin/sh\n# >>> rv secrets >>>"))
        _ = try SecretGitHook.uninstall(workTree: work).get()
        #expect(FileManager.default.fileExists(atPath: hook.path) == false)
    }

    @Test func secretsRobotJSONEscapesLineAndBidiScalars() throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let row = SecretsRun.CheckRow(
            name: "TOKEN",
            source: "keychain rv.secrets/\u{2028}" + sentence,
            ok: false,
            fingerprint: nil,
            error: "\u{2029}" + sentence + "\u{202E}" + sentence)
        let robot = SecretsRun.robotJSON([row])
        #expect(robot.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(robot.unicodeScalars.contains { $0.value == 0x2029 } == false)
        #expect(robot.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(robot.contains("\\u2028"))
        #expect(robot.contains("\\u2029"))
        #expect(robot.contains("\\u202e"))
        let parsed = try JSONSerialization.jsonObject(with: Data(robot.utf8)) as? [[String: Any]]
        #expect(parsed?.first?["name"] as? String == "TOKEN")
        #expect(parsed?.first?["ok"] as? Bool == false)
    }

    @Test func secretNameAndScanPathAreEscaped() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let name = "\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence + "\u{202E}" + sentence
        let environment = fixture.environment()
        let configuration = SecretsConfiguration(secrets: [])
        guard case .failure(let missing) = SecretsRun.check(configuration, names: [name], environment: environment) else {
            Issue.record("undefined name was accepted")
            return
        }
        #expect(missing.message.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(missing.message.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(missing.message.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(missing.message.contains("\\u001b[2J"))
        #expect(missing.message.contains("\\u2028"))
        #expect(missing.message.contains("\\u202e"))
        #expect(missing.message.contains("is not defined in secrets.json"))
        #expect(missing.message.contains("\\\\u001b") == false)

        guard case .failure(let created) = SecretsRun.set(
            name: name, value: Data("x".utf8), definition: nil, agents: [], description: nil, environment: environment)
        else {
            Issue.record("new name was stored")
            return
        }
        #expect(created.message.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(created.message.contains("\\u001b[2J"))
        #expect(created.message.contains("is new: pass --gateway"))
        #expect(created.message.contains("\\\\u001b") == false)

        let removed = try SecretsRun.remove(name: name, environment: environment).get()
        #expect(removed.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(removed.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(removed.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(removed.contains("Deleted "))
        #expect(removed.contains("\\u001b[2J"))
        #expect(removed.contains("\\u202e"))
        let removedLines = removed.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(removedLines.contains(sentence) == false)

        let refusal = SecretsRun.scanNotADirectory("/tmp/" + name)
        #expect(refusal.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(refusal.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(refusal.contains("\\u001b[2J"))
        #expect(refusal.contains("is not a directory"))
        #expect(refusal.contains("\\\\u001b") == false)

        let scan = SecretsRun.scanText(SecretsRun.ScanReport(
            findings: [SecretLeakFinding(path: name, line: 4, secret: "GH_TOKEN")], skipped: []))
        #expect(scan.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(scan.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(scan.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(scan.contains("\\u001b[2J"))
        #expect(scan.contains("\\u2028"))
        #expect(scan.contains(":4  GH_TOKEN"))
        let scanLines = scan.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(scanLines.contains(sentence) == false)
    }

    @Test func secretsCheckPrintsAnEscapedUnknownSource() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let carrier = "\\u001b[2J\\u001b[H\(sentence)\\u2028\(sentence)\\u202e\(sentence)"
        let policy = "{\"version\":1,\"secrets\":{\"allowedSources\":[\"\(carrier)\"]}}"
        guard case .failure(let error) = ManagedPolicy.decode(Data(policy.utf8)) else {
            Issue.record("unknown source was accepted")
            return
        }
        try Data("""
            {"version":1,"secrets":[{"name":"GH","source":{"hostEnvironment":{"variable":"GH"}},"delivery":{"environment":{}}}]}
            """.utf8).write(to: fixture.secretsFile)
        chmod(fixture.secretsFile.path, 0o600)
        var environment = fixture.environment(host: ["GH": "value-good-12345678"])
        environment.managed = .invalid(error.message)
        let rows = try SecretsRun.check(
            try SecretsRun.configuration(environment).get(), names: [], environment: environment).get()
        let text = SecretsRun.checkText(rows)
        #expect(text.contains("FAIL"))
        #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(text.contains("\\u001b[2J"))
        #expect(text.contains("\\u202e"))
        #expect(text.contains("\\\\u001b") == false)
    }
}

/// Real login Keychain: set → check → remove through the CLI logic.
/// Opt in with `RV_LIVE_KEYCHAIN=1`.
@Suite("SecretsCommandLiveKeychain", .enabled(if: ProcessInfo.processInfo.environment["RV_LIVE_KEYCHAIN"] == "1"))
struct SecretsCommandLiveKeychainTests {
    @Test func setCheckRemoveRoundTrip() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let name = "RV_TEST_\(UUID().uuidString.prefix(8).replacingOccurrences(of: "-", with: ""))"
        let environment = SecretsEnvironment(
            configDirectory: fixture.directory, resolver: .live(home: NSTemporaryDirectory()), keychain: .live)
        defer { _ = SecretKeychainWriter.live.delete("rv.secrets", name) }
        _ = try SecretsRun.set(
            name: name, value: Data("live-keychain-value".utf8), definition: .environment, agents: [],
            description: nil, environment: environment).get()
        let configuration = try SecretsRun.configuration(environment).get()
        let rows = try SecretsRun.check(configuration, names: [name], environment: environment).get()
        #expect(rows.first?.ok == true)
        #expect(rows.first?.fingerprint?.count == 16)
        _ = try SecretsRun.remove(name: name, environment: environment).get()
        guard case .failure(.notFound) = SecretResolver.live(home: NSTemporaryDirectory())
            .resolve(.keychain(service: "rv.secrets", account: name))
        else {
            Issue.record("remove must delete the Keychain item")
            return
        }
    }
}
