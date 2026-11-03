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

    private static let everySourceJSON = """
        {"version":1,"secrets":[
          {"name":"S_KEYCHAIN","source":{"keychain":{"service":"svc","account":"acct"}},"delivery":{"environment":{}}},
          {"name":"S_HOST","source":{"hostEnvironment":{"variable":"HOST_VAR"}},"delivery":{"environment":{}}},
          {"name":"S_OP","source":{"onePassword":{"reference":"op://Eng/Item/key"}},"delivery":{"environment":{}}},
          {"name":"S_VAULT","source":{"vault":{"path":"secret/data/db","field":"password","address":"https://vault.corp.example"}},"delivery":{"environment":{}}},
          {"name":"S_AWSSM","source":{"awsSecretsManager":{"secretID":"prod/thing","field":"key","region":"us-east-1"}},"delivery":{"environment":{}}},
          {"name":"S_INFISICAL","source":{"infisical":{"name":"KEY","project":"proj","environment":"dev","path":"/"}},"delivery":{"environment":{}}},
          {"name":"S_BITWARDEN","source":{"bitwarden":{"id":"11111111-2222-3333-4444-555555555555"}},"delivery":{"environment":{}}},
          {"name":"S_GCP","source":{"gcp":{"secret":"sec","project":"proj","version":"3"}},"delivery":{"environment":{}}},
          {"name":"S_AZURE","source":{"azure":{"vault":"v","name":"n","version":"abc"}},"delivery":{"environment":{}}},
          {"name":"S_AWSPROFILE","source":{"awsProfile":{"profile":"dev"}},"delivery":{"awsSigV4":{"upstream":"https://s3.us-east-1.amazonaws.com","region":"us-east-1","service":"s3","endpointEnv":"AWS_ENDPOINT_URL_S3"}}},
          {"name":"S_OAUTH","source":{"oauth":{"tokenURL":"https://auth.example.com/token","clientID":"cid","refreshToken":{"service":"rv.oauth","account":"refresh"}}},"delivery":{"gateway":{"upstream":"https://api.example.com/","baseURLEnv":"EX_BASE"}}}
        ]}
        """

    @Test func everySourceKindEncodesToPinnedBytesAndRoundTrips() throws {
        let configuration = try decode(Self.everySourceJSON).get()
        #expect(configuration.secrets.map { "\($0.source.kind)" } == [
            "keychain", "hostEnvironment", "onePassword", "vault", "awsSecretsManager", "infisical", "bitwarden",
            "gcp", "azure", "awsProfile", "oauth",
        ])
        let encoded = String(decoding: configuration.encoded(), as: UTF8.self)
        #expect(encoded == Self.everySourceEncoded)
        #expect(try SecretsConfiguration.decode(configuration.encoded()).get() == configuration)
    }

    @Test func unknownSourceKindStaysUnsupported() {
        let json = #"{"version":1,"secrets":[{"name":"X","source":{"keychian":{"service":"s","account":"a"}},"delivery":{"environment":{}}}]}"#
        #expect(invalidReason(json) == "X.source kind keychian is not supported")
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

    private func gatewayJSON(_ extra: String) -> String {
        #"{"version":1,"secrets":[{"name":"A","source":{"hostEnvironment":{"variable":"X"}},"#
            + #""delivery":{"gateway":{"upstream":"https://api.example.com","baseURLEnv":"A_BASE"\#(extra)}}}]}"#
    }

    private func binding(_ json: String) throws -> SecretGatewayBinding {
        let secret = try #require(try decode(json).get().secret(named: "A"))
        guard case .gateway(let binding) = secret.delivery else { throw SecretsDecoding.Failure("not a gateway") }
        return binding
    }

    @Test func gatewaySurfacesDefaultToHeaderAndRoundTrip() throws {
        #expect(try binding(gatewayJSON("")).surfaces == [.header])
        let opened = try binding(gatewayJSON(#","surfaces":["query","header"]"#))
        #expect(opened.surfaces == [.header, .query])

        let configuration = try decode(gatewayJSON(#","surfaces":["path"]"#)).get()
        let encoded = String(decoding: configuration.encoded(), as: UTF8.self)
        #expect(encoded.contains(#""surfaces" : ["#))
        #expect(try SecretsConfiguration.decode(configuration.encoded()).get() == configuration)
        let plain = String(decoding: try decode(gatewayJSON("")).get().encoded(), as: UTF8.self)
        #expect(plain.contains("surfaces") == false)
    }

    @Test func gatewaySurfacesAreStrict() {
        let refusal = "A.delivery.gateway.surfaces must list distinct surfaces from header, query, path"
        #expect(invalidReason(gatewayJSON(#","surfaces":[]"#)) == refusal)
        #expect(invalidReason(gatewayJSON(#","surfaces":["body"]"#)) == refusal)
        #expect(invalidReason(gatewayJSON(#","surfaces":["header","header"]"#)) == refusal)
        #expect(invalidReason(gatewayJSON(#","surfaces":"header""#)) == refusal)
        #expect(invalidReason(gatewayJSON(#","surfaces":["Header"]"#)) == refusal)
    }

    @Test func gatewayAllowRulesDecodeExpandAndRoundTrip() throws {
        #expect(try binding(gatewayJSON("")).allow.isEmpty)
        let json = gatewayJSON(
            #","allow":["github-clone",{"methods":["POST","GET"],"path":"/graphql"},{"methods":"*","path":"/v1/**"}]"#)
        let scoped = try binding(json)
        #expect(scoped.allow == [
            .preset(.githubClone),
            .rule(try #require(GatewayAccessRule(methods: ["GET", "POST"], path: "/graphql"))),
            .rule(try #require(GatewayAccessRule(methods: nil, path: "/v1/**"))),
        ])
        #expect(scoped.rules.count == 4)
        let configuration = try decode(json).get()
        let encoded = String(decoding: configuration.encoded(), as: UTF8.self)
        #expect(encoded.contains(#""github-clone""#))
        #expect(try SecretsConfiguration.decode(configuration.encoded()).get() == configuration)
        let plain = String(decoding: try decode(gatewayJSON("")).get().encoded(), as: UTF8.self)
        #expect(plain.contains("allow") == false)
    }

    @Test func gatewayAllowRulesAreStrict() {
        let place = "A.delivery.gateway.allow"
        let methods = "\(place)[0].methods must be \"*\" or a list of distinct upper-case HTTP methods"
        let path = "\(place)[0].path must be a /-rooted glob without . or .. segments, //, %, ?, #, ;, or \\, "
            + "and at most two **"
        #expect(invalidReason(gatewayJSON(#","allow":[]"#)) == "\(place) must list 1 to 32 presets or rules")
        #expect(invalidReason(gatewayJSON(#","allow":"read-only""#)) == "\(place) must list 1 to 32 presets or rules")
        #expect(invalidReason(gatewayJSON(#","allow":["write-all"]"#))
            == "\(place)[0] preset write-all is unknown; use read-only, github-clone, github-read")
        #expect(invalidReason(gatewayJSON(#","allow":[7]"#)) == "\(place)[0] must be a preset name or {methods, path}")
        #expect(invalidReason(gatewayJSON(#","allow":[{"methods":"*","path":"/x","query":{}}]"#))
            == "unknown key query in \(place)[0]")
        #expect(invalidReason(gatewayJSON(#","allow":[{"methods":["get"],"path":"/x"}]"#)) == methods)
        #expect(invalidReason(gatewayJSON(#","allow":[{"methods":[],"path":"/x"}]"#)) == methods)
        #expect(invalidReason(gatewayJSON(#","allow":[{"methods":["GET","GET"],"path":"/x"}]"#)) == methods)
        #expect(invalidReason(gatewayJSON(#","allow":[{"methods":"GET","path":"/x"}]"#)) == methods)
        #expect(invalidReason(gatewayJSON(#","allow":[{"methods":"*"}]"#)) == "\(place)[0].path must be a /-rooted glob")
        for bad in ["x", "/a/../b", "/a/./b", "/a//b", "/a%2fb", "/a?b", "/a#b", "/a\\\\b", "/a;b", "/a**", "/**/**/**"] {
            #expect(invalidReason(gatewayJSON(#","allow":[{"methods":"*","path":"\#(bad)"}]"#)) == path, "\(bad)")
        }
    }

    private func lifetimeJSON(_ fields: String, delivery: String = #"{"gateway":{"upstream":"https://api.example.com","baseURLEnv":"A_BASE"}}"#) -> String {
        #"{"version":1,"secrets":[{"name":"A","source":{"hostEnvironment":{"variable":"X"}},"delivery":"#
            + delivery + fields + "}]}"
    }

    @Test func expiryAndRefreshDecodeAndRoundTrip() throws {
        let plain = try #require(try decode(lifetimeJSON("")).get().secret(named: "A"))
        #expect(plain.expires == nil)
        #expect(plain.refresh == nil)

        let dated = try decode(lifetimeJSON(#","expires":"2026-12-31","refresh":"15m""#)).get()
        let secret = try #require(dated.secret(named: "A"))
        #expect(secret.expires == Date(timeIntervalSince1970: 1_798_675_200))
        #expect(secret.refresh?.seconds == 900)
        let encoded = String(decoding: dated.encoded(), as: UTF8.self)
        #expect(encoded.contains(#""expires" : "2026-12-31""#))
        #expect(encoded.contains(#""refresh" : "15m""#))
        #expect(try SecretsConfiguration.decode(dated.encoded()).get() == dated)

        let timed = try decode(lifetimeJSON(#","expires":"2026-12-31T12:30:00+02:00","refresh":"2h""#)).get()
        #expect(timed.secret(named: "A")?.expires == Date(timeIntervalSince1970: 1_798_713_000))
        let timedText = String(decoding: timed.encoded(), as: UTF8.self)
        #expect(timedText.contains(#""expires" : "2026-12-31T10:30:00Z""#))
        #expect(timedText.contains(#""refresh" : "2h""#))
        #expect(try SecretsConfiguration.decode(timed.encoded()).get() == timed)

        let environment = try decode(lifetimeJSON(#","expires":"2027-01-01T00:00:00Z""#, delivery: #"{"environment":{}}"#)).get()
        #expect(environment.secret(named: "A")?.expires == Date(timeIntervalSince1970: 1_798_761_600))
        #expect(String(decoding: environment.encoded(), as: UTF8.self).contains(#""expires" : "2027-01-01""#))
        #expect(String(decoding: try decode(lifetimeJSON("")).get().encoded(), as: UTF8.self).contains("expires") == false)
    }

    @Test func expiryAndRefreshAreStrict() {
        let expires = "A.expires must be an ISO-8601 date (2026-12-31) or date-time with a zone (2026-12-31T18:00:00Z)"
        for bad in [
            "2026-12-31T18:00:00", "2026-13-01", "2026-02-30", "31-12-2026", "2026-12-31 18:00:00Z", "tomorrow", "",
            "2026-12-31T18:00Z", "2026-12-31T18:00:00.5Z", "2026-12-31T25:00:00Z", " 2026-12-31",
        ] {
            #expect(invalidReason(lifetimeJSON(#","expires":"\#(bad)""#)) == expires, "\(bad)")
        }
        #expect(invalidReason(lifetimeJSON(#","expires":20261231"#)) == expires)
        let refresh = "A.refresh must be a whole number of s, m, h, or d from 1m to 30d, such as 15m"
        for bad in ["30s", "59s", "0m", "15", "15M", "1.5h", "m", "-5m", "31d", "15 m", "0015m", ""] {
            #expect(invalidReason(lifetimeJSON(#","refresh":"\#(bad)""#)) == refresh, "\(bad)")
        }
        #expect(invalidReason(lifetimeJSON(#","refresh":900"#)) == refresh)
        #expect(invalidReason(lifetimeJSON(#","refresh":"15m""#, delivery: #"{"environment":{}}"#))
            == "A.refresh applies to gateway delivery; a value in the environment cannot change after launch")
    }

    @Test func refreshIntervalsParseAndPrint() {
        #expect(SecretRefreshInterval("60s")?.seconds == 60)
        #expect(SecretRefreshInterval("90s")?.text == "90s")
        #expect(SecretRefreshInterval("120s")?.text == "2m")
        #expect(SecretRefreshInterval("60m")?.text == "1h")
        #expect(SecretRefreshInterval("48h")?.text == "2d")
        #expect(SecretRefreshInterval("30d")?.seconds == 2_592_000)
        #expect(SecretRefreshInterval("59s") == nil)
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

extension SecretsConfigurationTests {
    /// secrets.json bytes for one definition per source kind; the file format is a contract.
    static let everySourceEncoded = #"""
    {
      "secrets" : [
        {
          "delivery" : {
            "environment" : {

            }
          },
          "name" : "S_KEYCHAIN",
          "source" : {
            "keychain" : {
              "account" : "acct",
              "service" : "svc"
            }
          }
        },
        {
          "delivery" : {
            "environment" : {

            }
          },
          "name" : "S_HOST",
          "source" : {
            "hostEnvironment" : {
              "variable" : "HOST_VAR"
            }
          }
        },
        {
          "delivery" : {
            "environment" : {

            }
          },
          "name" : "S_OP",
          "source" : {
            "onePassword" : {
              "reference" : "op://Eng/Item/key"
            }
          }
        },
        {
          "delivery" : {
            "environment" : {

            }
          },
          "name" : "S_VAULT",
          "source" : {
            "vault" : {
              "address" : "https://vault.corp.example",
              "field" : "password",
              "path" : "secret/data/db"
            }
          }
        },
        {
          "delivery" : {
            "environment" : {

            }
          },
          "name" : "S_AWSSM",
          "source" : {
            "awsSecretsManager" : {
              "field" : "key",
              "region" : "us-east-1",
              "secretID" : "prod/thing"
            }
          }
        },
        {
          "delivery" : {
            "environment" : {

            }
          },
          "name" : "S_INFISICAL",
          "source" : {
            "infisical" : {
              "environment" : "dev",
              "name" : "KEY",
              "path" : "/",
              "project" : "proj"
            }
          }
        },
        {
          "delivery" : {
            "environment" : {

            }
          },
          "name" : "S_BITWARDEN",
          "source" : {
            "bitwarden" : {
              "id" : "11111111-2222-3333-4444-555555555555"
            }
          }
        },
        {
          "delivery" : {
            "environment" : {

            }
          },
          "name" : "S_GCP",
          "source" : {
            "gcp" : {
              "project" : "proj",
              "secret" : "sec",
              "version" : "3"
            }
          }
        },
        {
          "delivery" : {
            "environment" : {

            }
          },
          "name" : "S_AZURE",
          "source" : {
            "azure" : {
              "name" : "n",
              "vault" : "v",
              "version" : "abc"
            }
          }
        },
        {
          "delivery" : {
            "awsSigV4" : {
              "endpointEnv" : "AWS_ENDPOINT_URL_S3",
              "region" : "us-east-1",
              "service" : "s3",
              "upstream" : "https://s3.us-east-1.amazonaws.com"
            }
          },
          "name" : "S_AWSPROFILE",
          "source" : {
            "awsProfile" : {
              "profile" : "dev"
            }
          }
        },
        {
          "delivery" : {
            "gateway" : {
              "baseURLEnv" : "EX_BASE",
              "upstream" : "https://api.example.com"
            }
          },
          "name" : "S_OAUTH",
          "source" : {
            "oauth" : {
              "clientID" : "cid",
              "refreshToken" : {
                "account" : "refresh",
                "service" : "rv.oauth"
              },
              "tokenURL" : "https://auth.example.com/token"
            }
          }
        }
      ],
      "version" : 1
    }
    """# + "\n"
}
