import Foundation
import Testing
@testable import RVIsolation

@Suite("SecretGatewayProtocol")
struct SecretGatewayProtocolTests {
    private func head(_ text: String) -> GatewayRequestHead? {
        GatewayRequestHead.parse(Array(text.utf8))
    }

    @Test func mintedPlaceholdersAreDistinctAndFindable() {
        let first = SecretPlaceholder.mint(prefix: "sk-")
        let second = SecretPlaceholder.mint(prefix: "sk-")
        #expect(first != second)
        #expect(first.text.hasPrefix("sk-rvph_"))
        #expect(first.text.utf8.count == 3 + 5 + 32)
        let found = SecretPlaceholder.occurrences(in: Array("Bearer \(first.text), x=\(second.text)".utf8))
        #expect(found.map(\.token) == [first.token, second.token])
        #expect(SecretPlaceholder.occurrences(in: Array("rvph_ABCDEF".utf8)).isEmpty)
    }

    @Test func parsesStrictHTTP1RequestHeads() throws {
        let parsed = try #require(head("POST /s/KEY/v1/chat?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization:  Bearer t "))
        #expect(parsed.method == "POST")
        #expect(parsed.target == "/s/KEY/v1/chat?x=1")
        #expect(parsed.header("authorization") == "Bearer t")
        #expect(head("GET / HTTP/2\r\nHost: x") == nil)
        #expect(head("get / HTTP/1.1\r\nHost: x") == nil)
        #expect(head("GET http://evil/ HTTP/1.1\r\nHost: x") == nil)
        #expect(head("GET / HTTP/1.1\nHost: x") == nil)
        #expect(head("GET / HTTP/1.1\r\nHost: x\r\n folded") == nil)
        #expect(head("GET / HTTP/1.1\r\nBad Name: x") == nil)
        let many = (0...GatewayRequestHead.maximumHeaders).map { "H\($0): v" }.joined(separator: "\r\n")
        #expect(head("GET / HTTP/1.1\r\n" + many) == nil)
    }

    @Test func duplicateContentLengthIsRefused() {
        let maximum = 32 * 1024 * 1024
        #expect(gatewayBodyFraming(
            transferEncodings: [],
            contentLengths: ["0", "\(maximum + 1)"],
            maximum: maximum
        ) == .refused)
        #expect(gatewayBodyFraming(
            transferEncodings: [],
            contentLengths: ["0", "1"],
            maximum: maximum
        ) == .refused)
        #expect(gatewayBodyFraming(
            transferEncodings: ["chunked"],
            contentLengths: ["\(maximum + 1)"],
            maximum: maximum
        ) == .refused)
        #expect(gatewayBodyFraming(
            transferEncodings: [],
            contentLengths: ["\(maximum + 1)"],
            maximum: maximum
        ) == .refused)
        #expect(gatewayBodyFraming(
            transferEncodings: ["gzip"],
            contentLengths: [],
            maximum: maximum
        ) == .refused)
        #expect(gatewayBodyFraming(
            transferEncodings: [],
            contentLengths: ["0"],
            maximum: maximum
        ) == .empty)
        #expect(gatewayBodyFraming(
            transferEncodings: [],
            contentLengths: [],
            maximum: maximum
        ) == .empty)
        #expect(gatewayBodyFraming(
            transferEncodings: ["chunked"],
            contentLengths: [],
            maximum: maximum
        ) == .chunked)
        #expect(contentLengthsRefuseBody(["0", "0"], maximum: maximum) == false)
    }

    @Test func routesOnlyNamedSecretPaths() throws {
        let route = try #require(GatewayRoute(target: "/s/OPENAI_API_KEY/v1/models?limit=2"))
        #expect(route.secret == "OPENAI_API_KEY")
        #expect(route.remainder == "/v1/models?limit=2")
        #expect(GatewayRoute(target: "/s/KEY")?.remainder == "")
        #expect(GatewayRoute(target: "/s/KEY?q=1")?.remainder == "?q=1")
        #expect(GatewayRoute(target: "/v1/models") == nil)
        #expect(GatewayRoute(target: "/s/1BAD/x") == nil)
        #expect(GatewayRoute(target: "/s/KEY/../admin") == nil)
        #expect(GatewayRoute(target: "/s/KEY/x#frag") == nil)
    }

    @Test func upstreamURLStaysOnTheBoundOrigin() throws {
        let base = try #require(URL(string: "https://api.example.com/v1"))
        #expect(GatewayRoute(target: "/s/K/chat")?.upstreamURL(base: base)?.absoluteString
            == "https://api.example.com/v1/chat")
        #expect(GatewayRoute(target: "/s/K?x=1")?.upstreamURL(base: base)?.absoluteString
            == "https://api.example.com/v1?x=1")
        let slash = try #require(URL(string: "https://api.example.com/"))
        #expect(GatewayRoute(target: "/s/K/v1")?.upstreamURL(base: slash)?.absoluteString
            == "https://api.example.com/v1")
        #expect(GatewayRoute(target: "/s/K/@evil.example")?.upstreamURL(base: base)?.host == "api.example.com")
    }

    private func live(_ placeholder: SecretPlaceholder, secret: String, value: String) -> GatewaySubstitution.Live {
        GatewaySubstitution.Live(
            token: placeholder.token, secret: secret, prefix: placeholder.prefix,
            value: SecretValue(value)!)
    }

    @Test func substitutesOwnPlaceholdersInTargetAndHeaders() throws {
        let key = SecretPlaceholder.mint(prefix: "sk-")
        let request = try #require(head(
            "GET /s/KEY/v1?api_key=\(key.text) HTTP/1.1\r\nAuthorization: Bearer \(key.text)\r\nX-Other: keep"))
        let route = try #require(GatewayRoute(target: request.target))
        let result = try GatewaySubstitution.apply(request, route: route) {
            $0 == key.token ? live(key, secret: "KEY", value: "sk-real-123") : nil
        }.get()
        #expect(result.head.target == "/s/KEY/v1?api_key=sk-real-123")
        #expect(result.head.header("Authorization") == "Bearer sk-real-123")
        #expect(result.head.header("X-Other") == "keep")
        #expect(result.used.token == key.token)
    }

    @Test func refusesMissingUnknownAndForeignPlaceholders() throws {
        let mine = SecretPlaceholder.mint(prefix: "")
        let theirs = SecretPlaceholder.mint(prefix: "")
        let lookup: (String) -> GatewaySubstitution.Live? = { token in
            if token == mine.token { return live(mine, secret: "KEY", value: "v1") }
            if token == theirs.token { return live(theirs, secret: "OTHER", value: "v2") }
            return nil
        }
        func refusal(_ header: String) throws -> GatewayRefusal? {
            let request = try #require(head("GET /s/KEY/x HTTP/1.1\r\n\(header)"))
            let route = try #require(GatewayRoute(target: request.target))
            guard case .failure(let refusal) = GatewaySubstitution.apply(request, route: route, lookup: lookup) else {
                return nil
            }
            return refusal
        }
        #expect(try refusal("Authorization: Bearer plain") == .noPlaceholder)
        #expect(try refusal("Authorization: Bearer \(SecretPlaceholder.mint(prefix: "").text)") == .unknownPlaceholder)
        #expect(try refusal("Authorization: Bearer \(theirs.text)") == .foreignPlaceholder)
        #expect(try refusal("Authorization: Bearer \(mine.text)\r\nX-Leak: \(theirs.text)") == .foreignPlaceholder)
        #expect(try refusal("Authorization: Bearer \(mine.text)") == nil)
    }

    @Test func scrubberCatchesValuesSplitAtEveryBoundary() {
        let secret = Array("sk-live-SECRET-0123456789".utf8)
        let marker = Array("[rv]".utf8)
        let body = Array("{\"echo\":\"".utf8) + secret + Array("\",\"again\":\"".utf8) + secret + Array("\"}".utf8)
        let expected = Array("{\"echo\":\"[rv]\",\"again\":\"[rv]\"}".utf8)
        for split in 0...body.count {
            var scrubber = SecretScrubber([(secret, marker)])
            let output = scrubber.process(Array(body[..<split])) + scrubber.process(Array(body[split...]))
                + scrubber.finish()
            #expect(output == expected, "split at \(split)")
        }
        var byteAtATime = SecretScrubber([(secret, marker)])
        var output: [UInt8] = []
        for byte in body { output += byteAtATime.process([byte]) }
        output += byteAtATime.finish()
        #expect(output == expected)
    }

    @Test func scrubberPassesInnocentTrafficThrough() {
        var scrubber = SecretScrubber([(Array("secret".utf8), Array("X".utf8))])
        let first = scrubber.process(Array("hello secre".utf8))
        #expect(first == Array("hello ".utf8))
        let rest = scrubber.process(Array("tive".utf8)) + scrubber.finish()
        #expect(first + rest == Array("hello Xive".utf8))
        #expect(SecretScrubber.scrub("no match here", [(Array("zz".utf8), Array("X".utf8))]) == "no match here")
    }
}
