import Foundation
import Testing
@testable import RVIsolation

/// Seeded mutation fuzz over the secret gateway's request front end: the
/// socket head/chunk reader, `GatewayRequestHead.parse`, `GatewayRoute`,
/// and body framing. The libFuzzer twin is `Fuzz/GatewayRequest`
/// (docs/fuzzing.md).
@Suite("Gateway request fuzz")
struct GatewayRequestFuzzTests {
    static let seeds: [[UInt8]] = [
        "GET /s/GITHUB_TOKEN/user HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer rvph_0123456789abcdef\r\n",
        "POST /s/OPENAI_API_KEY/v1/chat/completions?x=1 HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n",
        "PUT /s/AWS/bucket/key HTTP/1.0\r\nTransfer-Encoding: chunked\r\nX-Amz-Date: 20260101T000000Z\r\n",
        "HEAD /s/T/ HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n",
        "DELETE /s/_x9/a/../b HTTP/1.1\r\n",
        "GET /other HTTP/1.1\r\nHost: x\r\n",
    ].map { Array($0.utf8) }

    static let bodies: [[UInt8]] = [
        "5\r\nhello\r\n0\r\n\r\n", "0\r\n\r\n", "ffffffffffffffff\r\n", "3;ext=1\r\nabc\r\n0\r\nT: v\r\n\r\n",
        "{}", "-1\r\n", "\n\r\n",
    ].map { Array($0.utf8) }

    static let dictionary: [[UInt8]] = [
        "\r\n", "\r\n\r\n", "\n", "\r", ":", ": ", " ", "\t", "/s/", "/", "?", "#", "..", "%2e", "%00",
        "HTTP/1.1", "HTTP/1.0", "Content-Length: ", "Transfer-Encoding: chunked", "Authorization: ",
        "Host: ", "rvph_", "\u{0}", "\u{FFFD}", "é",
    ].map { Array($0.utf8) }

    /// Rebuilds a parsed head as wire bytes; parsing them again must give
    /// the same head.
    static func serialize(_ head: GatewayRequestHead) -> [UInt8] {
        var text = "\(head.method) \(head.target) HTTP/1.1"
        for header in head.headers {
            text += "\r\n\(header.name): \(header.value)"
        }
        return Array(text.utf8)
    }

    /// Every property of one parse, as a list of broken ones.
    static func violations(parsing bytes: [UInt8]) -> [String] {
        guard let head = GatewayRequestHead.parse(bytes) else { return [] }
        var broken: [String] = []
        if bytes.count > GatewayRequestHead.maximumBytes { broken.append("accepted an oversized head") }
        if head.method.isEmpty || head.method.utf8.contains(where: { $0 < 65 || $0 > 90 }) {
            broken.append("method \(head.method.debugDescription)")
        }
        if head.target.hasPrefix("/") == false { broken.append("target \(head.target.debugDescription)") }
        if head.headers.count > GatewayRequestHead.maximumHeaders { broken.append("\(head.headers.count) headers") }
        for header in head.headers {
            let text = header.name + header.value
            if header.name.isEmpty || text.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 }) {
                broken.append("header \(header.name.debugDescription): \(header.value.debugDescription)")
            }
        }
        if GatewayRequestHead.parse(serialize(head)) != head { broken.append("serialize/parse round trip") }
        if let route = GatewayRoute(target: head.target) {
            if head.target != "/s/" + route.secret + route.remainder { broken.append("route lost bytes") }
            if route.remainder.contains("#") || route.remainder.split(separator: "/").contains("..") {
                broken.append("route remainder \(route.remainder.debugDescription)")
            }
            let base = URL(string: "https://api.example.com/v1")!
            if let url = route.upstreamURL(base: base), url.host != "api.example.com" || url.scheme != "https" {
                broken.append("upstream escaped to \(url.absoluteString)")
            }
        }
        let framing = gatewayBodyFraming(
            transferEncodings: head.headerValues("Transfer-Encoding"),
            contentLengths: head.headerValues("Content-Length"),
            maximum: 1_024
        )
        if case .fixed(let length) = framing, (1...1_024).contains(length) == false {
            broken.append("framing length \(length)")
        }
        if Set(head.headerValues("Content-Length")).count > 1, framing != .refused {
            broken.append("disagreeing Content-Length framed as \(framing)")
        }
        _ = SecretPlaceholder.occurrences(in: bytes)
        _ = SecretPlaceholder.redactedPath(head.target)
        return broken
    }

    /// The socket reader as `SecretGateway.handle` drives it: head, then a
    /// chunked body.
    static func violations(reading bytes: [UInt8]) -> [String] {
        guard let socket = FuzzSocket.feeding(bytes) else { return ["socketpair failed"] }
        defer { socket.close() }
        let wire = socket.delivered
        let reader = GatewaySocket.Reader(fd: socket.fd)
        guard let head = reader.readHead(limit: GatewayRequestHead.maximumBytes) else { return [] }
        var broken: [String] = []
        let terminator: [UInt8] = [13, 10, 13, 10]
        if wire.starts(with: head) == false || Array(wire.dropFirst(head.count).prefix(4)) != terminator {
            broken.append("head is not the bytes before the first blank line")
        }
        if head.count >= 4, (0...(head.count - 4)).contains(where: { Array(head[$0..<$0 + 4]) == terminator }) {
            broken.append("head contains a blank line")
        }
        broken += violations(parsing: head)
        if let body = reader.readChunked(limit: 1_024), body.count > 1_024 {
            broken.append("chunked body \(body.count) bytes past limit")
        }
        return broken
    }

    static func corpus(using random: inout FuzzRandom) -> [UInt8] {
        let head = seeds.randomElement(using: &random)!
        return head + [13, 10, 13, 10] + bodies.randomElement(using: &random)!
    }

    @Test(.timeLimit(.minutes(2)))
    func mutatedHeadsKeepParserInvariants() {
        let budget = FuzzBudget.resolve(defaultSeed: 0x6A7E_0001, defaultIterations: 20_000)
        var random = FuzzRandom(seed: budget.seed)
        var failures: [String] = []
        for _ in 0..<budget.iterations {
            let bytes = FuzzMutator.mutate(
                Self.seeds.randomElement(using: &random)!, seeds: Self.seeds, dictionary: Self.dictionary,
                maxLength: 2_048, using: &random)
            let broken = Self.violations(parsing: bytes)
            if broken.isEmpty == false { failures.append("\(broken) \(FuzzMutator.describe(bytes))") }
        }
        #expect(failures.isEmpty, "seed \(budget.seed): \(failures.count) failures, first \(failures.prefix(3))")
    }

    @Test(.timeLimit(.minutes(2)))
    func mutatedWireRequestsKeepReaderInvariants() {
        let budget = FuzzBudget.resolve(defaultSeed: 0x6A7E_0002, defaultIterations: 2_000)
        var random = FuzzRandom(seed: budget.seed)
        let wires = (0..<16).map { _ in Self.corpus(using: &random) }
        var failures: [String] = []
        for _ in 0..<budget.iterations {
            let bytes = FuzzMutator.mutate(
                Self.corpus(using: &random), seeds: wires, dictionary: Self.dictionary + Self.bodies,
                maxLength: 8_192, using: &random)
            let broken = Self.violations(reading: bytes)
            if broken.isEmpty == false { failures.append("\(broken) \(FuzzMutator.describe(bytes))") }
        }
        #expect(failures.isEmpty, "seed \(budget.seed): \(failures.count) failures, first \(failures.prefix(3))")
    }

    @Test func oversizedHeadIsRefused() {
        let line = Array("GET /s/T/ HTTP/1.1\r\nX: ".utf8)
        let bytes = line + [UInt8](repeating: UInt8(ascii: "a"), count: GatewayRequestHead.maximumBytes)
        #expect(GatewayRequestHead.parse(bytes) == nil)
    }
}
