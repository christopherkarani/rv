import Foundation
import Testing
@testable import RVIsolation

@Suite("ProviderCatalog")
struct ProviderCatalogTests {
    private static func shipped() throws -> ProviderCatalog {
        try ProviderCatalog.shipped.get()
    }

    private func reason(_ json: String) -> String? {
        guard case .failure(.invalid(let reason)) = ProviderCatalog.decode(Data(json.utf8)) else { return nil }
        return reason
    }

    /// One valid profile; `patch` rewrites it to exercise one refusal.
    private func document(_ profile: String = Self.validProfile, extra: String = "") -> String {
        #"{"version":1,"providers":["# + profile + extra + "]}"
    }

    private static let validProfile = """
        {"id":"acme","displayName":"Acme","description":"Acme API",
         "endpoints":[{"name":"api","upstream":"https://api.acme.example","allow":["read-only"]}],
         "credentials":[{"variable":"ACME_KEY","baseURLEnv":"ACME_BASE_URL","endpoint":"api"}]}
        """

    /// Whether `endpoint`'s rules let `method target` through, the way the
    /// gateway checks a request on a binding with that upstream.
    private func permits(_ endpoint: ProviderProfile.Endpoint, _ method: String, _ remainder: String) -> Bool {
        // The gateway refuses a target it cannot route (a `..` segment) before any rule.
        guard let route = GatewayRoute(target: "/s/K" + remainder) else { return false }
        let basePath = URLComponents(url: endpoint.upstream, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return GatewayAccess.refusal(
            endpoint.allow.flatMap(\.rules), method: method, route: route, basePath: basePath) == nil
    }

    private func endpoint(_ profile: String, _ name: String) throws -> ProviderProfile.Endpoint {
        try #require(try Self.shipped().profile(id: profile)?.endpoint(named: name))
    }

    // MARK: - Schema

    @Test func shippedCatalogLoadsWithTheSeededProfiles() throws {
        let catalog = try Self.shipped()
        #expect(catalog.profiles.map(\.id) == [
            "anthropic", "openai", "openrouter", "github", "vercel", "stripe", "npm", "pypi",
        ])
        for profile in catalog.profiles {
            #expect(profile.endpoints.isEmpty == false, "\(profile.id)")
            for endpoint in profile.endpoints {
                #expect(endpoint.upstream.scheme == "https", "\(profile.id)")
                #expect(endpoint.surfaces == [.header], "\(profile.id)")
            }
            #expect(profile.binaries == nil, "\(profile.id): host-specific pins do not ship")
        }
    }

    @Test func validDocumentDecodes() throws {
        let catalog = try ProviderCatalog.decode(Data(document().utf8)).get()
        let profile = try #require(catalog.profile(id: "acme"))
        #expect(profile.displayName == "Acme")
        #expect(profile.endpoints == [ProviderProfile.Endpoint(
            name: "api", upstream: try #require(URL(string: "https://api.acme.example")), surfaces: [.header],
            allow: [.preset(.readOnly)])])
        #expect(profile.credentials == [ProviderProfile.Credential(
            variable: "ACME_KEY", baseURLEnv: "ACME_BASE_URL", placeholderPrefix: "", endpoint: "api")])
    }

    @Test func refusesUnknownKeysAtEveryLevel() {
        #expect(reason(#"{"version":1,"providers":[],"extra":1}"#) == "unknown key extra in document")
        #expect(reason(document(Self.validProfile.replacingOccurrences(of: #""id":"acme""#, with: #""id":"acme","auth":"x""#)))
            == "unknown key auth in providers[0]")
        #expect(reason(document(Self.validProfile.replacingOccurrences(
            of: #""name":"api","#, with: #""name":"api","port":443,"#)))
            == "unknown key port in acme.endpoints[0]")
        #expect(reason(document(Self.validProfile.replacingOccurrences(
            of: #""endpoint":"api"}"#, with: #""endpoint":"api","header":"x"}"#)))
            == "unknown key header in acme.credentials[0]")
    }

    @Test func refusesBadVersionAndEmptyOrDuplicateKeys() {
        #expect(reason(#"{"version":2,"providers":[]}"#) == "version must be 1")
        #expect(reason(#"{"version":1,"providers":[]}"#) == "providers must list 1 to 64 profiles")
        #expect(reason(#"{"version":1,"version":1,"providers":[]}"#) == "duplicate key version")
        #expect(reason("not json") == "not a JSON object")
    }

    @Test func refusesDuplicateIdsAndBadIds() {
        #expect(reason(document(extra: "," + Self.validProfile.replacingOccurrences(of: "ACME_", with: "OTHER_")))
            == "duplicate provider id acme")
        for bad in ["Acme", "-acme", "acme-", "a b", "", String(repeating: "a", count: 33), "a:b"] {
            #expect(reason(document(Self.validProfile.replacingOccurrences(of: #""id":"acme""#, with: #""id":"\#(bad)""#)))
                == "providers[0].id must be 1 to 32 lower-case letters, digits or inner -", "\(bad)")
        }
    }

    @Test func refusesNonHTTPSOrDecoratedUpstreams() {
        for bad in ["http://api.acme.example", "https://user@api.acme.example", "https://api.acme.example?x=1",
                    "https://api.acme.example#f", "ftp://api.acme.example", "api.acme.example"] {
            #expect(reason(document(Self.validProfile.replacingOccurrences(
                of: "https://api.acme.example", with: bad)))
                == "acme.endpoints[0].upstream must be an https URL without credentials, query, or fragment", "\(bad)")
        }
    }

    @Test func refusesBadGlobsAndUnknownPresets() {
        for bad in [#"{"methods":["GET"],"path":"/a/../b"}"#, #"{"methods":["GET"],"path":"/a%2fb"}"#,
                    #"{"methods":["GET"],"path":"/**/**/**"}"#, #"{"methods":["GET"],"path":"relative"}"#] {
            let text = reason(document(Self.validProfile.replacingOccurrences(of: #""read-only""#, with: bad)))
            #expect(text?.hasPrefix("acme.endpoints[0].allow[0].path must be a /-rooted glob") == true, "\(bad)")
        }
        #expect(reason(document(Self.validProfile.replacingOccurrences(of: #""read-only""#, with: #""write-all""#)))?
            .hasPrefix("acme.endpoints[0].allow[0] preset write-all is unknown") == true)
        #expect(reason(document(Self.validProfile.replacingOccurrences(of: #"["read-only"]"#, with: "[]")))
            == "acme.endpoints[0].allow must list 1 to 32 presets or rules")
        #expect(reason(document(Self.validProfile.replacingOccurrences(
            of: #""allow":["read-only"]"#, with: #""surfaces":["body"]"#)))?
            .hasPrefix("acme.endpoints[0].surfaces must list distinct surfaces") == true)
    }

    @Test func refusesCredentialsThatCannotBeBound() {
        func credential(_ fields: String) -> String {
            document(Self.validProfile.replacingOccurrences(
                of: #"{"variable":"ACME_KEY","baseURLEnv":"ACME_BASE_URL","endpoint":"api"}"#, with: fields))
        }
        #expect(reason(credential(#"{"variable":"PATH","baseURLEnv":"ACME_BASE_URL","endpoint":"api"}"#))
            == "acme.credentials[0].variable must be an environment variable name rv may set")
        #expect(reason(credential(#"{"variable":"ACME_KEY","baseURLEnv":"ACME_KEY","endpoint":"api"}"#))
            == "acme.credentials[0].baseURLEnv must be a distinct environment variable name rv may set")
        #expect(reason(credential(#"{"variable":"ACME_KEY","baseURLEnv":"ACME_BASE_URL","endpoint":"web"}"#))
            == "acme.credentials[0].endpoint web is not one of this profile's endpoints")
        #expect(reason(credential(
            #"{"variable":"ACME_KEY","baseURLEnv":"ACME_BASE_URL","placeholderPrefix":"a b","endpoint":"api"}"#))
            == "acme.credentials[0].placeholderPrefix must be up to 32 letters, digits, _ or -")
        #expect(reason(document(extra: "," + Self.validProfile.replacingOccurrences(of: #""id":"acme""#, with: #""id":"other""#)
            .replacingOccurrences(of: "ACME_BASE_URL", with: "OTHER_BASE_URL")))
            == "ACME_KEY is claimed by more than one profile (acme, other)")
    }

    @Test func refusesDuplicateEndpointsAndBadBinaries() {
        #expect(reason(document(Self.validProfile.replacingOccurrences(
            of: #""allow":["read-only"]}"#,
            with: #""allow":["read-only"]},{"name":"api","upstream":"https://b.acme.example"}"#)))
            == "acme.endpoints has api twice")
        #expect(reason(document(Self.validProfile.replacingOccurrences(of: #""id":"acme""#, with: #""id":"acme","binaries":["gh"]"#)))
            == "acme.binaries must be 1 to 16 distinct absolute paths")
    }

    // MARK: - KnownSecretDefaults parity

    @Test func knownSecretDefaultsKeepTheirCuratedValues() {
        let expected: [String: KnownSecretDefaults.Gateway] = [
            "OPENAI_API_KEY": .init(upstream: "https://api.openai.com/v1", baseURLEnv: "OPENAI_BASE_URL", placeholderPrefix: "sk-"),
            "ANTHROPIC_API_KEY": .init(upstream: "https://api.anthropic.com", baseURLEnv: "ANTHROPIC_BASE_URL", placeholderPrefix: "sk-ant-"),
            "STRIPE_SECRET_KEY": .init(upstream: "https://api.stripe.com", baseURLEnv: "STRIPE_API_BASE", placeholderPrefix: "sk-"),
            "GITHUB_TOKEN": .init(upstream: "https://api.github.com", baseURLEnv: "GITHUB_API_URL", placeholderPrefix: ""),
            "GH_TOKEN": .init(upstream: "https://api.github.com", baseURLEnv: "GH_API_URL", placeholderPrefix: ""),
            "VERCEL_TOKEN": .init(upstream: "https://api.vercel.com", baseURLEnv: "VERCEL_BASE_URL", placeholderPrefix: ""),
        ]
        for (name, gateway) in expected {
            #expect(KnownSecretDefaults.gateway(for: name) == gateway, "\(name)")
        }
        #expect(KnownSecretDefaults.gateway(for: "ACME_KEY") == nil)
        #expect(KnownSecretDefaults.gateway(for: "openai_api_key") == nil)
    }

    @Test func knownSecretDefaultsAnswerNothingFromAnInvalidCatalog() {
        let broken = ProviderCatalog.decode(Data("{}".utf8))
        #expect(KnownSecretDefaults.gateway(for: "OPENAI_API_KEY", catalog: broken) == nil)
    }

    // MARK: - Seeded profile rules

    @Test func githubReadsAndClonesButNeverPushes() throws {
        let api = try endpoint("github", "api")
        #expect(api.upstream.absoluteString == "https://api.github.com")
        #expect(permits(api, "GET", "/repos/o/r"))
        #expect(permits(api, "HEAD", "/repos/o/r/contents/README.md"))
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            #expect(permits(api, method, "/repos/o/r/issues") == false, "\(method)")
        }
        #expect(permits(api, "POST", "/graphql") == false)

        let git = try endpoint("github", "git")
        #expect(git.upstream.absoluteString == "https://github.com")
        #expect(permits(git, "GET", "/o/r.git/info/refs?service=git-upload-pack"))
        #expect(permits(git, "POST", "/o/r.git/git-upload-pack"))
        #expect(permits(git, "GET", "/o/r.git/info/refs?service=git-receive-pack") == false)
        #expect(permits(git, "POST", "/o/r.git/git-receive-pack") == false)
        #expect(permits(git, "DELETE", "/o/r") == false)
    }

    @Test func npmTokenOnlyPutsAPackageDocument() throws {
        let publish = try endpoint("npm", "publish")
        #expect(publish.upstream.absoluteString == "https://registry.npmjs.org")
        #expect(permits(publish, "PUT", "/left-pad"))
        #expect(permits(publish, "GET", "/left-pad") == false)
        #expect(permits(publish, "GET", "/left-pad/-/left-pad-1.0.0.tgz") == false)
        #expect(permits(publish, "DELETE", "/left-pad/-rev/3-abc") == false)
        #expect(permits(publish, "PUT", "/left-pad/-rev/3-abc") == false)
        #expect(permits(publish, "PUT", "/-/package/left-pad/dist-tags/latest") == false)
        #expect(permits(publish, "PUT", "/-/user/org.couchdb.user:me") == false)
        #expect(permits(publish, "POST", "/-/npm/v1/tokens") == false)
        // npm escapes a scope's slash; with rules, an encoded slash is never forwarded.
        #expect(permits(publish, "PUT", "/@scope%2fpkg") == false)
    }

    @Test func pypiTokenOnlyUploads() throws {
        let upload = try endpoint("pypi", "upload")
        #expect(upload.upstream.absoluteString == "https://upload.pypi.org/legacy")
        #expect(permits(upload, "POST", "/"))
        #expect(permits(upload, "POST", "") == false)
        #expect(permits(upload, "GET", "/") == false)
        #expect(permits(upload, "POST", "/../manage") == false)
        #expect(permits(upload, "POST", "/x") == false)
        #expect(permits(upload, "DELETE", "/") == false)
    }

    @Test func inferenceAndPaymentProfilesKeepTheirOpenScope() throws {
        for id in ["anthropic", "openai", "openrouter", "vercel", "stripe"] {
            let profile = try #require(try Self.shipped().profile(id: id))
            #expect(profile.endpoints.allSatisfy { $0.allow.isEmpty }, "\(id)")
        }
    }

    // MARK: - Expansion

    private func expand(
        _ selector: String, _ name: String, baseURLEnv: String? = nil, placeholderPrefix: String = "",
        surfaces: Set<GatewaySurface>? = nil, allow: [String] = []
    ) throws -> Result<ProviderExpansion, ProviderExpansionError> {
        try Self.shipped().expand(
            selector, secret: name, baseURLEnv: baseURLEnv, placeholderPrefix: placeholderPrefix,
            surfaces: surfaces, allow: allow.map { try #require(GatewayAllowance($0)) })
    }

    @Test func expandsAProfileCredentialToItsEndpoint() throws {
        let github = try expand("github", "GITHUB_TOKEN").get()
        #expect(github == ProviderExpansion(
            profile: "github", endpoint: "api", upstream: try #require(URL(string: "https://api.github.com")),
            baseURLEnv: "GITHUB_API_URL", placeholderPrefix: "", surfaces: [.header],
            allow: [.preset(.githubRead)], binaries: nil))
        let openai = try expand("openai", "OPENAI_API_KEY").get()
        #expect(openai.placeholderPrefix == "sk-")
        #expect(openai.allow.isEmpty)
        #expect(try expand("openai", "OPENAI_API_KEY", placeholderPrefix: "sk-proj-").get().placeholderPrefix == "sk-proj-")
    }

    @Test func expandsAnyNameOnceTheEndpointAndVariableAreKnown() throws {
        let git = try expand("github:git", "GITHUB_GIT_TOKEN", baseURLEnv: "GITHUB_GIT_URL").get()
        #expect(git.upstream.absoluteString == "https://github.com")
        #expect(git.allow == [.preset(.githubClone)])
        #expect(try expand("github:git", "GITHUB_GIT_TOKEN") == .failure(.needsBaseURLEnv(profile: "github", endpoint: "git")))
        #expect(try expand("github", "GITHUB_GIT_TOKEN", baseURLEnv: "X_URL")
            == .failure(.endpointAmbiguous(profile: "github", endpoints: ["api", "git"])))
        let single = try expand("stripe", "STRIPE_TEST_KEY", baseURLEnv: "STRIPE_TEST_BASE").get()
        #expect(single.upstream.absoluteString == "https://api.stripe.com")
        #expect(single.placeholderPrefix == "")
    }

    @Test func expansionRefusesUnknownProvidersAndEndpoints() throws {
        #expect(try expand("gitlab", "GITLAB_TOKEN") == .failure(.unknownProvider("gitlab")))
        #expect(try expand("github:web", "GITHUB_TOKEN") == .failure(.unknownEndpoint(profile: "github", endpoint: "web")))
        #expect(try expand("github:", "GITHUB_TOKEN") == .failure(.unknownEndpoint(profile: "github", endpoint: "")))
    }

    @Test func expansionNarrowsButNeverWidens() throws {
        let repos = try expand("github", "GITHUB_TOKEN", allow: ["GET /repos/**"]).get()
        #expect(repos.allow == [.rule(try #require(GatewayAccessRule(methods: ["GET"], path: "/repos/**")))])
        #expect(try expand("github", "GITHUB_TOKEN", allow: ["github-read"]).get().allow == [.preset(.githubRead)])
        #expect(try expand("github", "GITHUB_TOKEN", allow: ["POST /graphql"])
            == .failure(.widerAllow(profile: "github", allowance: "POST /graphql")))
        #expect(try expand("github", "GITHUB_TOKEN", allow: ["read-only"])
            == .failure(.widerAllow(profile: "github", allowance: "read-only")))
        #expect(try expand("github", "GITHUB_TOKEN", allow: ["* /repos/**"])
            == .failure(.widerAllow(profile: "github", allowance: "* /repos/**")))
        // A hand-written rule cannot carry the preset's service=git-upload-pack condition.
        #expect(try expand("github:git", "T", baseURLEnv: "T_URL", allow: ["GET /**/info/refs"])
            == .failure(.widerAllow(profile: "github", allowance: "GET /**/info/refs")))
        #expect(try expand("github:git", "T", baseURLEnv: "T_URL", allow: ["POST /o/*/git-upload-pack"]).get().allow.count == 1)
        #expect(try expand("npm", "NPM_TOKEN", allow: ["PUT /left-pad"]).get().allow.count == 1)
        #expect(try expand("npm", "NPM_TOKEN", allow: ["PUT /**"])
            == .failure(.widerAllow(profile: "npm", allowance: "PUT /**")))
        #expect(try expand("npm", "NPM_TOKEN", allow: ["PUT /*/-rev/*"])
            == .failure(.widerAllow(profile: "npm", allowance: "PUT /*/-rev/*")))
        // An open profile narrows to anything.
        #expect(try expand("openai", "OPENAI_API_KEY", allow: ["POST /v1/chat/**"]).get().allow.count == 1)
        #expect(try expand("github", "GITHUB_TOKEN", surfaces: [.header, .query])
            == .failure(.widerSurface(profile: "github", surface: .query)))
        #expect(try expand("github", "GITHUB_TOKEN", surfaces: [.header]).get().surfaces == [.header])
    }

    @Test func expansionCarriesProfileBinaries() throws {
        let json = document(Self.validProfile.replacingOccurrences(
            of: #""id":"acme""#, with: #""id":"acme","binaries":["/opt/homebrew/bin/acme"]"#))
        let catalog = try ProviderCatalog.decode(Data(json.utf8)).get()
        let expanded = try catalog.expand(
            "acme", secret: "ACME_KEY", baseURLEnv: nil, placeholderPrefix: "", surfaces: nil, allow: []).get()
        #expect(expanded.binaries == ["/opt/homebrew/bin/acme"])
    }

    @Test func globContainmentIsConservative() {
        let cases: [(String, String, Bool)] = [
            ("/repos/**", "/**", true),
            ("/**", "/repos/**", false),
            ("/repos/o/r", "/repos/*/*", true),
            ("/repos/*/r", "/repos/*/*", true),
            ("/repos/a*/r", "/repos/*/r", true),
            ("/repos/*/r", "/repos/a*/r", false),
            ("/a/**/b", "/a/**", true),
            ("/a/**", "/a/**/b", false),
            ("/x/git-upload-pack", "/**/git-upload-pack", true),
            ("/**/git-upload-pack", "/**/git-upload-pack", true),
            ("/**/git-receive-pack", "/**/git-upload-pack", false),
            ("/left-pad", "/*", true),
            ("/a/b", "/*", false),
            ("/legacy/", "/legacy/", true),
            ("/legacy", "/legacy/", false),
            ("/", "/**", true),
        ]
        for (inner, outer, expected) in cases {
            #expect(GatewayAccess.glob(inner, isWithin: outer) == expected, "\(inner) within \(outer)")
        }
    }
}
