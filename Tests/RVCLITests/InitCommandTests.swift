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

    @Test func varlockFreshNamesSkipsLiteralsAndExisting() throws {
        let text = """
            NEW_KEY=op(op://vault/item/field)
            LITERAL=hardcoded-value
            """
        let empty = SecretsConfiguration()
        #expect(InitRun.varlockFreshNames(text: text, current: empty) == ["NEW_KEY"])
        let defined = SecretsConfiguration(secrets: [
            SecretDefinition(
                name: "NEW_KEY", source: .onePassword(reference: "op://vault/item/field"),
                delivery: .environment),
        ])
        #expect(InitRun.varlockFreshNames(text: text, current: defined).isEmpty)
        #expect(InitRun.varlockFreshNames(text: "\0", current: empty).isEmpty)
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
        #expect(text.contains("rv opencode --workspace /proj --resource-profile main"))
        let dry = InitRun.planText(
            plan, project: "/proj", secretDefined: [:], varlockLines: [], dryRun: true, wrote: false)
        #expect(dry.contains("dry run: nothing written"))
    }
}
