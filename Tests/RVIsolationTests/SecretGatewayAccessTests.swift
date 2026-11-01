import Foundation
import Testing
@testable import RVIsolation

@Suite("SecretGatewayAccess")
struct SecretGatewayAccessTests {
    private func refusal(
        _ allow: [GatewayAllowance], _ method: String, _ target: String, basePath: String = ""
    ) throws -> GatewayRefusal? {
        let route = try #require(GatewayRoute(target: target))
        return GatewayAccess.refusal(allow.flatMap(\.rules), method: method, route: route, basePath: basePath)
    }

    @Test func presetsExpandToDocumentedRules() {
        #expect(GatewayAccessPreset.readOnly.rules == [
            GatewayAccessRule(methods: ["GET", "HEAD", "OPTIONS"], path: "/**", query: [:]),
        ])
        #expect(GatewayAccessPreset.githubClone.rules == [
            GatewayAccessRule(methods: ["GET"], path: "/**/info/refs", query: ["service": "git-upload-pack"]),
            GatewayAccessRule(methods: ["POST"], path: "/**/git-upload-pack", query: [:]),
        ])
        #expect(GatewayAccessPreset.githubRead.rules == [
            GatewayAccessRule(methods: ["GET", "HEAD"], path: "/**", query: [:]),
        ])
        #expect(GatewayAllowance("read-only") == .preset(.readOnly))
        #expect(GatewayAllowance("GET,HEAD /repos/**") == .rule(GatewayAccessRule(methods: ["GET", "HEAD"], path: "/repos/**")!))
        #expect(GatewayAllowance("* /v1/chat/*") == .rule(GatewayAccessRule(methods: nil, path: "/v1/chat/*")!))
        for bad in ["write-all", "GET", "get /x", "GET,GET /x", "GET x", "GET /a/../b", "GET /a%2fb", "GET /a//b",
                    "GET /a/**x", "GET /**/**/**", "GET /a?b", "GET /a;b", "GET /a\\b", ", /x"] {
            #expect(GatewayAllowance(bad) == nil, "\(bad)")
        }
    }

    @Test func noRulesAllowEveryMethodAndPath() throws {
        #expect(try refusal([], "DELETE", "/s/K/repos/o/r") == nil)
        #expect(try refusal([], "GET", "/s/K/projects/group%2Fproject") == nil)
    }

    @Test func readOnlyRefusesWrites() throws {
        let readOnly: [GatewayAllowance] = [.preset(.readOnly)]
        for method in ["GET", "HEAD", "OPTIONS"] {
            #expect(try refusal(readOnly, method, "/s/K/repos/o/r?x=1") == nil, "\(method)")
        }
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            #expect(try refusal(readOnly, method, "/s/K/repos/o/r") == .outsideAllowRules, "\(method)")
        }
        #expect(try refusal(readOnly, "GET", "/s/K") == nil)
    }

    @Test func githubCloneAllowsUploadPackAndRefusesReceivePack() throws {
        let clone: [GatewayAllowance] = [.preset(.githubClone)]
        #expect(try refusal(clone, "GET", "/s/K/o/r.git/info/refs?service=git-upload-pack") == nil)
        #expect(try refusal(clone, "POST", "/s/K/o/r.git/git-upload-pack") == nil)
        #expect(try refusal(clone, "GET", "/s/K/o/r.git/info/refs?service=git-receive-pack") == .outsideAllowRules)
        #expect(try refusal(clone, "GET", "/s/K/o/r.git/info/refs") == .outsideAllowRules)
        #expect(try refusal(clone, "GET", "/s/K/o/r.git/info/refs?service=git-upload-pack&service=git-receive-pack")
            == .outsideAllowRules)
        #expect(try refusal(clone, "POST", "/s/K/o/r.git/git-receive-pack") == .outsideAllowRules)
        #expect(try refusal(clone, "GET", "/s/K/o/r.git/git-upload-pack") == .outsideAllowRules)
        #expect(try refusal(clone, "DELETE", "/s/K/o/r.git/info/refs?service=git-upload-pack") == .outsideAllowRules)
    }

    @Test func globsMatchOneSegmentOrMany() throws {
        let one: [GatewayAllowance] = [.rule(GatewayAccessRule(methods: ["GET"], path: "/repos/*/issues")!)]
        #expect(try refusal(one, "GET", "/s/K/repos/o/issues") == nil)
        #expect(try refusal(one, "GET", "/s/K/repos/o/r/issues") == .outsideAllowRules)
        #expect(try refusal(one, "GET", "/s/K/repos/issues") == .outsideAllowRules)
        let many: [GatewayAllowance] = [.rule(GatewayAccessRule(methods: nil, path: "/v1/**")!)]
        #expect(try refusal(many, "PATCH", "/s/K/v1/a/b/c") == nil)
        #expect(try refusal(many, "GET", "/s/K/v2/a") == .outsideAllowRules)
        let suffix: [GatewayAllowance] = [.rule(GatewayAccessRule(methods: ["GET"], path: "/files/*.json")!)]
        #expect(try refusal(suffix, "GET", "/s/K/files/a.json") == nil)
        #expect(try refusal(suffix, "GET", "/s/K/files/a.txt") == .outsideAllowRules)
    }

    @Test func rulesMatchTheUpstreamPathIncludingItsBase() throws {
        let chat: [GatewayAllowance] = [.rule(GatewayAccessRule(methods: ["POST"], path: "/v1/chat/completions")!)]
        #expect(try refusal(chat, "POST", "/s/K/chat/completions", basePath: "/v1") == nil)
        #expect(try refusal(chat, "POST", "/s/K/files", basePath: "/v1") == .outsideAllowRules)
    }

    @Test func ambiguousPathsAreRefusedBeforeMatching() throws {
        let any: [GatewayAllowance] = [.rule(GatewayAccessRule(methods: nil, path: "/public/**")!)]
        for target in [
            "/s/K/public/%2e%2e/admin", "/s/K/public/%2E%2E/admin", "/s/K/public/.%2e/admin",
            "/s/K/public/%2e/x", "/s/K/public/./x", "/s/K/public/a%2fb", "/s/K/public/a%2F..%2Fadmin",
            "/s/K/public/a%5cb", "/s/K/public/a\\..\\admin", "/s/K/public//admin",
            "/s/K/public/%252e%252e/admin", "/s/K/public/..;/admin", "/s/K/public/a;x=1",
            "/s/K/public/%00", "/s/K/public/%ff",
        ] {
            #expect(try refusal(any, "GET", target) == .ambiguousPath, "\(target)")
        }
        #expect(GatewayAccess.normalizedPath("/public/a%20b/") == "/public/a b/")
        #expect(GatewayAccess.normalizedPath("/") == "/")
        #expect(try refusal(any, "GET", "/s/K/public/a%20b") == nil)
    }

    @Test func substitutionChecksRulesBeforePlacingTheValue() throws {
        let key = SecretPlaceholder.mint(prefix: "")
        func apply(_ request: String, rules: [GatewayAccessRule]) throws -> Result<GatewayRequestHead, GatewayRefusal> {
            let parsed = try #require(GatewayRequestHead.parse(Array(request.utf8)))
            let route = try #require(GatewayRoute(target: parsed.target))
            return GatewaySubstitution.apply(parsed, route: route) {
                $0 == key.token
                    ? GatewaySubstitution.Live(
                        token: key.token, secret: "K", prefix: "", value: SecretValue("real")!, surfaces: [.header],
                        rules: rules, basePath: "")
                    : nil
            }.map(\.head)
        }
        let readOnly = GatewayAccessPreset.readOnly.rules
        let header = "Authorization: Bearer \(key.text)"
        #expect(try apply("DELETE /s/K/repos/o/r HTTP/1.1\r\n\(header)", rules: readOnly) == .failure(.outsideAllowRules))
        #expect(try apply("GET /s/K/a/%2e%2e/b HTTP/1.1\r\n\(header)", rules: readOnly) == .failure(.ambiguousPath))
        #expect(try apply("GET /s/K/repos HTTP/1.1\r\n\(header)", rules: readOnly)
            .map { $0.header("Authorization") } == .success("Bearer real"))
        #expect(try apply("DELETE /s/K/a%2Fb HTTP/1.1\r\n\(header)", rules: [])
            .map { $0.header("Authorization") } == .success("Bearer real"))
    }

    @Test func auditPathsNeverCarryAPlaceholder() {
        let key = SecretPlaceholder.mint(prefix: "sk-")
        #expect(SecretPlaceholder.redacted("/s/K/bot\(key.text)/send") == "/s/K/botsk-rvph_[redacted]/send")
        #expect(SecretPlaceholder.redacted("/s/K/plain") == "/s/K/plain")
        #expect(SecretPlaceholder.redactedPath("/s/K/rvph%5F\(key.token)/x?q=\(key.text)") == "/s/K/rvph_[redacted]/x")
        #expect(SecretPlaceholder.redactedPath("/s/K/a%2Fb?q=1") == "/s/K/a%2Fb")
    }

    @Test func onlyPolicyRefusalsAreMisuse() {
        let all: [GatewayRefusal] = [
            .malformed, .unknownRoute, .noPlaceholder, .unknownPlaceholder, .foreignPlaceholder, .tooLarge,
            .unsafeValue, .echoMethod, .encodedPlaceholder, .surfaceNotAllowed, .repeatedPlaceholder,
            .outsideAllowRules, .ambiguousPath, .auditUnavailable,
        ]
        #expect(all.filter(\.isMisuse).map(\.code) == [
            "foreignPlaceholder", "echoMethod", "encodedPlaceholder", "surfaceNotAllowed", "repeatedPlaceholder",
            "outsideAllowRules", "ambiguousPath",
        ])
        #expect(GatewayRefusal.auditUnavailable.status == 503)
    }
}
