import Foundation
import Testing
@testable import RVIsolation

/// Curated defaults grant least privilege: a placeholder for a well-known
/// name reaches only the paths and methods its everyday client needs.
@Suite("Known secret defaults")
struct KnownSecretDefaultsTests {
    static let names = [
        "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "STRIPE_SECRET_KEY", "GITHUB_TOKEN", "GH_TOKEN", "VERCEL_TOKEN",
    ]

    private func refusal(_ name: String, _ method: String, _ remainder: String) throws -> GatewayRefusal? {
        let known = try #require(KnownSecretDefaults.gateway(for: name))
        let upstream = try #require(URL(string: known.upstream))
        let basePath = URLComponents(url: upstream, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        let route = try #require(GatewayRoute(target: "/s/\(name)\(remainder)"))
        return GatewayAccess.refusal(known.allow.flatMap(\.rules), method: method, route: route, basePath: basePath)
    }

    @Test func everyCuratedDefaultHasAllowRules() throws {
        for name in Self.names {
            let known = try #require(KnownSecretDefaults.gateway(for: name), "\(name)")
            #expect(known.allow.isEmpty == false, "\(name) allows every method and path")
        }
    }

    @Test func modelProviderKeysReachOnlyTheirAPIPrefixWithGetAndPost() throws {
        #expect(try refusal("OPENAI_API_KEY", "POST", "/chat/completions") == nil)
        #expect(try refusal("OPENAI_API_KEY", "GET", "/models") == nil)
        #expect(try refusal("OPENAI_API_KEY", "DELETE", "/files/file-1") == .outsideAllowRules)
        #expect(try refusal("OPENAI_API_KEY", "PUT", "/chat/completions") == .outsideAllowRules)
        #expect(try refusal("ANTHROPIC_API_KEY", "POST", "/v1/messages") == nil)
        #expect(try refusal("ANTHROPIC_API_KEY", "GET", "/v1/models") == nil)
        #expect(try refusal("ANTHROPIC_API_KEY", "POST", "/api/oauth/token") == .outsideAllowRules)
        #expect(try refusal("ANTHROPIC_API_KEY", "DELETE", "/v1/files/f") == .outsideAllowRules)
    }

    @Test func githubTokensDefaultToGithubRead() throws {
        for name in ["GITHUB_TOKEN", "GH_TOKEN"] {
            #expect(KnownSecretDefaults.gateway(for: name)?.allow == [.preset(.githubRead)])
            #expect(try refusal(name, "GET", "/repos/o/r") == nil)
            for method in ["POST", "PUT", "PATCH", "DELETE"] {
                #expect(try refusal(name, method, "/repos/o/r") == .outsideAllowRules, "\(name) \(method)")
            }
            #expect(try refusal(name, "POST", "/graphql") == .outsideAllowRules)
        }
    }

    @Test func paymentAndDeployTokensDefaultToReadOnly() throws {
        for name in ["STRIPE_SECRET_KEY", "VERCEL_TOKEN"] {
            #expect(KnownSecretDefaults.gateway(for: name)?.allow == [.preset(.readOnly)])
            #expect(try refusal(name, "GET", "/v1/charges") == nil)
            for method in ["POST", "DELETE"] {
                #expect(try refusal(name, method, "/v1/charges") == .outsideAllowRules, "\(name) \(method)")
            }
        }
    }
}
