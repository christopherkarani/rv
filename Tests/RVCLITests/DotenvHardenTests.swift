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

@Suite("rv secrets harden")
struct DotenvHardenTests {
    /// Fixture with a dotenv-bound secret whose value the fake resolver reads
    /// from a real temp `.env`, and a fake Keychain shared with the resolver.
    private func fixture(policy: ManagedPolicy? = nil) throws -> (SecretsCLIFixture, SecretsEnvironment, URL) {
        let fixture = try SecretsCLIFixture()
        let envFile = fixture.directory.appendingPathComponent(".env")
        try Data("STRIPE_SECRET_KEY=sk-live-777\n".utf8).write(to: envFile)
        chmod(envFile.path, 0o600)
        let keychain = fixture.keychain
        let resolver = SecretResolver.live(
            environment: [:], home: "/nonexistent",
            dotenvReader: { DotenvLiveReader.read(path: $0) })
        let composed = SecretResolver { source in
            if case .keychain(let service, let account) = source {
                guard let data = keychain.items.withLock({ $0["\(service)/\(account)"] }) else {
                    return .failure(.notFound("keychain"))
                }
                return SecretResolver.live(environment: ["V": String(decoding: data, as: UTF8.self)], home: "/")
                    .resolve(.hostEnvironment(variable: "V"))
            }
            return resolver.resolve(source)
        }
        var environment = SecretsEnvironment(
            configDirectory: fixture.directory, resolver: composed, keychain: keychain.writer)
        if let policy {
            environment.managed = .active(
                ManagedPolicyBundle(policy: policy, sha256: "", isSigned: false, directory: ""))
        }
        _ = try SecretsRun.importDotenv(path: envFile, dryRun: false, environment: environment, hostEnvironment: [:]).get()
        return (fixture, environment, envFile)
    }

    @Test func hardenMovesValueAndRebinds() throws {
        let (fixture, environment, envFile) = try self.fixture()
        defer { fixture.tearDown() }
        let result = try SecretsRun.harden(names: ["STRIPE_SECRET_KEY"], all: false, environment: environment).get()
        #expect(result.failed == false)
        #expect(result.text.contains(
            "hardened STRIPE_SECRET_KEY: dotenv \(envFile.path)#STRIPE_SECRET_KEY -> keychain rv.secrets/STRIPE_SECRET_KEY (delivery unchanged: environment; stored value verified)"))
        #expect(result.text.contains("rotation checklist for STRIPE_SECRET_KEY:"))
        #expect(result.text.contains("remove the STRIPE_SECRET_KEY line from \(envFile.path)"))
        #expect(fixture.keychain.items.withLock { $0["rv.secrets/STRIPE_SECRET_KEY"] } == Data("sk-live-777".utf8))
        let configuration = try SecretsRun.configuration(environment).get()
        #expect(configuration.secret(named: "STRIPE_SECRET_KEY")?.source
            == .keychain(service: "rv.secrets", account: "STRIPE_SECRET_KEY"))
        let audit = (try? String(
            contentsOf: fixture.directory.appendingPathComponent("audit.jsonl"), encoding: .utf8)) ?? ""
        #expect(audit.contains("\"hardened\"") || audit.contains("hardened"))
        #expect(audit.contains("sk-live-777") == false)
        // .env untouched.
        #expect(try String(contentsOf: envFile, encoding: .utf8) == "STRIPE_SECRET_KEY=sk-live-777\n")
    }

    @Test func hardenWorksUnderDotenvDenyButNotKeychainDeny() throws {
        var denyDotenv = ManagedPolicy()
        denyDotenv.secrets.allowedSources = ["keychain"]
        // Fixture import happens under the same policy and would be refused;
        // build without policy, then apply it for the harden call.
        let (fixture, base, _) = try self.fixture()
        defer { fixture.tearDown() }
        var environment = base
        environment.managed = .active(
            ManagedPolicyBundle(policy: denyDotenv, sha256: "", isSigned: false, directory: ""))
        let result = try SecretsRun.harden(names: ["STRIPE_SECRET_KEY"], all: false, environment: environment).get()
        #expect(result.failed == false)

        var denyKeychain = ManagedPolicy()
        denyKeychain.secrets.allowedSources = ["vault"]
        environment.managed = .active(
            ManagedPolicyBundle(policy: denyKeychain, sha256: "", isSigned: false, directory: ""))
        guard case .failure(let failure) = SecretsRun.harden(
            names: ["STRIPE_SECRET_KEY"], all: false, environment: environment)
        else {
            Issue.record("keychain-deny must refuse harden")
            return
        }
        #expect(failure.message.contains("keychain sources are not allowed"))
    }

    @Test func hardenRefusesUndefinedAndNonDotenv() throws {
        let (fixture, environment, _) = try self.fixture()
        defer { fixture.tearDown() }
        let undefined = try SecretsRun.harden(names: ["NOPE"], all: false, environment: environment).get()
        #expect(undefined.failed)
        #expect(undefined.text.contains("NOPE is not defined"))
        _ = try SecretsRun.set(
            name: "PLAIN_KEY", value: Data("plain-value".utf8), definition: .environment, agents: [],
            description: nil, environment: environment).get()
        let plain = try SecretsRun.harden(names: ["PLAIN_KEY"], all: false, environment: environment).get()
        #expect(plain.failed)
        #expect(plain.text.contains("reads from keychain rv.secrets/PLAIN_KEY"))
    }

    @Test func readBackMismatchLeavesBindingUntouched() throws {
        let (fixture, base, _) = try self.fixture()
        defer { fixture.tearDown() }
        var environment = base
        let inner = base.resolver
        environment.resolver = SecretResolver { source in
            if case .keychain = source { return .success(SecretValue("different-value")!) }
            return inner.resolve(source)
        }
        let before = try String(contentsOf: fixture.secretsFile, encoding: .utf8)
        let result = try SecretsRun.harden(names: ["STRIPE_SECRET_KEY"], all: false, environment: environment).get()
        #expect(result.failed)
        #expect(result.text.contains("does not match"))
        #expect(try String(contentsOf: fixture.secretsFile, encoding: .utf8) == before)
    }

    @Test func allHardensDotenvAndSkipsOthers() throws {
        let (fixture, environment, _) = try self.fixture()
        defer { fixture.tearDown() }
        _ = try SecretsRun.set(
            name: "PLAIN_KEY", value: Data("plain-value".utf8), definition: .environment, agents: [],
            description: nil, environment: environment).get()
        let result = try SecretsRun.harden(names: [], all: true, environment: environment).get()
        #expect(result.failed == false)
        #expect(result.text.contains("hardened STRIPE_SECRET_KEY:"))
        #expect(result.text.contains("skip PLAIN_KEY: reads from keychain rv.secrets/PLAIN_KEY (not dotenv; nothing to harden)"))
    }

    @Test func scanExemptsOnlyTheBoundSecretInItsOriginFile() throws {
        let (fixture, environment, envFile) = try self.fixture()
        defer { fixture.tearDown() }
        // A second secret whose value is pasted into the bound .env.
        _ = try SecretsRun.set(
            name: "PLAIN_KEY", value: Data("plain-value-999".utf8), definition: .environment, agents: [],
            description: nil, environment: environment).get()
        try Data("STRIPE_SECRET_KEY=sk-live-777\nLEAKED=plain-value-999\n".utf8).write(to: envFile)
        chmod(envFile.path, 0o600)
        let copy = fixture.directory.appendingPathComponent("copy.txt")
        try Data("sk-live-777\n".utf8).write(to: copy)

        let configuration = try SecretsRun.configuration(environment).get()
        let report = SecretsRun.scan(root: fixture.directory, configuration: configuration, environment: environment)
        #expect(report.origins.contains { $0.secret == "STRIPE_SECRET_KEY" && $0.path == ".env" })
        #expect(report.findings.contains { $0.secret == "PLAIN_KEY" && $0.path == ".env" })
        #expect(report.findings.contains { $0.secret == "STRIPE_SECRET_KEY" && $0.path == "copy.txt" })
        let text = SecretsRun.scanText(report)
        #expect(text.contains("origin files (bound .env sources; not failures):"))
        #expect(text.contains(".env (1 secret bound)"))
    }

    @Test func managedStatusNamesDotenvPosture() throws {
        var deny = ManagedPolicy()
        deny.secrets.allowedSources = ["keychain", "vault"]
        let deniedState = ManagedPolicyState.active(
            ManagedPolicyBundle(policy: deny, sha256: "x", isSigned: false, directory: "/d"))
        #expect(ManagedRun.dotenvLine(state: deniedState, boundCount: 2)
            == "dotenv: forbidden; 2 dotenv-bound secrets will fail closed")
        let openState = ManagedPolicyState.active(
            ManagedPolicyBundle(policy: ManagedPolicy(), sha256: "x", isSigned: false, directory: "/d"))
        #expect(ManagedRun.dotenvLine(state: openState, boundCount: 1)
            == "dotenv: allowed by default (policy does not enumerate allowedSources); 1 dotenv-bound secret")
        #expect(ManagedRun.dotenvLine(state: .none, boundCount: 3)
            == "dotenv: allowed (no organization policy); 3 dotenv-bound secrets")
        #expect(ManagedRun.dotenvLine(state: deniedState, boundCount: 0) == nil)
        let status = ManagedRun.status(deniedState, directory: "/d", dotenvBoundCount: 2)
        #expect(ManagedRun.statusText(status).contains("dotenv: forbidden"))
        #expect(status.dotenv != nil)
    }
}
