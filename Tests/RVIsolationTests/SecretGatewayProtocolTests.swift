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

    private func live(
        _ placeholder: SecretPlaceholder, secret: String, value: String,
        surfaces: Set<GatewaySurface> = Set(GatewaySurface.allCases)
    ) -> GatewaySubstitution.Live {
        GatewaySubstitution.Live(
            token: placeholder.token, secret: secret, prefix: placeholder.prefix,
            value: SecretValue(value)!, surfaces: surfaces)
    }

    private func surfaced(
        _ request: String, surfaces: Set<GatewaySurface>
    ) throws -> Result<GatewayRequestHead, GatewayRefusal> {
        let key = SecretPlaceholder.mint(prefix: "")
        // `BASIC<user:password>` becomes a Basic header value after PH is swapped in.
        var text = request.replacingOccurrences(of: "PH", with: key.text)
        while let open = text.range(of: "BASIC<"), let close = text[open.upperBound...].firstIndex(of: ">") {
            let credentials = String(text[open.upperBound..<close])
            text.replaceSubrange(open.lowerBound...close, with: "Basic " + Data(credentials.utf8).base64EncodedString())
        }
        let parsed = try #require(head(text))
        let route = try #require(GatewayRoute(target: parsed.target))
        return GatewaySubstitution.apply(parsed, route: route) {
            $0 == key.token ? live(key, secret: "KEY", value: "real", surfaces: surfaces) : nil
        }.map { $0.head }
    }

    @Test func placeholdersAreSwappedOnlyOnTheirAllowedSurfaces() throws {
        let header: Set<GatewaySurface> = [.header]
        #expect(try surfaced("GET /s/KEY/x HTTP/1.1\r\nAuthorization: Bearer PH", surfaces: header)
            .map { $0.header("Authorization") } == .success("Bearer real"))
        #expect(try surfaced("GET /s/KEY/x?key=PH HTTP/1.1\r\nX: y", surfaces: header) == .failure(.surfaceNotAllowed))
        #expect(try surfaced("GET /s/KEY/botPH/x HTTP/1.1\r\nX: y", surfaces: header) == .failure(.surfaceNotAllowed))
        #expect(try surfaced("GET /s/KEY/x?key=PH HTTP/1.1\r\nAuthorization: Bearer PH", surfaces: header)
            == .failure(.surfaceNotAllowed))
        #expect(try surfaced("GET /s/KEY/x?key=PH HTTP/1.1\r\nX: y", surfaces: [.query]).map(\.target)
            == .success("/s/KEY/x?key=real"))
        #expect(try surfaced("GET /s/KEY/x HTTP/1.1\r\nAuthorization: Bearer PH", surfaces: [.query])
            == .failure(.surfaceNotAllowed))
        #expect(try surfaced("GET /s/KEY/botPH/x HTTP/1.1\r\nX: y", surfaces: [.path]).map(\.target)
            == .success("/s/KEY/botreal/x"))
        #expect(try surfaced("GET /s/KEY/x HTTP/1.1\r\nAuthorization: BASIC<u:PH>", surfaces: [.query])
            == .failure(.surfaceNotAllowed))
    }

    @Test func eachSurfaceIsFilledAtMostOnce() throws {
        let all = Set(GatewaySurface.allCases)
        for request in [
            "GET /s/KEY/x HTTP/1.1\r\nAuthorization: Bearer PH\r\nX-Echo: PH",
            "GET /s/KEY/x HTTP/1.1\r\nAuthorization: Bearer PH PH",
            "GET /s/KEY/x HTTP/1.1\r\nAuthorization: BASIC<PH:PH>",
            "GET /s/KEY/x HTTP/1.1\r\nAuthorization: BASIC<u:PH>\r\nX-Api-Key: PH",
            "GET /s/KEY/x?a=PH&b=PH HTTP/1.1\r\nX: y",
            "GET /s/KEY/PH/PH HTTP/1.1\r\nX: y",
        ] {
            #expect(try surfaced(request, surfaces: all) == .failure(.repeatedPlaceholder), "\(request)")
        }
        let spread = try surfaced("GET /s/KEY/botPH/x?key=PH HTTP/1.1\r\nAuthorization: Bearer PH", surfaces: all)
        #expect(spread.map(\.target) == .success("/s/KEY/botreal/x?key=real"))
        #expect(spread.map { $0.header("Authorization") } == .success("Bearer real"))
        let clone = try surfaced(
            "GET /s/KEY/r.git/info/refs HTTP/1.1\r\nAuthorization: BASIC<x-access-token:PH>\r\nUser-Agent: git/2",
            surfaces: [.header])
        #expect(clone.map { $0.header("Authorization") }
            == .success("Basic " + Data("x-access-token:real".utf8).base64EncodedString()))
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

    private func substituted(_ request: String, value: String) throws -> Result<GatewayRequestHead, GatewayRefusal> {
        let key = SecretPlaceholder.mint(prefix: "")
        let parsed = try #require(head(request.replacingOccurrences(of: "PH", with: key.text)))
        let route = try #require(GatewayRoute(target: parsed.target))
        return GatewaySubstitution.apply(parsed, route: route) {
            $0 == key.token ? live(key, secret: "KEY", value: value) : nil
        }.map { $0.head }
    }

    @Test func queryValuesArePercentEncodedSoTheyCannotAddParameters() throws {
        let base = try #require(URL(string: "https://api.example.com/v1"))
        let rewritten = try substituted("GET /s/KEY/models?key=PH&limit=2 HTTP/1.1\r\nX: y", value: "x?admin=1&").get()
        #expect(rewritten.target == "/s/KEY/models?key=x%3Fadmin%3D1%26&limit=2")
        let url = try #require(GatewayRoute(target: rewritten.target)?.upstreamURL(base: base))
        #expect(url.path == "/v1/models")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.map(\.name) == ["key", "limit"])
        #expect(items.first?.value == "x?admin=1&")

        let traversal = try substituted("GET /s/KEY/models?key=PH HTTP/1.1\r\nX: y", value: "/../admin").get()
        #expect(traversal.target == "/s/KEY/models?key=%2F..%2Fadmin")
        #expect(GatewayRoute(target: traversal.target)?.upstreamURL(base: base)?.path == "/v1/models")

        let lines = try substituted("GET /s/KEY/x?key=PH HTTP/1.1\r\nX: y", value: "a\r\nb c+%").get()
        #expect(lines.target == "/s/KEY/x?key=a%0D%0Ab%20c%2B%25")
    }

    @Test func pathValuesThatCouldReshapeThePathAreRefused() throws {
        for value in ["/../admin", "x?x=1&", "a/b", "a\\b", "a#b", "..", "a..b", "a\r\nb"] {
            #expect(try substituted("GET /s/KEY/botPH/send HTTP/1.1\r\nX: y", value: value) == .failure(.unsafeValue),
                "value \(value.debugDescription)")
        }
        let plain = try substituted("GET /s/KEY/botPH/send HTTP/1.1\r\nX: y", value: "123:ABC-def_~").get()
        #expect(plain.target == "/s/KEY/bot123:ABC-def_~/send")
        let encoded = try substituted("GET /s/KEY/botPH/send HTTP/1.1\r\nX: y", value: "a b%é").get()
        #expect(encoded.target == "/s/KEY/bota%20b%25%C3%A9/send")
    }

    @Test func headerValuesWithLineBreaksAreRefused() throws {
        for value in ["sk-1\r\nX-Injected: yes", "sk-1\nX-Injected: yes", "sk-1\rX"] {
            #expect(try substituted("GET /s/KEY/x HTTP/1.1\r\nAuthorization: Bearer PH", value: value)
                == .failure(.unsafeValue))
        }
        let pem = "-----BEGIN KEY-----\nabc\n-----END KEY-----"
        #expect(try substituted("GET /s/KEY/x?k=PH HTTP/1.1\r\nX: y", value: pem).map(\.target)
            == .success("/s/KEY/x?k=-----BEGIN%20KEY-----%0Aabc%0A-----END%20KEY-----"))
    }

    private func basic(_ credentials: String) -> String {
        "Basic " + Data(credentials.utf8).base64EncodedString()
    }

    @Test func basicCredentialsAreDecodedSubstitutedAndReencoded() throws {
        let key = SecretPlaceholder.mint(prefix: "")
        func authorization(_ header: String, value: String = "ghp_real") throws -> Result<String?, GatewayRefusal> {
            let parsed = try #require(head("GET /s/KEY/repo.git/info/refs HTTP/1.1\r\nAuthorization: \(header)"))
            let route = try #require(GatewayRoute(target: parsed.target))
            return GatewaySubstitution.apply(parsed, route: route) {
                $0 == key.token ? live(key, secret: "KEY", value: value) : nil
            }.map { $0.head.header("Authorization") }
        }
        #expect(try authorization(basic("x-access-token:\(key.text)")) == .success(basic("x-access-token:ghp_real")))
        #expect(try authorization("basic " + Data("u:\(key.text)".utf8).base64EncodedString())
            == .success(basic("u:ghp_real")))
        #expect(try authorization(basic("\(key.text):x-oauth-basic")) == .success(basic("ghp_real:x-oauth-basic")))
        #expect(try authorization(basic("\(key.text):x"), value: "user:pass") == .failure(.unsafeValue))
        #expect(try authorization(basic("u:\(key.text)"), value: "a:b") == .success(basic("u:a:b")))
        #expect(try authorization(basic("u:\(key.text)"), value: "a\r\nX-Injected: 1") == .failure(.unsafeValue))
        #expect(try authorization(basic("u:\(SecretPlaceholder.mint(prefix: "").text)")) == .failure(.unknownPlaceholder))
        #expect(try authorization(basic("u:plain")) == .failure(.noPlaceholder))
    }

    @Test func percentEncodedPlaceholdersAreRefused() throws {
        let key = SecretPlaceholder.mint(prefix: "")
        let marker = "%72%76%70%68%5F"
        let fully = key.text.utf8.map { String(format: "%%%02X", $0) }.joined()
        for request in [
            "GET /s/KEY/x?k=%72vph_\(key.token) HTTP/1.1\r\nX: y",
            "GET /s/KEY/x?k=\(marker)\(key.token) HTTP/1.1\r\nX: y",
            "GET /s/KEY/\(fully)/x HTTP/1.1\r\nX: y",
            "GET /s/KEY/x HTTP/1.1\r\nAuthorization: Bearer rvph%5f\(key.token)",
            "GET /s/KEY/x?k=\(key.text) HTTP/1.1\r\nX-Other: rvph%5F\(key.token)",
            "GET /s/KEY/x HTTP/1.1\r\nAuthorization: \(basic("u:rvph%5F\(key.token)"))",
        ] {
            let parsed = try #require(head(request))
            let route = try #require(GatewayRoute(target: parsed.target))
            let result = GatewaySubstitution.apply(parsed, route: route) {
                $0 == key.token ? live(key, secret: "KEY", value: "v") : nil
            }.map { $0.head }
            #expect(result == .failure(.encodedPlaceholder), "\(request)")
        }
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
