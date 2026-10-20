#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVIsolation

@Suite("SecretsConfiguration")
struct SecretsConfigurationTests {
    private func decode(_ json: String) -> Result<SecretsConfiguration, SecretsConfigurationError> {
        SecretsConfiguration.decode(Data(json.utf8))
    }

    private func invalidReason(_ json: String) -> String? {
        guard case .failure(.invalid(let reason)) = decode(json) else { return nil }
        return reason
    }

    @Test func nonStringOptionalFieldsFailDecodeInsteadOfDefaulting() {
        // A numeric GCP version must not silently become "latest", and a
        // non-string placeholderPrefix must not silently become "".
        let gcp = #"{"version":1,"secrets":[{"name":"G","source":{"gcp":{"secret":"s","version":3}},"delivery":{"environment":{}}}]}"#
        #expect(invalidReason(gcp)?.contains("version") == true)
        let prefix = #"{"version":1,"secrets":[{"name":"G","source":{"hostEnvironment":{"variable":"G"}},"delivery":{"gateway":{"upstream":"https://a.example","baseURLEnv":"G_BASE","placeholderPrefix":7}}}]}"#
        #expect(invalidReason(prefix)?.contains("placeholderPrefix") == true)
        // Absent fields keep their defaults.
        let absent = #"{"version":1,"secrets":[{"name":"G","source":{"gcp":{"secret":"s"}},"delivery":{"environment":{}}}]}"#
        guard case .success(let configuration) = decode(absent),
            case .gcp(_, _, let version) = configuration.secrets.first?.source
        else {
            Issue.record("absent version must still default")
            return
        }
        #expect(version == "latest")
    }

    @Test func decodesEveryProviderAndDelivery() throws {
        let json = """
            {"version":1,"secrets":[
              {"name":"OPENAI_API_KEY","description":"model calls","agents":["codex"],
               "source":{"keychain":{"service":"rv.openai","account":"default"}},
               "delivery":{"gateway":{"upstream":"https://api.openai.com/","baseURLEnv":"OPENAI_BASE_URL",
                                      "placeholderPrefix":"sk-"}}},
              {"name":"GH_TOKEN","source":{"hostEnvironment":{"variable":"GH_TOKEN"}},"delivery":{"environment":{}}},
              {"name":"STRIPE_KEY","source":{"onePassword":{"reference":"op://Eng/Stripe/key"}},
               "delivery":{"gateway":{"upstream":"https://api.stripe.com/v1","baseURLEnv":"STRIPE_BASE"}}},
              {"name":"DB_PASSWORD","source":{"vault":{"path":"secret/data/db","field":"password",
                                                        "address":"https://vault.corp.example"}},
               "delivery":{"environment":{}}},
              {"name":"AWS_THING","source":{"awsSecretsManager":{"secretID":"prod/thing","field":"key",
                                                                   "region":"us-east-1"}},
               "delivery":{"environment":{}}}
            ]}
            """
        let configuration = try decode(json).get()
        #expect(configuration.secrets.map(\.name) == [
            "OPENAI_API_KEY", "GH_TOKEN", "STRIPE_KEY", "DB_PASSWORD", "AWS_THING",
        ])
        let openai = try #require(configuration.secret(named: "OPENAI_API_KEY"))
        #expect(openai.source == .keychain(service: "rv.openai", account: "default"))
        #expect(openai.agents == ["codex"])
        guard case .gateway(let binding) = openai.delivery else {
            Issue.record("expected gateway delivery")
            return
        }
        #expect(binding.upstream.absoluteString == "https://api.openai.com")
        #expect(binding.baseURLEnv == "OPENAI_BASE_URL")
        #expect(binding.placeholderPrefix == "sk-")
        #expect(openai.stages(forAgent: "codex"))
        #expect(openai.stages(forAgent: "claude") == false)
        #expect(openai.stages(forAgent: nil) == false)
        #expect(try #require(configuration.secret(named: "GH_TOKEN")).stages(forAgent: nil))
        #expect(configuration.secret(named: "DB_PASSWORD")?.source == .vault(
            path: "secret/data/db", field: "password", address: URL(string: "https://vault.corp.example")))
        #expect(configuration.secret(named: "AWS_THING")?.source == .awsSecretsManager(
            secretID: "prod/thing", field: "key", region: "us-east-1"))
    }

    @Test func refusesUnsafeOrAmbiguousDocuments() {
        let source = #"{"hostEnvironment":{"variable":"X"}}"#
        let env = #"{"environment":{}}"#
        #expect(invalidReason(#"{"version":2,"secrets":[]}"#) == "version must be 1")
        #expect(invalidReason(#"{"version":1,"secrets":[],"extra":1}"#) == "unknown key extra in document")
        #expect(invalidReason(
            #"{"version":1,"secrets":[{"name":"A","source":\#(source),"delivery":\#(env)},"#
                + #"{"name":"A","source":\#(source),"delivery":\#(env)}]}"#) == "duplicate secret A")
        #expect(invalidReason(#"{"version":1,"secrets":[{"name":"PATH","source":\#(source),"delivery":\#(env)}]}"#)
            == "secrets[0].name must be an environment variable name")
        #expect(invalidReason(#"{"version":1,"secrets":[{"name":"A","source":\#(source),"delivery":\#(env),"x":1}]}"#)
            == "unknown key x in secrets[0]")
        let collide = #"{"gateway":{"upstream":"https://a.example","baseURLEnv":"B"}}"#
        #expect(invalidReason(
            #"{"version":1,"secrets":[{"name":"A","source":\#(source),"delivery":\#(collide)},"#
                + #"{"name":"B","source":\#(source),"delivery":\#(env)}]}"#)
            == "B is exported by more than one secret")
    }

    @Test func gatewayUpstreamMustBeAPlainHTTPSOrigin() {
        func upstream(_ url: String) -> String? {
            invalidReason(
                #"{"version":1,"secrets":[{"name":"A","source":{"hostEnvironment":{"variable":"X"}},"#
                    + #""delivery":{"gateway":{"upstream":"\#(url)","baseURLEnv":"A_BASE"}}}]}"#)
        }
        let refusal = "A.delivery.gateway.upstream must be an https URL without credentials, query, or fragment"
        #expect(upstream("http://api.example.com") == refusal)
        #expect(upstream("https://user:pw@api.example.com") == refusal)
        #expect(upstream("https://api.example.com/?q=1") == refusal)
        #expect(upstream("https://api.example.com/#frag") == refusal)
        #expect(upstream("https://api.example.com/v1") == nil)
    }

    @Test func providerFieldsAreTypeChecked() {
        func source(_ body: String) -> String? {
            invalidReason(
                #"{"version":1,"secrets":[{"name":"A","source":\#(body),"delivery":{"environment":{}}}]}"#)
        }
        #expect(source(#"{"awsSecretsManager":{"secretID":"x","field":7}}"#)
            == "A.source.awsSecretsManager.field is invalid")
        #expect(source(#"{"awsSecretsManager":{"secretID":"x","region":"US EAST"}}"#)
            == "A.source.awsSecretsManager.region is invalid")
        #expect(source(#"{"awsSecretsManager":{"secretID":"--profile"}}"#)
            == "A.source.awsSecretsManager.secretID is required")
        #expect(source(#"{"onePassword":{"reference":"vault/item"}}"#)
            == "A.source.onePassword.reference must be an op:// reference")
        #expect(source(#"{"vault":{"path":"../etc","field":"f"}}"#) == "A.source.vault needs a KV path and field")
        #expect(source(#"{"vault":{"path":"a/b","field":"f","address":"http://vault"}}"#)
            == "A.source.vault.address must be an https URL")
        #expect(source(#"{"keychain":{"service":"s"}}"#) == "A.source.keychain needs service and account")
        #expect(source(#"{"keychain":{"service":"s","account":"a"},"hostEnvironment":{"variable":"X"}}"#)
            == "A.source must name exactly one kind")
    }

    @Test func loadTreatsMissingFileAsEmptyAndRefusesUnsafeFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SecretsConfiguration.load(configDirectory: directory) == .success(.empty))

        let file = SecretsConfiguration.fileURL(configDirectory: directory)
        try Data(#"{"version":1,"secrets":[]}"#.utf8).write(to: file)
        chmod(file.path, 0o600)
        #expect(SecretsConfiguration.load(configDirectory: directory) == .success(.empty))

        chmod(file.path, 0o666)
        #expect(SecretsConfiguration.load(configDirectory: directory)
            == .failure(.unsafeFile("group or world writable")))

        try FileManager.default.removeItem(at: file)
        let real = directory.appendingPathComponent("real.json")
        try Data(#"{"version":1,"secrets":[]}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
        #expect(SecretsConfiguration.load(configDirectory: directory) == .failure(.unsafeFile("symlink")))
    }

    @Test func unknownKeyAndSourceKindAreEscaped() {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let key = invalidReason("{\"version\":1,\"\\u202e\(sentence)\":true}")
        #expect(key?.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(key?.contains("\\u202e") == true)
        #expect(key?.contains("unknown key") == true)
        let kind = invalidReason(
            "{\"version\":1,\"secrets\":[{\"name\":\"TOKEN\",\"source\":{\"\\u001b[2J\\u001b[H\(sentence)\":{}},\"delivery\":{\"environment\":{}}}]}"
        )
        #expect(kind?.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(kind?.contains("\\u001b[2J") == true)
        #expect(kind?.contains("source kind") == true)
        let delivery = invalidReason(
            "{\"version\":1,\"secrets\":[{\"name\":\"TOKEN\",\"source\":{\"hostEnvironment\":{\"variable\":\"X\"}},\"delivery\":{\"\\u2029\(sentence)\":{}}}]}"
        )
        #expect(delivery?.unicodeScalars.contains { $0.value == 0x2029 } == false)
        #expect(delivery?.contains("\\u2029") == true)
        #expect(delivery?.contains("delivery kind") == true)
    }

    @Test func keychainAccountRejectsLineAndBidiScalars() {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let line = invalidReason(
            "{\"version\":1,\"secrets\":[{\"name\":\"TOKEN\",\"source\":{\"keychain\":{\"service\":\"rv.secrets\",\"account\":\"\\u2028\(sentence)\"}},\"delivery\":{\"environment\":{}}}]}"
        )
        #expect(line != nil)
        #expect(line?.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(line?.contains(sentence) == false)
        let reversed = invalidReason(
            "{\"version\":1,\"secrets\":[{\"name\":\"TOKEN\",\"source\":{\"keychain\":{\"service\":\"rv.secrets\",\"account\":\"\\u202e\(sentence)\"}},\"delivery\":{\"environment\":{}}}]}"
        )
        #expect(reversed != nil)
        #expect(reversed?.unicodeScalars.contains { $0.value == 0x202E } == false)
        let source = SecretSource.keychain(service: "rv.secrets", account: "\u{2028}" + sentence + "\u{202E}" + sentence)
        #expect(source.locator.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(source.locator.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(source.locator.contains("\\u2028"))
        #expect(source.locator.contains("\\u202e"))
        let stderr = Array(("\u{1B}[2J\u{1B}[H" + sentence + "\u{202E}" + sentence).utf8)
        let summary = BoundedProcess.Outcome(status: 1, stdout: [], stderr: stderr).stderrSummary
        #expect(summary.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(summary.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(summary.contains("\\u001b[2J"))
        #expect(summary.contains("\\u202e"))
        #expect(summary.contains("\\\\u001b") == false)
        guard case .failure(let missing) = SecretResolver.live(home: "/tmp").resolve(source) else {
            Issue.record("a missing keychain item was resolved")
            return
        }
        #expect(missing.message.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(missing.message.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(missing.message.contains("\\u2028"))
        #expect(missing.message.contains("not found: keychain item"))
    }
}
