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
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-secrets-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        // Canonicalized (realpath, not resolvingSymlinksInPath, which keeps
        // /var unresolved): dotenv bindings store canonical paths, so
        // fixture paths must already be canonical for exact comparisons.
        directory = DotenvLiveReader.canonicalPath(created.path).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? created
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
            environment: environment) == .failure(CommandFailure(
                "NEW is new: pass --gateway URL --base-url-env VAR, or --environment; "
                    + "to bind a value already in a .env file instead, use `rv secrets import --dotenv <file>`")))
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
        #expect(imported.contains("import OPENAI_API_KEY: onePassword (type string(startsWith=sk-))"))
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

    @Test func hookInstallIsIdempotentAndScansTheIndex() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let work = fixture.directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        func run(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try run(["-C", work.path, "init", "-q"])
        let foreign = work.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\necho foreign\n".utf8).write(to: foreign)
        chmod(foreign.path, 0o755)
        let installed = try SecretGitHook.install(workTree: work, rvPath: "/usr/bin/true").get()
        #expect(installed.contains("installed"))
        let hook = try String(contentsOf: foreign, encoding: .utf8)
        #expect(hook.contains("# rv-secrets-hook"))
        #expect(hook.contains("'/usr/bin/true'"))
        let saved = try String(contentsOf: work.appendingPathComponent(".git/hooks/pre-commit.rv-saved"), encoding: .utf8)
        #expect(saved == "#!/bin/sh\necho foreign\n")
        _ = try SecretGitHook.install(workTree: work, rvPath: "/usr/bin/true").get()
        #expect(try String(contentsOf: work.appendingPathComponent(".git/hooks/pre-commit.rv-saved"), encoding: .utf8) == saved)

        let value = "hook-secret-value-xyz"
        var configuration = SecretsConfiguration(secrets: [
            SecretDefinition(name: "GH_TOKEN", source: .hostEnvironment(variable: "GH_TOKEN"), delivery: .environment),
        ])
        _ = try configuration.write(configDirectory: fixture.directory).get()
        let environment = fixture.environment(host: ["GH_TOKEN": value])
        try Data("clean\n".utf8).write(to: work.appendingPathComponent("clean.txt"))
        try Data("\(value)\n".utf8).write(to: work.appendingPathComponent("leak.txt"))
        try run(["-C", work.path, "add", "clean.txt"])
        let clean = try SecretsRun.hookRun(workTree: work, environment: environment).get()
        #expect(clean.failed == false)
        #expect(clean.text.contains(value) == false)
        try run(["-C", work.path, "add", "leak.txt"])
        let leaked = try SecretsRun.hookRun(workTree: work, environment: environment).get()
        #expect(leaked.failed)
        #expect(leaked.text.contains("leak.txt:1:GH_TOKEN"))
        #expect(leaked.text.contains(value) == false)

        let removed = try SecretGitHook.uninstall(workTree: work).get()
        #expect(removed.contains("restored"))
        #expect(try String(contentsOf: foreign, encoding: .utf8) == saved)
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

    @Test func hookMentioningTheMarkerIsBackedUpNotOverwritten() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let work = fixture.directory.appendingPathComponent("repo-marker")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try git(work, ["init", "-q"])
        let foreign = work.appendingPathComponent(".git/hooks/pre-commit")
        let original = "#!/bin/sh\n# rv-secrets-hook mentioned in a comment\necho foreign\n"
        try Data(original.utf8).write(to: foreign)
        chmod(foreign.path, 0o755)
        _ = try SecretGitHook.install(workTree: work, rvPath: "/usr/bin/true").get()
        #expect(try String(contentsOf: work.appendingPathComponent(".git/hooks/pre-commit.rv-saved"), encoding: .utf8) == original)
        _ = try SecretGitHook.uninstall(workTree: work).get()
        #expect(try String(contentsOf: foreign, encoding: .utf8) == original)
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
