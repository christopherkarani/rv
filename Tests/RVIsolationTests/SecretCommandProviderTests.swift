import Foundation
import Testing
@testable import RVIsolation

@Suite("Secret provider CLIs")
struct SecretCommandProviderTests {
    private func fake(_ name: String, body: String) throws -> [String: String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        chmod(url.path, 0o755)
        return ["PATH": directory.path, "HOME": directory.path]
    }

    @Test func infisicalBitwardenGcpAndAzure() throws {
        let secret = "provider-secret-value"
        let infisical = try fake("infisical", body: """
            #!/bin/sh
            printf '%s\\n' "$*" > "$HOME/args"
            printf '%s' '\(secret)'
            """)
        let read = SecretCommandProviders.infisical(
            name: "DATABASE_URL", project: "proj", environmentName: "dev", path: "/", environment: infisical)
        guard case .success(let value) = read else {
            Issue.record("infisical did not resolve")
            return
        }
        #expect(value.revealed() == Array(secret.utf8))
        #expect(String(describing: value) == "<redacted>")
        let args = try String(contentsOf: URL(fileURLWithPath: infisical["HOME"]!).appendingPathComponent("args"), encoding: .utf8)
        #expect(args == "secrets get DATABASE_URL --plain --silent --projectId proj --env dev --path /\n")
        #expect(args.contains(secret) == false)

        let bws = try fake("bws", body: """
            #!/bin/sh
            printf '%s' '{"id":"abc","value":"\(secret)","key":"DB"}'
            """)
        guard case .success(let bw) = SecretCommandProviders.bitwarden(
            id: "12345678-1234-1234-1234-123456789abc", environment: bws)
        else {
            Issue.record("bws did not resolve")
            return
        }
        #expect(bw.revealed() == Array(secret.utf8))

        let gcloud = try fake("gcloud", body: "#!/bin/sh\nprintf '%s' '\(secret)'\n")
        guard case .success = SecretCommandProviders.gcp(secret: "api-key", project: "my-project", version: "5", environment: gcloud)
        else {
            Issue.record("gcloud did not resolve")
            return
        }

        let az = try fake("az", body: "#!/bin/sh\nprintf '%s' '\(secret)'\n")
        guard case .success = SecretCommandProviders.azure(vault: "my-vault", name: "db", version: nil, environment: az) else {
            Issue.record("az did not resolve")
            return
        }
    }

    @Test func failuresAreTypedAndNeverIncludeTheOutput() throws {
        let missing = SecretCommandProviders.infisical(
            name: "X", project: nil, environmentName: nil, path: nil, environment: ["PATH": "/nope", "HOME": "/tmp"])
        guard case .failure(let unavailable) = missing else {
            Issue.record("missing CLI was accepted")
            return
        }
        #expect(unavailable.message.contains("not installed"))

        let broken = try fake("bws", body: "#!/bin/sh\nprintf '%s' 'super-secret-blob'\nexit 2\n")
        guard case .failure(let failed) = SecretCommandProviders.bitwarden(id: "12345678-1234-1234-1234-123456789abc", environment: broken)
        else {
            Issue.record("failing bws was accepted")
            return
        }
        #expect(failed.message.contains("exited 2"))
        #expect(failed.message.contains("super-secret-blob") == false)

        let shaped = try fake("bws", body: "#!/bin/sh\nprintf '%s' 'super-secret-blob'\n")
        guard case .failure(let shape) = SecretCommandProviders.bitwarden(id: "12345678-1234-1234-1234-123456789abc", environment: shaped)
        else {
            Issue.record("plain bws output was accepted")
            return
        }
        #expect(shape.message.contains("did not return a usable value"))
        #expect(shape.message.contains("super-secret-blob") == false)
    }

    @Test func commandOutputStopsAtOneMebibyteAndTheDeadlineIsHonored() throws {
        var huge = try fake("bws", body: "#!/bin/sh\npython3 -c 'print(\"a\" * 1100000, end=\"\")'\n")
        huge["PATH"] = "\(huge["PATH"]!):/usr/bin:/bin"
        guard case .failure(let oversized) = SecretCommandProviders.bitwarden(
            id: "12345678-1234-1234-1234-123456789abc", environment: huge)
        else {
            Issue.record("oversized output was accepted")
            return
        }
        #expect(oversized.message.contains("1 MiB") || oversized.message.contains("did not return"))
        #expect(BoundedProcess.run("/bin/sleep", ["2"], environment: [:], timeout: 0.2) == nil)
    }
}

/// Opt in per provider. Each test checks that a real CLI returns a value and
/// that the value's description stays redacted. Nothing prints the value.
@Suite("Live secret provider CLIs")
struct LiveSecretProviderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RV_LIVE_INFISICAL"] == "1"))
    func infisical() {
        let env = ProcessInfo.processInfo.environment
        let result = SecretCommandProviders.infisical(
            name: env["RV_LIVE_INFISICAL_SECRET"] ?? "", project: env["RV_LIVE_INFISICAL_PROJECT"],
            environmentName: env["RV_LIVE_INFISICAL_ENV"], path: env["RV_LIVE_INFISICAL_PATH"], environment: env)
        guard case .success(let value) = result else { Issue.record("infisical did not resolve"); return }
        #expect(String(describing: value) == "<redacted>")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RV_LIVE_BWS"] == "1"))
    func bitwarden() {
        let env = ProcessInfo.processInfo.environment
        let result = SecretCommandProviders.bitwarden(id: env["RV_LIVE_BWS_ID"] ?? "", environment: env)
        guard case .success(let value) = result else { Issue.record("bws did not resolve"); return }
        #expect(String(describing: value) == "<redacted>")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RV_LIVE_GCP"] == "1"))
    func gcp() {
        let env = ProcessInfo.processInfo.environment
        let result = SecretCommandProviders.gcp(
            secret: env["RV_LIVE_GCP_SECRET"] ?? "", project: env["RV_LIVE_GCP_PROJECT"],
            version: env["RV_LIVE_GCP_VERSION"] ?? "latest", environment: env)
        guard case .success(let value) = result else { Issue.record("gcloud did not resolve"); return }
        #expect(String(describing: value) == "<redacted>")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RV_LIVE_AZURE"] == "1"))
    func azure() {
        let env = ProcessInfo.processInfo.environment
        let result = SecretCommandProviders.azure(
            vault: env["RV_LIVE_AZURE_VAULT"] ?? "", name: env["RV_LIVE_AZURE_SECRET"] ?? "",
            version: env["RV_LIVE_AZURE_VERSION"], environment: env)
        guard case .success(let value) = result else { Issue.record("az did not resolve"); return }
        #expect(String(describing: value) == "<redacted>")
    }
}
