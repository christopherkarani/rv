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

    @Test func writerFailureAfterFirstStoreLeavesConfigUntouchedAndRetryCompletes() throws {
        let fixture = try SecretsCLIFixture()
        defer { fixture.tearDown() }
        let envFile = fixture.directory.appendingPathComponent(".env")
        try Data("FIRST_KEY=first-value-1\nSECOND_KEY=second-value-2\n".utf8).write(to: envFile)
        chmod(envFile.path, 0o600)
        let stored = Mutex<[String: Data]>([:])
        let attempts = Mutex(0)
        let flakyWriter = SecretKeychainWriter(
            store: { service, account, value in
                let attempt = attempts.withLock { count -> Int in count += 1; return count }
                if attempt > 1 { return false }
                stored.withLock { $0["\(service)/\(account)"] = value }
                return true
            },
            delete: { _, _ in true })
        let live = SecretResolver.live(environment: [:], home: "/nonexistent")
        let resolver = SecretResolver { source in
            if case .keychain(let service, let account) = source {
                guard let data = stored.withLock({ $0["\(service)/\(account)"] }) else {
                    return .failure(.notFound("keychain"))
                }
                return SecretResolver.live(environment: ["V": String(decoding: data, as: UTF8.self)], home: "/")
                    .resolve(.hostEnvironment(variable: "V"))
            }
            return live.resolve(source)
        }
        var environment = SecretsEnvironment(
            configDirectory: fixture.directory, resolver: resolver, keychain: flakyWriter)
        _ = try SecretsRun.importDotenv(path: envFile, dryRun: false, environment: environment, hostEnvironment: [:]).get()
        let before = try String(contentsOf: fixture.secretsFile, encoding: .utf8)

        let crashed = try SecretsRun.harden(names: [], all: true, environment: environment).get()
        #expect(crashed.failed)
        #expect(crashed.text.contains("nothing rebound"))
        #expect(crashed.text.contains("hardened FIRST_KEY:") == false)
        #expect(crashed.text.contains("rotation checklist") == false)
        #expect(try String(contentsOf: fixture.secretsFile, encoding: .utf8) == before)

        environment.keychain = SecretKeychainWriter(
            store: { service, account, value in
                stored.withLock { $0["\(service)/\(account)"] = value }
                return true
            },
            delete: { _, _ in true })
        let retried = try SecretsRun.harden(names: [], all: true, environment: environment).get()
        #expect(retried.failed == false)
        let configuration = try SecretsRun.configuration(environment).get()
        #expect(configuration.secrets.allSatisfy { $0.source.kind == "keychain" })
    }

    @Test func hardenRefusesToOverwriteAReferencedKeychainAccount() throws {
        let (fixture, environment, _) = try self.fixture()
        defer { fixture.tearDown() }
        var configuration = try SecretsRun.configuration(environment).get()
        configuration.secrets.append(SecretDefinition(
            name: "OTHER",
            source: .keychain(service: SecretKeychain.service, account: "STRIPE_SECRET_KEY"),
            delivery: .environment))
        _ = try configuration.write(configDirectory: fixture.directory).get()
        let result = try SecretsRun.harden(names: ["STRIPE_SECRET_KEY"], all: false, environment: environment).get()
        #expect(result.failed)
        #expect(result.text.contains("another secret already reads from"))
        let after = try SecretsRun.configuration(environment).get()
        #expect(after.secret(named: "STRIPE_SECRET_KEY")?.source.kind == "dotenv")
    }

    @Test func hardenDetectsConfigChangeDuringKeychainStore() throws {
        let (fixture, base, _) = try self.fixture()
        defer { fixture.tearDown() }
        // The writer simulates a concurrent edit: while harden copies the
        // value, secrets.json changes under it. Harden must rebind nothing.
        let directory = fixture.directory
        var environment = base
        environment.keychain = SecretKeychainWriter(
            store: { service, account, value in
                fixture.keychain.items.withLock { $0["\(service)/\(account)"] = value }
                if case .success(var edited) = SecretsConfiguration.load(configDirectory: directory) {
                    edited.secrets.removeAll { $0.name == "STRIPE_SECRET_KEY" }
                    edited.secrets.append(SecretDefinition(
                        name: "STRIPE_SECRET_KEY", source: .hostEnvironment(variable: "OTHER"),
                        delivery: .environment))
                    _ = edited.write(configDirectory: directory)
                }
                return true
            },
            delete: { _, _ in true })
        let result = try SecretsRun.harden(names: ["STRIPE_SECRET_KEY"], all: false, environment: environment).get()
        #expect(result.failed)
        #expect(result.text.contains("nothing rebound"))
        #expect(result.text.contains("changed in secrets.json during harden"))
        let after = try SecretsRun.configuration(environment).get()
        #expect(after.secret(named: "STRIPE_SECRET_KEY")?.source.kind == "hostEnvironment")
    }

    @Test func hardenFailsClosedOnInvalidPolicy() throws {
        let (fixture, base, _) = try self.fixture()
        defer { fixture.tearDown() }
        var environment = base
        environment.managed = .invalid("bad policy")
        guard case .failure(let failure) = SecretsRun.harden(
            names: ["STRIPE_SECRET_KEY"], all: false, environment: environment)
        else {
            Issue.record("invalid policy must refuse harden")
            return
        }
        #expect(failure.message.contains("invalid"))
    }

    @Test func scanAndHookFailClosedOnInvalidPolicy() throws {
        let (fixture, base, _) = try self.fixture()
        defer { fixture.tearDown() }
        var environment = base
        environment.managed = .invalid("bad policy")
        let configuration = try SecretsRun.configuration(base).get()
        let report = SecretsRun.scan(root: fixture.directory, configuration: configuration, environment: environment)
        #expect(report.blocked != nil)
        #expect(SecretsRun.scanText(report).contains("organization policy is invalid"))
        guard case .failure = SecretsRun.hookRun(workTree: fixture.directory, environment: environment) else {
            Issue.record("hook must fail closed on an invalid policy")
            return
        }
    }

    @Test func scanSkipsPolicyDeniedSecretsUnderValidPolicy() throws {
        let (fixture, base, _) = try self.fixture()
        defer { fixture.tearDown() }
        var deny = ManagedPolicy()
        deny.secrets.allowedSources = ["keychain"]
        var environment = base
        environment.managed = .active(
            ManagedPolicyBundle(policy: deny, sha256: "", isSigned: false, directory: ""))
        let configuration = try SecretsRun.configuration(base).get()
        let report = SecretsRun.scan(root: fixture.directory, configuration: configuration, environment: environment)
        #expect(report.blocked == nil)
        #expect(report.skipped.contains { $0.contains("STRIPE_SECRET_KEY") && $0.contains("dotenv source") })
        #expect(report.findings.isEmpty)
        // A scan that could not check a secret must not pass the gate.
        #expect(report.failed)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", fixture.directory.path, "init", "-q"]
        try git.run()
        git.waitUntilExit()
        guard case .success(let hook) = SecretsRun.hookRun(workTree: fixture.directory, environment: environment) else {
            Issue.record("hook run must produce a report")
            return
        }
        #expect(hook.failed)
        #expect(hook.text.contains("could not check STRIPE_SECRET_KEY"))
    }

    @Test func checkAndDescribeRenderDotenvRows() throws {
        let (fixture, environment, _) = try self.fixture()
        defer { fixture.tearDown() }
        let configuration = try SecretsRun.configuration(environment).get()
        let rows = try SecretsRun.check(configuration, names: [], environment: environment).get()
        #expect(rows.count == 1)
        #expect(rows[0].ok)
        #expect(rows[0].source.contains("dotenv "))
        #expect(SecretsRun.checkText(rows).contains("sk-live-777") == false)
        let described = SecretsRun.describe(configuration)
        #expect(described.secrets.first?.source == "dotenv")
        #expect(SecretsRun.describeText(described).contains("STRIPE_SECRET_KEY  dotenv  environment"))
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
        #expect(ManagedRun.dotenvLine(state: .invalid("bad policy"), boundCount: 2)
            == "dotenv: organization policy invalid; secret staging disabled; 2 dotenv-bound secrets")
        #expect(ManagedRun.status(.invalid("bad policy"), directory: "/d", dotenvBoundCount: 2).dotenv != nil)
        #expect(ManagedRun.dotenvLine(state: deniedState, boundCount: 0) == nil)
        let status = ManagedRun.status(deniedState, directory: "/d", dotenvBoundCount: 2)
        #expect(ManagedRun.statusText(status).contains("dotenv: forbidden"))
        #expect(status.dotenv != nil)
    }
}
