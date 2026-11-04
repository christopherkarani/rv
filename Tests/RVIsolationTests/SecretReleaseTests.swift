import Foundation
import RVDomain
import RVPolicy
import Synchronization
import Testing
@testable import RVIsolation

@Suite("Secret release")
struct SecretReleaseTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let upstream = URL(string: "https://api.example.com")!

    static func environment(_ name: String, expires: Date? = nil) -> SecretDefinition {
        SecretDefinition(name: name, source: .hostEnvironment(variable: name), delivery: .environment, expires: expires)
    }

    static func gateway(_ name: String, source: SecretSource? = nil) -> SecretDefinition {
        SecretDefinition(
            name: name, source: source ?? .keychain(service: "rv.secrets", account: name),
            delivery: .gateway(SecretGatewayBinding(upstream: upstream, baseURLEnv: "\(name)_URL")))
    }

    static let oauth = gateway(
        "API", source: .oauth(OAuthSource(
            tokenURL: URL(string: "https://issuer.example.com/token")!, clientID: "c",
            refreshToken: SecretKeychainItem(service: "rv.oauth", account: "api"))))

    static let aws = SecretDefinition(
        name: "AWS_DEV", source: .awsProfile(profile: "dev"),
        delivery: .awsSigV4(AWSSigningBinding(
            upstream: URL(string: "https://s3.us-east-1.amazonaws.com")!, region: "us-east-1", service: "s3",
            endpointEnv: "AWS_ENDPOINT_URL_S3")))

    /// Counts every read, so a test can prove admission happened first.
    final class Provider: Sendable {
        let reads = Mutex(0)
        let versions = Mutex(0)
        let value: @Sendable (SecretSource) -> Result<SecretValue, SecretResolutionError>

        init(_ value: @escaping @Sendable (SecretSource) -> Result<SecretValue, SecretResolutionError>) {
            self.value = value
        }

        convenience init(text: String) {
            self.init { _ in .success(SecretValue(text)!) }
        }

        var resolver: SecretResolver {
            SecretResolver(
                resolve: { source in
                    self.reads.withLock { $0 += 1 }
                    return self.value(source)
                },
                version: { _ in
                    self.versions.withLock { $0 += 1 }
                    return "v1"
                })
        }
    }

    static func policy(_ json: String) throws -> ManagedPolicyState {
        .active(ManagedPolicyBundle(
            policy: try ManagedPolicy.decode(Data(json.utf8)).get(), sha256: "", isSigned: false, directory: ""))
    }

    static func release(
        _ definitions: [SecretDefinition], to target: SecretTarget, provider: Provider,
        managed: ManagedPolicyState = .none
    ) -> Result<[ReleasedSecret], SecretRefusal> {
        SecretRelease(resolver: provider.resolver, managed: managed, now: { start })
            .release(definitions, to: target)
    }

    static func reason(_ result: Result<[ReleasedSecret], SecretRefusal>) -> SecretRefusal.Reason? {
        if case .failure(.refused(_, let reason)) = result { return reason }
        return nil
    }

    @Test(arguments: [SecretTarget.cage, .stdioServer, .header])
    func anExpiredSecretRefusesTheWholeSetBeforeAnythingIsRead(target: SecretTarget) {
        let provider = Provider(text: "v")
        let expired = Self.start.addingTimeInterval(-1)
        let result = Self.release(
            [Self.environment("FRESH"), Self.environment("OLD", expires: expired)], to: target, provider: provider)
        #expect(result.failure == .refused(secret: "OLD", .expired(at: expired)))
        #expect(provider.reads.withLock { $0 } == 0)
        #expect(provider.versions.withLock { $0 } == 0)
    }

    @Test(arguments: [SecretTarget.cage, .stdioServer, .header])
    func anInvalidPolicyReleasesNothingEvenForAnEmptySet(target: SecretTarget) {
        let provider = Provider(text: "v")
        #expect(Self.release([], to: target, provider: provider, managed: .invalid("bad signature")).failure
            == .policyInvalid("bad signature"))
        #expect(Self.release([Self.environment("A")], to: target, provider: provider, managed: .invalid("x")).failure
            == .policyInvalid("x"))
        #expect(provider.reads.withLock { $0 } == 0)
    }

    @Test func eachTargetHasItsOwnOrganizationRule() throws {
        let provider = Provider(text: "v")
        let noEnvironment = try Self.policy(#"{"version":1,"secrets":{"allowEnvironmentDelivery":false}}"#)
        func rule(_ definition: SecretDefinition, _ target: SecretTarget) -> SecretRefusal.Reason? {
            Self.reason(Self.release([definition], to: target, provider: provider, managed: noEnvironment))
        }
        #expect(rule(Self.environment("A"), .cage) == .organizationPolicy(.environmentDelivery))
        #expect(rule(Self.gateway("B"), .cage) == nil)
        // A stdio server holds the real value whatever the definition's delivery says.
        #expect(rule(Self.gateway("B"), .stdioServer) == .organizationPolicy(.environmentDelivery))
        #expect(rule(Self.environment("A"), .header) == nil)

        let keychainOnly = try Self.policy(#"{"version":1,"secrets":{"allowedSources":["keychain"]}}"#)
        for target in [SecretTarget.cage, .stdioServer, .header] {
            #expect(Self.reason(Self.release([Self.environment("A")], to: target, provider: provider, managed: keychainOnly))
                == .organizationPolicy(.source(kind: "hostEnvironment")))
        }
    }

    /// A resource profile's `keychain` entry puts a real value in the cage's
    /// environment, so it answers to the same organization rules.
    @Test func profileKeychainEntriesAnswerToOrganizationPolicy() throws {
        let entry = RuntimeResourceProfile.KeychainEntry(service: "s", account: "a", env: "OPENAI_API_KEY")
        let noEnvironment = try Self.policy(#"{"version":1,"secrets":{"allowEnvironmentDelivery":false}}"#)
        let vaultOnly = try Self.policy(#"{"version":1,"secrets":{"allowedSources":["vault"]}}"#)
        let open = try Self.policy(#"{"version":1,"secrets":{"allowedSources":["keychain"]}}"#)
        #expect(SecretOrganizationRules.profileKeychainRule(policy: noEnvironment.policy) == .environmentDelivery)
        #expect(SecretOrganizationRules.profileKeychainRule(policy: vaultOnly.policy) == .source(kind: "keychain"))
        #expect(SecretOrganizationRules.profileKeychainRule(policy: open.policy) == nil)
        #expect(SecretOrganizationRules.profileKeychainRule(policy: nil) == nil)

        func refusal(_ managed: ManagedPolicyState) -> SecretLeaseError? {
            SecretLaunchBroker.profileKeychainRefusal([entry], managed: managed)
        }
        #expect(refusal(noEnvironment) == .organizationPolicy(
            SecretOrganizationRule.environmentDelivery.message(secret: "resource profile keychain entry $OPENAI_API_KEY")))
        #expect(refusal(.invalid("x")) == .organizationPolicy("invalid, so keychain entries are not staged: x"))
        #expect(refusal(.none) == nil)
        #expect(SecretLaunchBroker.profileKeychainRefusal([], managed: .invalid("x")) == nil)
    }

    @Test func gatewayOnlyValuesNeverLeaveForAServerOrHeader() {
        let provider = Provider(text: "v")
        for definition in [Self.oauth, Self.aws] {
            #expect(Self.reason(Self.release([definition], to: .stdioServer, provider: provider)) == .gatewayOnly)
            #expect(Self.reason(Self.release([definition], to: .header, provider: provider)) == .gatewayOnly)
        }
        #expect(provider.reads.withLock { $0 } == 0)
    }

    @Test func anOAuthAnswerReleasesItsAccessTokenUntilTheEarlierExpiry() throws {
        let soon = Self.start.addingTimeInterval(600)
        let answer = #"{"access_token":"tok-1","expires_at":\#(Int(soon.timeIntervalSince1970))}"#
        let released = try Self.release([Self.oauth], to: .cage, provider: Provider(text: answer)).get()
        #expect(released.first?.value == SecretValue("tok-1"))
        #expect(released.first?.expires == soon)
        #expect(released.first?.version == "v1")

        let stale = #"{"access_token":"tok-1","expires_at":\#(Int(Self.start.timeIntervalSince1970) - 5)}"#
        #expect(Self.reason(Self.release([Self.oauth], to: .cage, provider: Provider(text: stale)))
            == .expired(at: Self.start.addingTimeInterval(-5)))
        #expect(Self.reason(Self.release([Self.oauth], to: .cage, provider: Provider(text: "not json"))) == .unusableToken)
    }

    @Test func anAWSProfileReleasesItsCredentialSetUntilItsExpiration() throws {
        let set = #"{"Version":1,"AccessKeyId":"AKIAEXAMPLE","SecretAccessKey":"s3cr3t","Expiration":"2027-02-01T00:00:00Z"}"#
        let released = try Self.release([Self.aws], to: .cage, provider: Provider(text: set)).get()
        #expect(released.first?.value == SecretValue(set))
        #expect(released.first?.expires == SecretExpiry.parse("2027-02-01T00:00:00Z"))
        #expect(Self.reason(Self.release([Self.aws], to: .cage, provider: Provider(text: "{}"))) == .unusableCredentials)
    }

    @Test func eachTargetHasItsOwnTextRule() throws {
        let multiline = Provider(text: "line one\nline two")
        #expect(try Self.release([Self.environment("A")], to: .stdioServer, provider: multiline).get().first?.text
            == "line one\nline two")
        #expect(Self.reason(Self.release([Self.environment("A")], to: .header, provider: multiline)) == .lineBreak)

        let large = Provider(text: String(repeating: "x", count: SecretRelease.maximumEnvironmentValueBytes + 1))
        #expect(Self.reason(Self.release([Self.environment("A")], to: .cage, provider: large)) == .unusableEnvironmentValue)
        // A gateway entry never becomes an environment variable, so the limit does not apply.
        #expect((try? Self.release([Self.gateway("B")], to: .cage, provider: large).get()) != nil)

        let binary = Provider { _ in .success(SecretValue([0xFF, 0xFE])!) }
        #expect(Self.reason(Self.release([Self.environment("A")], to: .stdioServer, provider: binary)) == .notText)
        #expect(Self.reason(Self.release([Self.environment("A")], to: .header, provider: binary)) == .notText)
    }

    @Test func onlyGatewayEntriesInACageReadAVersionMarker() throws {
        let provider = Provider(text: "v")
        _ = try Self.release([Self.environment("A"), Self.gateway("B")], to: .cage, provider: provider).get()
        #expect(provider.versions.withLock { $0 } == 1)
        _ = try Self.release([Self.gateway("B")], to: .header, provider: provider).get()
        #expect(provider.versions.withLock { $0 } == 1)
    }

    @Test func prefetchedValuesAreNotReadAgainAndAFailureNamesItsSecret() {
        let provider = Provider { _ in .failure(.notFound("gone")) }
        var resolver = provider.resolver
        resolver.prefetch = { _ in [0: .success(SecretValue("batched")!)] }
        let result = SecretRelease(resolver: resolver, managed: .none, now: { Self.start })
            .release([Self.environment("A"), Self.environment("B")], to: .cage)
        #expect(result.failure == .refused(secret: "B", .resolution(.notFound("gone"))))
        #expect(provider.reads.withLock { $0 } == 1)
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
