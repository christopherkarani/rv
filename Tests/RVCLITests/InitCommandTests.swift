#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation
import RVPolicy
import Testing
@testable import RVCLI

@Suite("rv init")
struct InitCommandTests {
    struct Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-init-cli-\(UUID().uuidString)", isDirectory: true)
        var home: URL { root.appendingPathComponent("home", isDirectory: true) }
        var config: URL { home.appendingPathComponent(".config/rv", isDirectory: true) }
        var bin: URL { home.appendingPathComponent("bin", isDirectory: true) }
        var project: URL { home.appendingPathComponent("proj", isDirectory: true) }

        func write(_ relative: String, _ text: String, executable: Bool = false) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            if executable { chmod(url.path, 0o755) }
        }

        func environment() -> InitEnvironment {
            InitEnvironment(
                configDirectory: config, home: home, pathDirectories: [bin.path],
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) })
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func planDetectsBinaryAndCredential() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try fixture.write("bin/codex", "#!/bin/sh\n", executable: true)
        try fixture.write(".codex/auth.json", "{}")
        let plan = try InitRun.plan(
            profileID: "main", project: "/proj", agents: [], secretNames: [],
            environment: fixture.environment()).get()
        #expect(plan.profile.id == "main")
        #expect(plan.profile.projects == ["/proj"])
        #expect(plan.profile.agents == ["codex"])
        #expect(plan.profile.executableLinks.map(\.name) == ["codex"])
        #expect(plan.profile.executableLinks.first?.target.hasSuffix("/bin/codex") == true)
        #expect(plan.profile.credentials.map(\.destination) == [".codex/auth.json"])
        #expect(plan.notes.joined(separator: " ").contains("codex"))
    }

    @Test func planExplicitAgentsNarrowDetection() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try fixture.write("bin/codex", "#!/bin/sh\n", executable: true)
        try fixture.write(".codex/auth.json", "{}")
        try fixture.write("bin/opencode", "#!/bin/sh\n", executable: true)
        let plan = try InitRun.plan(
            profileID: "main", project: "/proj", agents: ["opencode"], secretNames: [],
            environment: fixture.environment()).get()
        #expect(plan.profile.agents == ["opencode"])
        #expect(plan.profile.executableLinks.map(\.name) == ["opencode"])
        #expect(plan.profile.credentials.isEmpty)
    }

    @Test func planRejectsBadInput() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let environment = fixture.environment()
        let badID = InitRun.plan(
            profileID: "has space", project: "/proj", agents: [], secretNames: [], environment: environment)
        #expect(badID.failureMessage?.contains("profile id") == true)
        let badAgent = InitRun.plan(
            profileID: "main", project: "/proj", agents: ["has space"], secretNames: [], environment: environment)
        #expect(badAgent.failureMessage?.contains("agent tag") == true)
        let dupAgents = InitRun.plan(
            profileID: "main", project: "/proj", agents: ["a", "a"], secretNames: [], environment: environment)
        #expect(dupAgents.failureMessage?.contains("distinct") == true)
        let badSecret = InitRun.plan(
            profileID: "main", project: "/proj", agents: [], secretNames: ["not a name"],
            environment: environment)
        #expect(badSecret.failureMessage?.contains("environment variable name") == true)
        let tooMany = InitRun.plan(
            profileID: "main", project: "/proj", agents: [],
            secretNames: (0..<17).map { "S\($0)" }, environment: environment)
        #expect(tooMany.failureMessage?.contains("16 secrets") == true)
    }

    @Test func planWithNothingDetectedServesEveryLaunch() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let plan = try InitRun.plan(
            profileID: "main", project: "/proj", agents: [], secretNames: [],
            environment: fixture.environment()).get()
        #expect(plan.profile.agents.isEmpty)
        #expect(plan.profile.executableLinks.isEmpty)
        #expect(plan.profile.credentials.isEmpty)
        #expect(plan.notes.isEmpty == false)
    }

    @Test func missingAgentNoteOnlyForExplicitAgents() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let detected = try InitRun.plan(
            profileID: "main", project: "/proj", agents: [], secretNames: [],
            environment: fixture.environment()).get()
        #expect(detected.notes.joined(separator: "\n").contains("may be missing") == false)
        let explicit = try InitRun.plan(
            profileID: "main", project: "/proj", agents: ["ghost"], secretNames: [],
            environment: fixture.environment()).get()
        #expect(explicit.notes.joined(separator: "\n").contains("ghost"))
    }

    @Test func planWiresSecretNamesSortedAndDeduped() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let plan = try InitRun.plan(
            profileID: "main", project: "/proj", agents: [], secretNames: ["B_KEY", "A_KEY", "B_KEY"],
            environment: fixture.environment()).get()
        #expect(plan.profile.secrets == ["A_KEY", "B_KEY"])
    }

    @Test func writeProfileAppendsAndRefusesDuplicates() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let first = RuntimeResourceProfile(id: "main", projects: ["/proj"])
        let second = RuntimeResourceProfile(id: "other", projects: ["/proj"])
        _ = try InitRun.writeProfile(first, configDirectory: fixture.config).get()
        _ = try InitRun.writeProfile(second, configDirectory: fixture.config).get()
        let reloaded = try RuntimeResourcePolicyStore.load(from: fixture.config).get()
        #expect(reloaded.profiles.map(\.id) == ["main", "other"])
        let duplicate = InitRun.writeProfile(first, configDirectory: fixture.config)
        #expect(duplicate.failureMessage?.contains("--profile-id") == true)
        #expect(try RuntimeResourcePolicyStore.load(from: fixture.config).get().profiles.count == 2)
    }

    @Test func writeProfileRejectsDocumentsTheHostWouldRefuse() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        let bad = RuntimeResourceProfile(id: "has space", projects: ["/proj"])
        let result = InitRun.writeProfile(bad, configDirectory: fixture.config)
        #expect(result.failureMessage?.contains("invalid") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("runtime-resources.json").path) == false)
    }

    @Test func writeProfileFailsClosedOnUnreadablePolicy() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try FileManager.default.createDirectory(at: fixture.config, withIntermediateDirectories: true)
        let file = fixture.config.appendingPathComponent("runtime-resources.json")
        try Data("not json".utf8).write(to: file)
        chmod(file.path, 0o600)
        let result = InitRun.writeProfile(
            RuntimeResourceProfile(id: "main", projects: ["/proj"]), configDirectory: fixture.config)
        #expect(result.failureMessage?.isEmpty == false)
    }

    @Test func attachSecretAppendsOnce() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        _ = try InitRun.writeProfile(
            RuntimeResourceProfile(id: "main", projects: ["/proj"]), configDirectory: fixture.config).get()
        #expect(try InitRun.attachSecret("A_KEY", profileID: "main", configDirectory: fixture.config).get())
        #expect(try InitRun.attachSecret("A_KEY", profileID: "main", configDirectory: fixture.config).get() == false)
        let reloaded = try RuntimeResourcePolicyStore.load(from: fixture.config).get()
        #expect(reloaded.profiles.first?.secrets == ["A_KEY"])
        let missing = InitRun.attachSecret("B_KEY", profileID: "nope", configDirectory: fixture.config)
        #expect(missing.failureMessage?.contains("rv init") == true)
    }

    /// Runs `rv init` against the fixture's home and returns its output.
    private func runInit(_ arguments: [String], fixture: Fixture) throws -> String {
        let secrets = SecretsEnvironment(
            configDirectory: fixture.config, resolver: FakeKeychain().resolver(host: [:]), keychain: FakeKeychain().writer)
        return try Init.parse(arguments)
            .execute(root: fixture.project, environment: fixture.environment(), secretsEnvironment: secrets).get()
    }

    private func writeSchema(_ fixture: Fixture) throws {
        try fixture.write("proj/.env.schema", """
            # @sensitive
            OPENAI_API_KEY=op(op://Private/OpenAI/credential)
            """)
    }

    // A cloned repo's .env.schema must not bind the user's vault secrets.
    @Test func projectSchemaIsSuggestedButNeverImported() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try writeSchema(fixture)
        let schema = fixture.project.appendingPathComponent(".env.schema").path

        let dry = try runInit(["--dry-run"], fixture: fixture)
        #expect(dry.contains("varlock \(schema): found, not imported"))
        #expect(dry.contains("rerun with --varlock \(schema)"))

        let wrote = try runInit([], fixture: fixture)
        #expect(wrote.contains("found, not imported"))
        #expect(wrote.contains("rv secrets import --varlock \(schema) --resource-profile main"))
        #expect(wrote.contains("OPENAI_API_KEY") == false)
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("secrets.json").path) == false)
        let profile = try RuntimeResourcePolicyStore.load(from: fixture.config).get().profiles.first
        #expect(profile?.id == "main")
        #expect(profile?.secrets.isEmpty == true)
    }

    @Test func explicitVarlockShowsAndImportsEachSecret() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        try writeSchema(fixture)
        let schema = fixture.project.appendingPathComponent(".env.schema").path
        let line = "import OPENAI_API_KEY: provider onePassword, delivery environment (real value in the cage)"

        let dry = try runInit(["--varlock", schema, "--dry-run"], fixture: fixture)
        #expect(dry.contains("varlock \(schema): would import 1 secret"))
        #expect(dry.contains(line))
        #expect(dry.contains("found, not imported") == false)
        #expect(FileManager.default.fileExists(atPath: fixture.config.appendingPathComponent("secrets.json").path) == false)

        let wrote = try runInit(["--varlock", schema], fixture: fixture)
        #expect(wrote.contains(line))
        let stored = try SecretsConfiguration.load(configDirectory: fixture.config).get()
        #expect(stored.secret(named: "OPENAI_API_KEY")?.source == .onePassword(reference: "op://Private/OpenAI/credential"))
        let profile = try RuntimeResourcePolicyStore.load(from: fixture.config).get().profiles.first
        #expect(profile?.secrets == ["OPENAI_API_KEY"])
    }

    @Test func policyFileEncodeRoundTrips() throws {
        let policy = RuntimeResourcePolicy(
            version: 1,
            profiles: [
                RuntimeResourceProfile(
                    id: "main", projects: ["/proj"], agents: ["codex"],
                    executableLinks: [.init(name: "codex", target: "/usr/local/bin/codex")],
                    readFiles: ["/usr/local/bin/codex"],
                    credentials: [.init(source: "/home/.codex/auth.json", destination: ".codex/auth.json")],
                    environment: [.init(name: "LIT", literalValue: "1")],
                    keychain: [.init(service: "s", account: "a", env: "K")],
                    secrets: ["A_KEY"]),
            ],
            defaultProfile: "main")
        let decoded = try RuntimeResourcePolicyStore.decode(RuntimeResourcePolicyFile.encode(policy)).get()
        #expect(decoded == policy)
    }

    @Test func shellWordQuotesSpacedPaths() {
        #expect(InitRun.shellWord("/plain/path") == "/plain/path")
        #expect(InitRun.shellWord("/my proj/dir") == "'/my proj/dir'")
    }

    @Test func shellWordKeepsShellExpansionsInert() {
        // No whitespace, but pasting this raw would run the substitution.
        #expect(InitRun.shellWord("/tmp/$(touch pwned)") == "'/tmp/$(touch pwned)'")
        #expect(InitRun.shellWord("/tmp/a;b") == "'/tmp/a;b'")
        #expect(InitRun.shellWord("/tmp/`id`") == "'/tmp/`id`'")
        #expect(InitRun.shellWord("/tmp/a'b") == "'/tmp/a'\\''b'")
    }

    @Test func ensureProfileCanBeAddedRejectsDuplicates() throws {
        let fixture = Fixture()
        defer { fixture.tearDown() }
        _ = try InitRun.writeProfile(
            RuntimeResourceProfile(id: "main", projects: ["/proj"]), configDirectory: fixture.config).get()
        let duplicate = InitRun.ensureProfileCanBeAdded("main", configDirectory: fixture.config)
        #expect(duplicate.failureMessage?.contains("already exists") == true)
        _ = try InitRun.ensureProfileCanBeAdded("other", configDirectory: fixture.config).get()
    }

    @Test func planTextNamesRemediesAndNextStep() throws {
        let profile = RuntimeResourceProfile(id: "main", projects: ["/proj"], secrets: ["A_KEY", "B_KEY"])
        let plan = InitRun.Plan(profile: profile, notes: ["a note"])
        let text = InitRun.planText(
            plan, project: "/proj", secretDefined: ["A_KEY": true, "B_KEY": false],
            varlockLines: [], dryRun: false, wrote: true)
        #expect(text.contains("profile main for /proj"))
        #expect(text.contains("staged at launch"))
        #expect(text.contains("`rv secrets set B_KEY`"))
        #expect(text.contains("wrote runtime-resources.json"))
        #if os(macOS)
        #expect(text.contains("next: rv opencode --workspace /proj --resource-profile main"))
        #else
        #expect(text.contains("next: rv setup"))
        #expect(text.contains("next: rv opencode") == false)
        #endif
        let dry = InitRun.planText(
            plan, project: "/proj", secretDefined: [:], varlockLines: [], dryRun: true, wrote: false)
        #expect(dry.contains("dry run: nothing written"))
    }
}
