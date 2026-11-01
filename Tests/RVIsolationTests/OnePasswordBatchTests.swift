import Foundation
import Testing
@testable import RVIsolation

/// A fake `op`: `read` prints `value-<field>`, `inject` replaces each
/// `{{ op://v/i/<field> }}` the same way. A reference whose item is
/// `missing` fails either way. Every call is logged to $HOME/calls.
private let fakeOp = #"""
    #!/bin/sh
    echo "$1" >> "$HOME/calls"
    case "$1" in
      read)
        case "$3" in *missing*) echo "[ERROR] could not find item" >&2; exit 1;; esac
        printf 'value-%s' "${3##*/}"
        ;;
      inject)
        input="$(cat)"
        case "$input" in *missing*) echo "[ERROR] could not find item" >&2; exit 1;; esac
        printf '%s' "$input" | sed -E 's#\{\{ op://[^}]*/([^/} ]+) \}\}#value-\1#g'
        ;;
      *) exit 2;;
    esac
    """#

@Suite("1Password op inject batching")
struct OnePasswordBatchTests {
    private func environment() throws -> [String: String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-op-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let op = directory.appendingPathComponent("op")
        try Data(fakeOp.utf8).write(to: op)
        chmod(op.path, 0o755)
        return ["PATH": "\(directory.path):/usr/bin:/bin", "HOME": directory.path]
    }

    private func calls(_ environment: [String: String]) -> [String] {
        let text = (try? String(contentsOfFile: environment["HOME"]! + "/calls", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    private func revealed(_ result: Result<SecretValue, SecretResolutionError>?) -> String? {
        guard case .success(let value) = result else { return nil }
        return String(decoding: value.revealed(), as: UTF8.self)
    }

    @Test func severalReferencesResolveInOneInject() throws {
        let environment = try environment()
        let results = SecretCommandProviders.onePasswordBatch(
            ["op://Eng/a/alpha", "op://Eng/b/beta", "op://Eng/c/gamma", "op://Eng/a/alpha"], environment: environment)
        #expect(revealed(results["op://Eng/a/alpha"]) == "value-alpha")
        #expect(revealed(results["op://Eng/b/beta"]) == "value-beta")
        #expect(revealed(results["op://Eng/c/gamma"]) == "value-gamma")
        #expect(calls(environment) == ["inject"])
    }

    @Test func aFailedBatchFallsBackToSingleReadsAndNamesTheBadReference() throws {
        let environment = try environment()
        let results = SecretCommandProviders.onePasswordBatch(
            ["op://Eng/a/alpha", "op://Eng/missing/beta"], environment: environment)
        #expect(revealed(results["op://Eng/a/alpha"]) == "value-alpha")
        guard case .failure(let error) = results["op://Eng/missing/beta"] else {
            Issue.record("bad reference resolved")
            return
        }
        #expect(error.message.contains("op://Eng/missing/beta"))
        #expect(calls(environment) == ["inject", "read", "read"])
    }

    @Test func oneReferenceUsesOpRead() throws {
        let environment = try environment()
        let results = SecretCommandProviders.onePasswordBatch(["op://Eng/a/alpha"], environment: environment)
        #expect(revealed(results["op://Eng/a/alpha"]) == "value-alpha")
        #expect(calls(environment) == ["read"])
    }

    @Test func parseKeepsMultiLineValuesAndIgnoresStrayText() {
        let inject = OnePasswordInject(references: ["op://v/i/one", "op://v/i/two"], separator: "__SEP__")
        #expect(String(decoding: inject.template, as: UTF8.self)
            == "RV_1P_0={{ op://v/i/one }}__SEP__RV_1P_1={{ op://v/i/two }}__SEP__")
        let parsed = inject.parse(Array("RV_1P_0=line1\nline2=x__SEP__RV_1P_1=b__SEP__\n".utf8))
        #expect(parsed["op://v/i/one"].map { String(decoding: $0, as: UTF8.self) } == "line1\nline2=x")
        #expect(parsed["op://v/i/two"].map { String(decoding: $0, as: UTF8.self) } == "b")
        #expect(parsed.count == 2)
    }

    @Test func liveResolverPrefetchBatchesOnlyOnePasswordSources() throws {
        let environment = try environment()
        let resolver = SecretResolver.live(environment: environment, home: environment["HOME"]!)
        let prefetched = resolver.prefetch([
            .onePassword(reference: "op://Eng/a/alpha"),
            .hostEnvironment(variable: "PATH"),
            .onePassword(reference: "op://Eng/b/beta"),
        ])
        #expect(Set(prefetched.keys) == [0, 2])
        #expect(revealed(prefetched[2]) == "value-beta")
        #expect(calls(environment) == ["inject"])
    }
}

extension OnePasswordBatchTests {
    @Test func launchLeaseResolvesOnePasswordSecretsInOneCall() throws {
        let environment = try environment()
        let fixture = try SecretsFixture("""
            {"version":1,"secrets":[
              {"name":"ALPHA","source":{"onePassword":{"reference":"op://Eng/a/alpha"}},"delivery":{"environment":{}}},
              {"name":"BETA","source":{"onePassword":{"reference":"op://Eng/b/beta"}},"delivery":{"environment":{}}},
              {"name":"BAD","source":{"onePassword":{"reference":"op://Eng/missing/gamma"}},"delivery":{"environment":{}}}
            ]}
            """)
        defer { fixture.tearDown() }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory,
            resolver: .live(environment: environment, home: environment["HOME"]!), workspace: nil)
        defer { broker.stop() }
        let lease = try broker.lease(names: ["ALPHA", "BETA"], agent: nil).get()
        #expect(lease.environment.map(\.name) == ["ALPHA", "BETA"])
        #expect(lease.environment.map(\.value) == ["value-alpha", "value-beta"])
        #expect(calls(environment) == ["inject"])

        guard case .failure(.resolution(secret: "BAD", _)) = broker.lease(names: ["ALPHA", "BAD"], agent: nil) else {
            Issue.record("the bad reference must be named")
            return
        }
    }
}
