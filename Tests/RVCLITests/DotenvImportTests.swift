#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIsolation
import RVPolicy
import Testing
@testable import RVCLI

@Suite("rv secrets import --dotenv")
struct DotenvImportTests {
    private func writeEnv(_ fixture: SecretsCLIFixture, _ text: String, name: String = ".env") throws -> URL {
        let url = fixture.directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        chmod(url.path, 0o600)
        return url
    }

    @Test func dryRunBindsNothingAndEchoesAbsolutePath() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let env = try writeEnv(fixture, "STRIPE_SECRET_KEY=sk-test-9\nDEBUG=true\n")
        let text = try SecretsRun.importDotenv(
            path: env, dryRun: true, environment: fixture.environment(), hostEnvironment: [:]).get()
        #expect(text.contains("storing absolute path: \(env.path)"))
        #expect(text.contains("import STRIPE_SECRET_KEY: dotenv (delivery environment)"))
        #expect(text.contains("import DEBUG: dotenv (delivery environment)"))
        #expect(text.contains("git: not a work tree (skipped)"))
        #expect(text.contains("dry run: nothing written"))
        #expect(text.contains("sk-test-9") == false)
        #expect(FileManager.default.fileExists(atPath: fixture.secretsFile.path) == false)
    }

    @Test func writeBindsByReferenceAndReimportIsIdempotent() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let env = try writeEnv(fixture, "STRIPE_SECRET_KEY=sk-test-9\n")
        let text = try SecretsRun.importDotenv(
            path: env, dryRun: false, environment: fixture.environment(), hostEnvironment: [:]).get()
        #expect(text.contains("wrote secrets.json (1 secret; delivery environment)"))
        let stored = try String(contentsOf: fixture.secretsFile, encoding: .utf8)
        #expect(stored.contains("sk-test-9") == false)
        #expect(stored.contains("\"dotenv\""))
        let configuration = try SecretsRun.configuration(fixture.environment()).get()
        #expect(configuration.secret(named: "STRIPE_SECRET_KEY")?.source
            == .dotenv(path: env.path, variable: "STRIPE_SECRET_KEY"))

        let again = try SecretsRun.importDotenv(
            path: env, dryRun: false, environment: fixture.environment(), hostEnvironment: [:]).get()
        #expect(again.contains("skip STRIPE_SECRET_KEY: already bound to dotenv \(env.path)#STRIPE_SECRET_KEY"))
        #expect(again.contains("nothing to import"))
    }

    @Test func skipsEmptyOversizeReservedExportedAndDuplicates() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let big = String(repeating: "v", count: 8_193)
        let env = try writeEnv(fixture, """
            EMPTY_ONE=
            BIG_ONE=\(big)
            PATH=/usr/bin
            EXPORTED_ONE=x
            DUPE=one
            DUPE=two
            GOOD_ONE=ok
            """)
        let text = try SecretsRun.importDotenv(
            path: env, dryRun: true, environment: fixture.environment(),
            hostEnvironment: ["EXPORTED_ONE": "y"]).get()
        #expect(text.contains("skip EMPTY_ONE: empty value cannot stage"))
        #expect(text.contains("skip BIG_ONE: value exceeds the 8 KiB environment limit"))
        #expect(text.contains("skip PATH: reserved variable"))
        #expect(text.contains("skip EXPORTED_ONE: already defined in this project's environment"))
        #expect(text.contains("skip DUPE: duplicate variable in file"))
        #expect(text.contains("import GOOD_ONE: dotenv (delivery environment)"))
    }

    @Test func policyDenialFailsEvenInDryRun() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let env = try writeEnv(fixture, "STRIPE_SECRET_KEY=sk-test-9\n")
        var policy = ManagedPolicy()
        policy.secrets.allowedSources = ["keychain"]
        var environment = fixture.environment()
        environment.managed = .active(
            ManagedPolicyBundle(policy: policy, sha256: "", isSigned: false, directory: ""))
        guard case .failure(let failure) = SecretsRun.importDotenv(
            path: env, dryRun: true, environment: environment, hostEnvironment: [:])
        else {
            Issue.record("dry run under a denying policy must fail")
            return
        }
        #expect(failure.message == "organization policy: STRIPE_SECRET_KEY uses a dotenv source, which is not allowed; nothing imported")
    }

    @Test func groupWritableFileRefusedAtImport() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let env = try writeEnv(fixture, "STRIPE_SECRET_KEY=sk-test-9\n")
        chmod(env.path, 0o664)
        guard case .failure(let failure) = SecretsRun.importDotenv(
            path: env, dryRun: true, environment: fixture.environment(), hostEnvironment: [:])
        else {
            Issue.record("group-writable .env must be refused at import")
            return
        }
        #expect(failure.message.contains("writable"))
    }

    @Test func exactlyOneOfVarlockOrDotenv() throws {
        #expect(throws: Error.self) { try SecretsImport.parse([]) }
        #expect(throws: Error.self) { try SecretsImport.parse(["--varlock", "a", "--dotenv", "b"]) }
        let parsed = try SecretsImport.parse(["--dotenv", ".env"])
        #expect(parsed.dotenv == ".env")
        #expect(parsed.varlock == nil)
    }

    @Test func initReviewLinesAnnotateButNeverSkip() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let env = try writeEnv(fixture, "STRIPE_SECRET_KEY=sk-test-9\nDEBUG=true\n")
        let candidates = try SecretsRun.dotenvCandidates(
            path: env, current: .empty, hostEnvironment: [:]).get()
        let lines = InitRun.dotenvReviewLines(candidates)
        #expect(lines.first == "dotenv \(env.path): would bind 2 names (values stay in .env)")
        #expect(lines.contains("  bind STRIPE_SECRET_KEY (dotenv STRIPE_SECRET_KEY; delivery environment)"))
        #expect(lines.contains("  bind DEBUG (dotenv DEBUG; delivery environment; not secret-looking)"))
        #expect(InitRun.dotenvFreshNames(candidates) == ["STRIPE_SECRET_KEY", "DEBUG"])
    }

    @Test func listMarksDotenvFileBackedNotWeaker() throws {
        let configuration = SecretsConfiguration(secrets: [
            SecretDefinition(
                name: "A_KEY", source: .dotenv(path: "/p/.env", variable: "A_KEY"), delivery: .environment),
            SecretDefinition(name: "B_KEY", source: .hostEnvironment(variable: "B"), delivery: .environment),
        ])
        let report = SecretsRun.list(configuration, profiles: [])
        let a = try #require(report.secrets.first { $0.name == "A_KEY" })
        #expect(a.fileBacked)
        #expect(a.weaker == false)
        let text = SecretsRun.listText(report)
        #expect(text.contains("[file-backed]"))
        #expect(SecretsRun.robotJSON(report).contains("\"fileBacked\""))
    }

    @Test func setRefusalOnDotenvNamesHarden() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let env = try writeEnv(fixture, "STRIPE_SECRET_KEY=sk-test-9\n")
        _ = try SecretsRun.importDotenv(
            path: env, dryRun: false, environment: fixture.environment(), hostEnvironment: [:]).get()
        guard case .failure(let failure) = SecretsRun.set(
            name: "STRIPE_SECRET_KEY", value: Data("new-value".utf8), definition: nil, agents: [],
            description: nil, environment: fixture.environment())
        else {
            Issue.record("set on a dotenv-bound name must refuse")
            return
        }
        #expect(failure.message.contains("reads from dotenv"))
        #expect(failure.message.contains("use `rv secrets harden STRIPE_SECRET_KEY` to move this value into the Keychain"))
    }
}
