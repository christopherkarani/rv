#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIsolation
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
        let report = SecretsRun.scan(
            root: tree, configuration: try SecretsRun.configuration(environment).get(), environment: environment)
        #expect(report.findings == [SecretLeakFinding(path: ".env", line: 2, secret: "GH_TOKEN")])
        let text = SecretsRun.scanText(report)
        #expect(text == ".env:2  GH_TOKEN\n")
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
