#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVPolicy
import Testing
@testable import RVIsolation

/// Characterization pins for the secret definition's cross-field rules, written
/// against the decoder as it stands. They exist so a later restructuring of where
/// `refresh` and `binaries` live cannot change a message, an error's precedence,
/// or a byte of `secrets.json`.
@Suite("SecretDefinitionInvariants")
struct SecretDefinitionInvariantTests {
    private func reason(_ json: String) -> String? {
        guard case .failure(.invalid(let reason)) = SecretsConfiguration.decode(Data(json.utf8)) else { return nil }
        return reason
    }

    private func document(source: String, delivery: String, extra: String = "") -> String {
        #"{"version":1,"secrets":[{"name":"A","source":\#(source),"delivery":\#(delivery)\#(extra)}]}"#
    }

    private static let hostEnv = #"{"hostEnvironment":{"variable":"X"}}"#
    private static let profile = #"{"awsProfile":{"profile":"dev"}}"#
    private static let oauth =
        #"{"oauth":{"tokenURL":"https://auth.example.com/token","clientID":"id","refreshToken":{"service":"s","account":"a"}}}"#
    private static let environment = #"{"environment":{}}"#
    private static let gateway = #"{"gateway":{"upstream":"https://api.example.com","baseURLEnv":"A_BASE"}}"#
    private static let sigV4 =
        #"{"awsSigV4":{"upstream":"https://s3.us-east-1.amazonaws.com","region":"us-east-1","service":"s3","endpointEnv":"AWS_ENDPOINT_URL_S3"}}"#

    // MARK: exact strings

    @Test func awsProfileNeedsSigV4Delivery() {
        let message = "A.source.awsProfile needs awsSigV4 delivery"
        #expect(reason(document(source: Self.profile, delivery: Self.environment)) == message)
        #expect(reason(document(source: Self.profile, delivery: Self.gateway)) == message)
        #expect(reason(document(source: Self.profile, delivery: Self.sigV4)) == nil)
    }

    @Test func oauthNeedsGatewayDelivery() {
        let message = "A.source.oauth needs gateway delivery"
        #expect(reason(document(source: Self.oauth, delivery: Self.environment)) == message)
        #expect(reason(document(source: Self.oauth, delivery: Self.sigV4)) == message)
        #expect(reason(document(source: Self.oauth, delivery: Self.gateway)) == nil)
    }

    @Test func sigV4NeedsAnAwsProfileSource() {
        #expect(reason(document(source: Self.hostEnv, delivery: Self.sigV4))
            == "A.delivery.awsSigV4 needs an awsProfile source")
    }

    @Test func refreshAndBinariesAreRefusedOnEnvironmentDelivery() {
        let refresh = "A.refresh applies to gateway delivery; a value in the environment cannot change after launch"
        let binaries =
            "A.binaries applies to gateway delivery; rv cannot see which process reads an environment variable"
        #expect(reason(document(source: Self.hostEnv, delivery: Self.environment, extra: #","refresh":"15m""#)) == refresh)
        #expect(reason(document(
            source: Self.hostEnv, delivery: Self.environment, extra: #","binaries":["/usr/bin/curl"]"#)) == binaries)
    }

    @Test func gatewayDeliveriesAcceptRefreshAndBinaries() throws {
        let extra = #","refresh":"15m","binaries":["/usr/bin/curl"]"#
        for (source, delivery) in [(Self.hostEnv, Self.gateway), (Self.profile, Self.sigV4)] {
            let configuration = try SecretsConfiguration.decode(
                Data(document(source: source, delivery: delivery, extra: extra).utf8)).get()
            let secret = try #require(configuration.secret(named: "A"))
            #expect(secret.refresh?.text == "15m")
            #expect(secret.binaries == ["/usr/bin/curl"])
        }
    }

    // MARK: precedence

    @Test func theSourceDeliveryPairingIsCheckedBeforeExpiresRefreshAndBinaries() {
        let pairing = "A.source.awsProfile needs awsSigV4 delivery"
        let bad = #","expires":"soon","refresh":"10s","binaries":["relative"]"#
        #expect(reason(document(source: Self.profile, delivery: Self.environment, extra: bad)) == pairing)
        #expect(reason(document(source: Self.hostEnv, delivery: Self.sigV4, extra: bad))
            == "A.delivery.awsSigV4 needs an awsProfile source")
        #expect(reason(document(source: Self.oauth, delivery: Self.environment, extra: bad))
            == "A.source.oauth needs gateway delivery")
    }

    @Test func expiresIsCheckedBeforeRefresh() {
        let extra = #","expires":"soon","refresh":"15m""#
        #expect(reason(document(source: Self.hostEnv, delivery: Self.environment, extra: extra))
            == "A.expires must be an ISO-8601 date (2026-12-31) or date-time with a zone (2026-12-31T18:00:00Z)")
    }

    @Test func aBadRefreshGrammarBeatsTheEnvironmentRule() {
        #expect(reason(document(source: Self.hostEnv, delivery: Self.environment, extra: #","refresh":"10s""#))
            == "A.refresh must be a whole number of s, m, h, or d from 1m to 30d, such as 15m")
    }

    @Test func refreshOnEnvironmentBeatsABadBinariesList() {
        let extra = #","refresh":"15m","binaries":["relative"]"#
        #expect(reason(document(source: Self.hostEnv, delivery: Self.environment, extra: extra))
            == "A.refresh applies to gateway delivery; a value in the environment cannot change after launch")
    }

    @Test func aBadBinariesListBeatsTheEnvironmentRule() {
        #expect(reason(document(source: Self.hostEnv, delivery: Self.environment, extra: #","binaries":["relative"]"#))
            == "A.binaries must be 1 to 16 distinct absolute paths, such as /opt/homebrew/bin/gh")
    }

    // MARK: kind sync

    private static let samples: [SecretSource] = [
        .keychain(service: "svc", account: "acct"),
        .hostEnvironment(variable: "X"),
        .onePassword(reference: "op://Eng/Item/field"),
        .vault(path: "secret/data/db", field: "password", address: nil),
        .awsSecretsManager(secretID: "prod/thing", field: nil, region: nil),
        .infisical(name: "KEY", project: nil, environment: nil, path: nil),
        .bitwarden(id: "11111111-2222-3333-4444-555555555555"),
        .gcp(secret: "s", project: nil, version: "latest"),
        .azure(vault: "v", name: "n", version: nil),
        .awsProfile(profile: "dev"),
        .oauth(OAuthSource(
            tokenURL: URL(string: "https://auth.example.com/token")!, clientID: "id",
            refreshToken: SecretKeychainItem(service: "s", account: "a"))),
    ]

    /// No `default`: adding a `SecretSource` case stops this compiling until `samples` and the kind lists follow.
    private func index(_ source: SecretSource) -> Int {
        switch source {
        case .keychain: 0
        case .hostEnvironment: 1
        case .onePassword: 2
        case .vault: 3
        case .awsSecretsManager: 4
        case .infisical: 5
        case .bitwarden: 6
        case .gcp: 7
        case .azure: 8
        case .awsProfile: 9
        case .oauth: 10
        }
    }

    private func deliveryIndex(_ delivery: SecretDelivery) -> Int {
        switch delivery {
        case .gateway: 0
        case .environment: 1
        case .awsSigV4: 2
        }
    }

    private func delivery(for source: SecretSource) -> SecretDelivery {
        switch source {
        case .awsProfile:
            .awsSigV4(AWSSigningBinding(
                upstream: URL(string: "https://s3.us-east-1.amazonaws.com")!, region: "us-east-1", service: "s3",
                endpointEnv: "AWS_ENDPOINT_URL_S3"))
        case .oauth: .gateway(SecretGatewayBinding(upstream: URL(string: "https://api.example.com")!, baseURLEnv: "A_BASE"))
        default: .environment
        }
    }

    private func entry(_ configuration: SecretsConfiguration) throws -> [String: Any] {
        let object = try #require(try JSONSerialization.jsonObject(with: configuration.encoded()) as? [String: Any])
        let secrets = try #require(object["secrets"] as? [[String: Any]])
        return try #require(secrets.first)
    }

    @Test func everySourceCaseHasOneSampleAndTheKindListsAgree() {
        #expect(Self.samples.map(index) == Array(0..<11))
        let kinds = Self.samples.map(\.kind)
        #expect(kinds.count == 11)
        #expect(Set(kinds) == Set(ManagedPolicy.secretSourceKinds))
        #expect(Set(kinds).count == ManagedPolicy.secretSourceKinds.count)
    }

    @Test func everySourceKindRoundTripsUnderItsOwnKey() throws {
        for source in Self.samples {
            let configuration = SecretsConfiguration(secrets: [
                SecretDefinition(name: "A", source: source, delivery: delivery(for: source))
            ])
            let encoded = try entry(configuration)
            #expect((encoded["source"] as? [String: Any])?.keys.sorted() == [source.kind])
            #expect(try SecretsConfiguration.decode(configuration.encoded()).get() == configuration)
        }
    }

    @Test func everyDeliveryKindRoundTripsUnderItsOwnKey() throws {
        let deliveries = [
            delivery(for: .oauth(OAuthSource(tokenURL: URL(string: "https://a.example")!, clientID: "i"))),
            .environment,
            delivery(for: .awsProfile(profile: "dev")),
        ]
        #expect(deliveries.map(deliveryIndex) == [0, 1, 2])
        #expect(deliveries.map(\.kind) == ["gateway", "environment", "awsSigV4"])
        for delivery in deliveries {
            let source: SecretSource = switch delivery {
            case .gateway: Self.samples[10]
            case .environment: Self.samples[1]
            case .awsSigV4: Self.samples[9]
            }
            let configuration = SecretsConfiguration(secrets: [
                SecretDefinition(name: "A", source: source, delivery: delivery)
            ])
            #expect((try entry(configuration)["delivery"] as? [String: Any])?.keys.sorted() == [delivery.kind])
            #expect(try SecretsConfiguration.decode(configuration.encoded()).get() == configuration)
        }
    }

    // MARK: golden bytes

    private static let goldenInput = """
        {"version":1,"secrets":[
          {"name":"KEYCHAIN_KEY","description":"model calls","type":"apiKey","agents":["codex","claude"],
           "expires":"2027-03-01T12:30:00Z","refresh":"15m","binaries":["/usr/bin/curl","/opt/homebrew/bin/gh"],
           "source":{"keychain":{"service":"rv.secrets","account":"KEYCHAIN_KEY"}},
           "delivery":{"gateway":{"upstream":"https://api.example.com/v1/","baseURLEnv":"KEYCHAIN_BASE",
             "placeholderPrefix":"sk-","surfaces":["query","header"],
             "allow":["read-only",{"methods":["POST","GET"],"path":"/graphql"},{"methods":"*","path":"/v1/**"}],
             "approve":[{"methods":["DELETE"],"path":"/v1/**"}]}}},
          {"name":"HOST_ENV","expires":"2027-06-30","source":{"hostEnvironment":{"variable":"HOST_ENV"}},
           "delivery":{"environment":{}}},
          {"name":"ONEPASSWORD_KEY","refresh":"1h","source":{"onePassword":{"reference":"op://Eng/Stripe/key"}},
           "delivery":{"gateway":{"upstream":"https://api.stripe.com/v1","baseURLEnv":"STRIPE_BASE"}}},
          {"name":"VAULT_KEY","source":{"vault":{"path":"secret/data/db","field":"password",
             "address":"https://vault.corp.example"}},"delivery":{"environment":{}}},
          {"name":"AWSSM_KEY","source":{"awsSecretsManager":{"secretID":"prod/thing","field":"key","region":"us-east-1"}},
           "delivery":{"environment":{}}},
          {"name":"INFISICAL_KEY","source":{"infisical":{"name":"KEY","project":"proj","environment":"prod","path":"/app"}},
           "delivery":{"environment":{}}},
          {"name":"BITWARDEN_KEY","source":{"bitwarden":{"id":"11111111-2222-3333-4444-555555555555"}},
           "delivery":{"environment":{}}},
          {"name":"GCP_KEY","source":{"gcp":{"secret":"s","project":"p","version":"3"}},"delivery":{"environment":{}}},
          {"name":"AZURE_KEY","source":{"azure":{"vault":"v","name":"n","version":"abc"}},"delivery":{"environment":{}}},
          {"name":"AWS_PROFILE_KEY","refresh":"1h","binaries":["/usr/local/bin/aws"],
           "source":{"awsProfile":{"profile":"dev"}},
           "delivery":{"awsSigV4":{"upstream":"https://s3.us-east-1.amazonaws.com","region":"us-east-1","service":"s3",
             "endpointEnv":"AWS_ENDPOINT_URL_S3","allow":["read-only"],"approve":[{"methods":["PUT"],"path":"/**"}]}}},
          {"name":"OAUTH_KEY","source":{"oauth":{"tokenURL":"https://auth.example.com/oauth/token","clientID":"client-1",
             "clientSecret":{"service":"rv.oauth","account":"secret"},
             "refreshToken":{"service":"rv.oauth","account":"refresh"},"scope":"read write"}},
           "delivery":{"gateway":{"upstream":"https://api.example.com","baseURLEnv":"OAUTH_BASE"}}}
        ]}
        """

    private func goldenConfiguration() throws -> SecretsConfiguration {
        try SecretsConfiguration.decode(Data(Self.goldenInput.utf8)).get()
    }

    @Test func theGoldenConfigurationCoversEverySourceAndDelivery() throws {
        let secrets = try goldenConfiguration().secrets
        #expect(secrets.map(\.source).map(index).sorted() == Array(0..<11))
        #expect(Set(secrets.map(\.delivery).map(deliveryIndex)) == [0, 1, 2])
        #expect(secrets.compactMap(\.refresh).count == 3)
        #expect(secrets.compactMap(\.binaries).count == 2)
        #expect(secrets.compactMap(\.expires).count == 2)
    }

    @Test func theGoldenConfigurationRoundTripsThroughEncodeAndDecode() throws {
        let configuration = try goldenConfiguration()
        #expect(try SecretsConfiguration.decode(configuration.encoded()).get() == configuration)
        #expect(try SecretsConfiguration.decode(configuration.encoded()).get().encoded() == configuration.encoded())
    }

    private static let goldenEncoded = #"""
    {
      "secrets" : [
        {
          "agents" : [
            "codex",
            "claude"
          ],
          "binaries" : [
            "/usr/bin/curl",
            "/opt/homebrew/bin/gh"
          ],
          "delivery" : {
            "gateway" : {
              "allow" : [
                "read-only",
                {
                  "methods" : [
                    "GET",
                    "POST"
                  ],
                  "path" : "/graphql"
                },
                {
                  "methods" : "*",
                  "path" : "/v1/**"
                }
              ],
              "approve" : [
                {
                  "methods" : [
                    "DELETE"
                  ],
                  "path" : "/v1/**"
                }
              ],
              "baseURLEnv" : "KEYCHAIN_BASE",
              "placeholderPrefix" : "sk-",
              "surfaces" : [
                "header",
                "query"
              ],
              "upstream" : "https://api.example.com/v1"
            }
          },
          "description" : "model calls",
          "expires" : "2027-03-01T12:30:00Z",
          "name" : "KEYCHAIN_KEY",
          "refresh" : "15m",
          "source" : {
            "keychain" : {
              "account" : "KEYCHAIN_KEY",
              "service" : "rv.secrets"
            }
          },
          "type" : "apiKey"
        },
        {
          "delivery" : {
            "environment" : {

            }
          },
          "expires" : "2027-06-30",
          "name" : "HOST_ENV",
          "source" : {
            "hostEnvironment" : {
              "variable" : "HOST_ENV"
            }
          }
        },
        {
          "delivery" : {
            "gateway" : {
              "baseURLEnv" : "STRIPE_BASE",
              "upstream" : "https://api.stripe.com/v1"
            }
          },
          "name" : "ONEPASSWORD_KEY",
          "refresh" : "1h",
          "source" : {
            "onePassword" : {
              "reference" : "op://Eng/Stripe/key"
            }
          }
        },
        {
          "delivery" : {
            "environment" : {

            }
          },
          "name" : "VAULT_KEY",
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
          "name" : "AWSSM_KEY",
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
          "name" : "INFISICAL_KEY",
          "source" : {
            "infisical" : {
              "environment" : "prod",
              "name" : "KEY",
              "path" : "/app",
              "project" : "proj"
            }
          }
        },
        {
          "delivery" : {
            "environment" : {

            }
          },
          "name" : "BITWARDEN_KEY",
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
          "name" : "GCP_KEY",
          "source" : {
            "gcp" : {
              "project" : "p",
              "secret" : "s",
              "version" : "3"
            }
          }
        },
        {
          "delivery" : {
            "environment" : {

            }
          },
          "name" : "AZURE_KEY",
          "source" : {
            "azure" : {
              "name" : "n",
              "vault" : "v",
              "version" : "abc"
            }
          }
        },
        {
          "binaries" : [
            "/usr/local/bin/aws"
          ],
          "delivery" : {
            "awsSigV4" : {
              "allow" : [
                "read-only"
              ],
              "approve" : [
                {
                  "methods" : [
                    "PUT"
                  ],
                  "path" : "/**"
                }
              ],
              "endpointEnv" : "AWS_ENDPOINT_URL_S3",
              "region" : "us-east-1",
              "service" : "s3",
              "upstream" : "https://s3.us-east-1.amazonaws.com"
            }
          },
          "name" : "AWS_PROFILE_KEY",
          "refresh" : "1h",
          "source" : {
            "awsProfile" : {
              "profile" : "dev"
            }
          }
        },
        {
          "delivery" : {
            "gateway" : {
              "baseURLEnv" : "OAUTH_BASE",
              "upstream" : "https://api.example.com"
            }
          },
          "name" : "OAUTH_KEY",
          "source" : {
            "oauth" : {
              "clientID" : "client-1",
              "clientSecret" : {
                "account" : "secret",
                "service" : "rv.oauth"
              },
              "refreshToken" : {
                "account" : "refresh",
                "service" : "rv.oauth"
              },
              "scope" : "read write",
              "tokenURL" : "https://auth.example.com/oauth/token"
            }
          }
        }
      ],
      "version" : 1
    }

    """#

    #if canImport(Darwin)
    /// Darwin Foundation's pretty printer; swift-corelibs output is not verified identical.
    @Test func encodedBytesAreStable() throws {
        let text = String(decoding: try goldenConfiguration().encoded(), as: UTF8.self)
        #expect(text == Self.goldenEncoded)
    }
    #endif
}
