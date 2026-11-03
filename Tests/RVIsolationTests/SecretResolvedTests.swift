import Foundation
import Synchronization
import Testing
@testable import RVIsolation

/// `ResolvedSecret`: a secret is parsed once, at the resolver adapter, into
/// the kind its definition calls for, and only a lasting token is text.
@Suite("Resolved secret")
struct SecretResolvedTests {
    static let awsJSON = SecretGatewayAWSTests.credentials(expires: Date(timeIntervalSince1970: 1_800_003_600))
    static let oauthJSON = String(
        decoding: Data(
            #"{"access_token":"at-REAL-oauth-token-0001","expires_at":1800003600}"#.utf8), as: UTF8.self)

    private func definition(_ json: String, _ name: String) throws -> SecretDefinition {
        let configuration = try SecretsConfiguration.decode(Data(json.utf8)).get()
        return try #require(configuration.secret(named: name))
    }

    private var aws: SecretDefinition {
        get throws { try definition(SecretGatewayAWSTests.secretsJSON(), "AWS_DEV") }
    }

    private var oauth: SecretDefinition {
        get throws { try definition(SecretOAuthTests.secretsJSON, "GH") }
    }

    private var token: SecretDefinition {
        get throws {
            try definition(
                #"{"version":1,"secrets":[{"name":"TOK","source":{"hostEnvironment":{"variable":"X"}},"delivery":{"environment":{}}}]}"#,
                "TOK")
        }
    }

    @Test func eachSourceParsesIntoItsOwnKind() throws {
        guard case .token(let plain)? = ResolvedSecret.parse(SecretValue("plain-value")!, for: try token) else {
            Issue.record("a host variable was not a token")
            return
        }
        #expect(plain == SecretValue("plain-value"))
        guard case .awsCredentials(let set)? = ResolvedSecret.parse(SecretValue(Self.awsJSON)!, for: try aws) else {
            Issue.record("an awsProfile source was not a credential set")
            return
        }
        #expect(set.accessKeyID == SecretValue(SecretGatewayAWSTests.realKey))
        guard case .oauth(let minted)? = ResolvedSecret.parse(SecretValue(Self.oauthJSON)!, for: try oauth) else {
            Issue.record("an oauth source was not an access token")
            return
        }
        #expect(minted.token == SecretValue("at-REAL-oauth-token-0001"))
    }

    @Test func unusableGatewayOnlyValuesDoNotParse() throws {
        #expect(ResolvedSecret.parse(SecretValue("not json")!, for: try aws) == nil)
        #expect(ResolvedSecret.parse(SecretValue("not json")!, for: try oauth) == nil)
        #expect(try aws.credentialParts(SecretValue("not json")!) == nil)
    }

    @Test func onlyALastingTokenIsText() throws {
        let value = SecretValue("plain-value")!
        #expect(ResolvedSecret.token(value).lastingToken == value)
        #expect(ResolvedSecret.parse(SecretValue(Self.awsJSON)!, for: try aws)?.lastingToken == nil)
        #expect(ResolvedSecret.parse(SecretValue(Self.oauthJSON)!, for: try oauth)?.lastingToken == nil)
    }

    @Test func aGatewayOnlySourceIsNeverATokenWhateverItsDelivery() throws {
        for (name, definition, json) in [("awsProfile", try aws, Self.awsJSON), ("oauth", try oauth, Self.oauthJSON)] {
            for delivery in [SecretDelivery.environment, try aws.delivery, try oauth.delivery] {
                let parsed = ResolvedSecret.parse(SecretValue(json)!, source: definition.source, delivery: delivery)
                #expect(parsed?.lastingToken == nil, "\(name) read as text under \(delivery.kind) delivery")
            }
        }
    }

    @Test func textConsumersGetNilForGatewayOnlySecretsWithoutTheSourceBeingRead() throws {
        let reads = Mutex(0)
        let resolver = SecretResolver { source in
            reads.withLock { $0 += 1 }
            switch source {
            case .awsProfile: return .success(SecretValue(Self.awsJSON)!)
            case .oauth: return .success(SecretValue(Self.oauthJSON)!)
            case .hostEnvironment: return .success(SecretValue("plain-value")!)
            case .keychain, .onePassword, .vault, .awsSecretsManager, .infisical, .bitwarden, .gcp, .azure:
                return .failure(.notFound("unexpected"))
            }
        }
        for gatewayOnly in [try aws, try oauth] {
            guard case .success(let text) = resolver.resolveText(gatewayOnly) else {
                Issue.record("\(gatewayOnly.name) failed to resolve")
                continue
            }
            #expect(text == nil)
        }
        #expect(reads.withLock { $0 } == 0)
        guard case .success(let plain) = resolver.resolveText(try token) else {
            Issue.record("a host variable failed to resolve")
            return
        }
        #expect(plain == SecretValue("plain-value"))
        #expect(reads.withLock { $0 } == 1)
    }

    @Test func resolveCredentialReportsAnUnusableValueWithoutEchoingIt() throws {
        let resolver = SecretResolver { _ in .success(SecretValue("garbage-REAL-0123")!) }
        guard case .failure(let error) = resolver.resolveCredential(try aws) else {
            Issue.record("garbage was a credential set")
            return
        }
        #expect(error == .invalidValue(AWSSigningBinding.unusableCredentials))
        #expect(error.message.contains("garbage-REAL-0123") == false)
    }

    @Test func nothingPrintsSecretMaterial() throws {
        let secrets = ["AKIAREAL", "realSecretKey", "real-session-token", "at-REAL-oauth", "plain-REAL-value"]
        let resolvedAWS = try #require(ResolvedSecret.parse(SecretValue(Self.awsJSON)!, for: try aws))
        let resolvedOAuth = try #require(ResolvedSecret.parse(SecretValue(Self.oauthJSON)!, for: try oauth))
        let credential = try #require(SecretGateway.Entry.Credential(resolvedAWS, delivery: try aws.delivery))
        let entry = SecretGateway.Entry(
            secret: "AWS_DEV", prefix: "", credential: credential,
            upstream: URL(string: "https://s3.us-east-1.amazonaws.com")!, previous: [credential])
        let rendered: [String] = [
            String(describing: resolvedAWS), String(reflecting: resolvedAWS),
            String(describing: resolvedOAuth), String(reflecting: resolvedOAuth),
            String(describing: ResolvedSecret.token(SecretValue("plain-REAL-value")!)),
            String(describing: credential), String(reflecting: credential),
            String(describing: entry), String(reflecting: entry),
            String(describing: SecretRefreshed(value: resolvedAWS, fingerprint: nil, expires: nil)),
        ]
        for text in rendered {
            for secret in secrets { #expect(text.contains(secret) == false) }
        }
    }

    /// Swift Testing renders a failed `#expect` operand, and `dump` renders any
    /// value, from its `Mirror` children, not from `description`.
    private func reflectedContents(_ value: Any, depth: Int = 0) -> [[UInt8]] {
        guard depth < 12 else { return [] }
        if let bytes = value as? [UInt8] { return [bytes] }
        if let text = value as? String { return [Array(text.utf8)] }
        return Mirror(reflecting: value).children.flatMap { reflectedContents($0.value, depth: depth + 1) }
    }

    @Test func nothingReflectsSecretMaterial() throws {
        let secrets = ["AKIAREAL", "realSecretKey", "real-session-token", "at-REAL-oauth", "plain-REAL-value"]
        let resolvedAWS = try #require(ResolvedSecret.parse(SecretValue(Self.awsJSON)!, for: try aws))
        let resolvedOAuth = try #require(ResolvedSecret.parse(SecretValue(Self.oauthJSON)!, for: try oauth))
        let credential = try #require(SecretGateway.Entry.Credential(resolvedAWS, delivery: try aws.delivery))
        let entry = SecretGateway.Entry(
            secret: "AWS_DEV", prefix: "", credential: credential,
            upstream: URL(string: "https://s3.us-east-1.amazonaws.com")!, previous: [credential])
        let values: [Any] = [
            SecretValue("plain-REAL-value")!, SecretValue(Self.awsJSON)!, resolvedAWS, resolvedOAuth,
            ResolvedSecret.token(SecretValue("plain-REAL-value")!), credential, entry,
            SecretRefreshed(value: resolvedAWS, fingerprint: nil, expires: nil),
        ]
        for value in values {
            var dumped = ""
            dump(value, to: &dumped)
            #expect(dumped.contains("bytes") == false)
            for contents in reflectedContents(value) {
                let text = String(decoding: contents, as: UTF8.self)
                for secret in secrets { #expect(text.contains(secret) == false) }
            }
        }
    }

    // MARK: Entry credential

    @Test func aRefreshCannotChangeWhatKindOfCredentialAnEntrySpends() throws {
        let set = try #require(ResolvedSecret.parse(SecretValue(Self.awsJSON)!, for: try aws))
        let signed = try #require(SecretGateway.Entry.Credential(set, delivery: try aws.delivery))
        let substituted = SecretGateway.Entry.Credential.substituted(SecretValue("plain-value")!)
        #expect(signed.replacing(with: .token(SecretValue("plain-value")!)) == nil)
        #expect(
            signed.replacing(with: try #require(ResolvedSecret.parse(SecretValue(Self.oauthJSON)!, for: try oauth)))
                == nil)
        #expect(substituted.replacing(with: set) == nil)
        #expect(signed.replacing(with: set) == signed)
        #expect(signed.signing != nil)
        #expect(signed.substitutable == nil)
        #expect(substituted.signing == nil)
        #expect(substituted.substitutable == SecretValue("plain-value"))
    }

    @Test func aSignedCredentialScrubsEveryPartAndASubstitutedOneItsValue() throws {
        let set = try #require(ResolvedSecret.parse(SecretValue(Self.awsJSON)!, for: try aws))
        let signed = try #require(SecretGateway.Entry.Credential(set, delivery: try aws.delivery))
        #expect(signed.scrubbed.count == 3)
        #expect(SecretGateway.Entry.Credential.substituted(SecretValue("v")!).scrubbed == [SecretValue("v")!])
    }
}
