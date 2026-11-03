import Foundation
import Testing
@testable import RVIsolation

/// `refresh` and `binaries` live in the gateway payloads: an environment secret
/// cannot hold them, and a running placeholder's route ignores them.
@Suite("SecretGatewayLimits")
struct SecretGatewayLimitsTests {
    private static let upstream = URL(string: "https://api.example.com")!
    private static let gateway = SecretDelivery.gateway(SecretGatewayBinding(upstream: upstream, baseURLEnv: "API_BASE"))
    private static let aws = SecretDelivery.awsSigV4(AWSSigningBinding(
        upstream: upstream, region: "us-east-1", service: "s3", endpointEnv: "AWS_ENDPOINT_URL"))

    private func definition(_ delivery: SecretDelivery) -> SecretDefinition {
        SecretDefinition(name: "A", source: .hostEnvironment(variable: "A"), delivery: delivery)
    }

    @Test func setRefreshSetsAndClearsOnGatewayPayloads() throws {
        let interval = try #require(SecretRefreshInterval("15m"))
        for delivery in [Self.gateway, Self.aws] {
            var secret = definition(delivery)
            try secret.setRefresh(interval)
            #expect(secret.refresh == interval)
            #expect(secret.delivery.limits?.refresh == interval)
            try secret.setRefresh(nil)
            #expect(secret.refresh == nil)
            #expect(secret.delivery == delivery)
        }
    }

    @Test func setRefreshOnEnvironmentRefusesAValueAndAcceptsAClear() throws {
        let interval = try #require(SecretRefreshInterval("15m"))
        var secret = definition(.environment)
        #expect(throws: SecretDefinitionError.refreshNeedsGateway("A")) { try secret.setRefresh(interval) }
        #expect(secret == definition(.environment))
        try secret.setRefresh(nil)
        #expect(secret == definition(.environment))
        #expect(secret.refresh == nil && secret.binaries == nil && secret.delivery.limits == nil)
    }

    @Test func routeIgnoresLimitsButNotTheBinding() throws {
        let limited = Self.gateway.with(limits: SecretGatewayLimits(
            refresh: try #require(SecretRefreshInterval("1h")), binaries: ["/usr/bin/curl"]))
        #expect(limited != Self.gateway)
        #expect(limited.route == Self.gateway.route)
        #expect(Self.gateway.route != Self.aws.route)
        #expect(SecretDelivery.environment.route == .environment)
    }
}
