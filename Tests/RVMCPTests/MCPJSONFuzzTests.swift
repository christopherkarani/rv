import Foundation
import Testing
@testable import RVMCP

/// Seeded mutation fuzz over the MCP gateway's JSON front end: the
/// newline framing `MCPGatewayRuntime.readLines` puts on hostile upstream
/// and client streams, and `JSONValue.parse` (the `JSONSpellingParser`
/// module) on each line. The libFuzzer twin is `Fuzz/MCPJSON`
/// (docs/fuzzing.md).
@Suite("MCP JSON fuzz")
struct MCPJSONFuzzTests {
    /// Starts a JSON `\u` escape in the seeds below.
    static let u = "\\" + "u"

    /// The inputs of `Fuzz/MCPJSON/seeds`, less the two read-buffer seeds
    /// that `linesAcrossTheReadBufferAreDeliveredWhole` covers.
    static let seeds: [[UInt8]] = [
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x","arguments":{"a":[1,2.5e-3,-0,true,false,null]}}}"#,
        #"{"jsonrpc":"2.0","id":"7","result":{"content":[{"type":"text","text":"a\nb \#(u)2028 \#(u)d83d\#(u)de00 \"q\" \\ \/ \#(u)0000"}]}}"#,
        "[123456789012345678901234567890,-9007199254740993,1e999999,9.007199254740993e15,0e-99999,1E+400,-0.0e-0]",
        String(repeating: "[", count: 70) + String(repeating: "]", count: 70),
        String(repeating: #"{"a":"#, count: 66) + "1" + String(repeating: "}", count: 66),
        #"["\#(u)d800","\#(u)dc00","\#(u)d800\#(u)0041","\#(u)d83d\#(u)de00"]"#,
        #"{"a":1,"a":2}"#,
        #"{"\#(u)00e9":1,"e\#(u)0301":2}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/ca"#,
        "// c\n{\"a\":1,/* x */\"b\":[1,2,],}",
        "{\"a\":1}\r\n\n{\"b\":[]}\n{\"c\"",
    ].map { Array($0.utf8) } + [
        [0xEF, 0xBB, 0xBF] + Array("{}".utf8),
        Array(#"[""#.utf8) + [0xFF, 0xFE, 0xC0, 0xAF, 0xED, 0xA0, 0x80] + Array(#""]"#.utf8),
    ]

    static let dictionary: [[UInt8]] = [
        "{", "}", "[", "]", "\"", ":", ",", "\\u", "\\ud800", "\\udc00", "\\\"", "\\\\", "true", "false",
        "null", "-", "0", "1e", "E+", ".", "//", "/*", "*/", "\n", "\r\n", "\u{2028}", "\"jsonrpc\"",
        "\"id\"", "\"method\"", "\"params\"",
    ].map { Array($0.utf8) } + [[0xEF, 0xBB, 0xBF], [0xFF], [0xC3], [0xED, 0xA0, 0x80]]

    /// Parse settings the gateway and its config readers use: the line
    /// default, `mcp.json`, and the lenient host configs.
    static let modes: [(depth: Int, lenient: Bool)] = [(64, false), (16, false), (160, true)]

    /// Every property of one document, as a list of broken ones. Accepted
    /// input must serialise to one line and parse back to an equal value
    /// that serialises identically; a stricter mode's acceptance implies
    /// the looser mode's, with the same value.
    static func violations(parsing bytes: [UInt8]) -> [String] {
        var broken: [String] = []
        var accepted: [JSONValue?] = []
        for mode in modes {
            let value = try? JSONValue.parse(Data(bytes), maximumDepth: mode.depth, lenient: mode.lenient)
            accepted.append(value)
            guard let value else { continue }
            let label = "depth \(mode.depth) lenient \(mode.lenient)"
            let compact = value.compactText
            if compact.utf8.contains(where: { $0 == 10 || $0 == 13 }) { broken.append("\(label): compact text spans lines") }
            if let again = try? JSONValue.parse(compact, maximumDepth: mode.depth) {
                if again != value { broken.append("\(label): compact text parses to a different value") }
                if again.compactText != compact { broken.append("\(label): compact text is not stable") }
            } else {
                broken.append("\(label): compact text does not parse")
            }
            if (try? JSONValue.parse(value.prettyText, maximumDepth: mode.depth)) != value {
                broken.append("\(label): pretty text does not parse back")
            }
            _ = value.domainValue
            _ = value.withExactNumbers()
        }
        if let strict = accepted[1], accepted[0] != strict { broken.append("depth 16 accepted what depth 64 did not") }
        if let strict = accepted[0], accepted[2] != strict { broken.append("lenient refused or changed strict input") }
        return broken
    }

    /// What `readLines` must deliver for `wire`: each LF-terminated line
    /// without one trailing CR, then any unterminated tail; empty lines are
    /// skipped. Lines past `maximumLineBytes` never occur at these sizes.
    static func expectedLines(_ wire: [UInt8]) -> [[UInt8]] {
        var pieces = wire.split(separator: 10, omittingEmptySubsequences: false).map { Array($0) }
        let tail = pieces.removeLast()
        var lines: [[UInt8]] = []
        for var piece in pieces {
            if piece.last == 13 { piece.removeLast() }
            if piece.isEmpty == false { lines.append(piece) }
        }
        if tail.isEmpty == false { lines.append(tail) }
        return lines
    }

    /// The stream as `MCPGatewayRuntime` reads a client or upstream pipe.
    static func violations(reading bytes: [UInt8]) -> [String] {
        guard let socket = FuzzSocket.feeding(bytes) else { return ["socketpair failed"] }
        defer { socket.close() }
        var lines: [[UInt8]] = []
        MCPGatewayRuntime.readLines(socket.fd) { lines.append(Array($0)) }
        var broken: [String] = []
        if lines != expectedLines(socket.delivered) { broken.append("lines differ from LF framing") }
        for line in lines { broken += violations(parsing: line) }
        return broken
    }

    static func stream(using random: inout FuzzRandom) -> [UInt8] {
        let separators: [[UInt8]] = [[10], [13, 10], [10, 10], [13]]
        var bytes: [UInt8] = []
        for _ in 0..<Int.random(in: 1...4, using: &random) {
            bytes += seeds.randomElement(using: &random)! + separators.randomElement(using: &random)!
        }
        return bytes
    }

    @Test(.timeLimit(.minutes(2)))
    func mutatedDocumentsRoundTrip() {
        let budget = FuzzBudget.resolve(defaultSeed: 0x6A50_0001, defaultIterations: 20_000)
        var random = FuzzRandom(seed: budget.seed)
        var failures: [String] = []
        for _ in 0..<budget.iterations {
            let bytes = FuzzMutator.mutate(
                Self.seeds.randomElement(using: &random)!, seeds: Self.seeds, dictionary: Self.dictionary,
                maxLength: 4_096, using: &random)
            let broken = Self.violations(parsing: bytes)
            if broken.isEmpty == false { failures.append("\(broken) \(FuzzMutator.describe(bytes))") }
        }
        #expect(failures.isEmpty, "seed \(budget.seed): \(failures.count) failures, first \(failures.prefix(3))")
    }

    @Test(.timeLimit(.minutes(2)))
    func mutatedStreamsKeepLineFraming() {
        let budget = FuzzBudget.resolve(defaultSeed: 0x6A50_0002, defaultIterations: 1_000)
        var random = FuzzRandom(seed: budget.seed)
        let streams = (0..<16).map { _ in Self.stream(using: &random) }
        var failures: [String] = []
        for _ in 0..<budget.iterations {
            let bytes = FuzzMutator.mutate(
                Self.stream(using: &random), seeds: streams, dictionary: Self.dictionary,
                maxLength: 16_384, using: &random)
            let broken = Self.violations(reading: bytes)
            if broken.isEmpty == false { failures.append("\(broken) \(FuzzMutator.describe(bytes))") }
        }
        #expect(failures.isEmpty, "seed \(budget.seed): \(failures.count) failures, first \(failures.prefix(3))")
    }

    /// `readLines` reads 64 KiB at a time: a line, or a CRLF, that straddles
    /// a read is still one line. This is the 64 MiB line cap scaled down to
    /// the read buffer; the cap itself is a constant too large to fuzz.
    @Test func linesAcrossTheReadBufferAreDeliveredWhole() throws {
        let read = 64 * 1024
        let long = Array(#"{"a":""#.utf8) + [UInt8](repeating: UInt8(ascii: "x"), count: read + 100) + Array(#""}"#.utf8)
        let crAtBoundary = Array(#"{"b":""#.utf8)
            + [UInt8](repeating: UInt8(ascii: "y"), count: read - 1 - 8) + Array(#""}"#.utf8)
        #expect(crAtBoundary.count == read - 1)
        for wire in [long + [10] + Array("{}".utf8), crAtBoundary + [13, 10] + Array("[]\r\n".utf8)] {
            let socket = try #require(FuzzSocket.feeding(wire))
            defer { socket.close() }
            #expect(socket.delivered.count == wire.count)
            var lines: [[UInt8]] = []
            MCPGatewayRuntime.readLines(socket.fd) { lines.append(Array($0)) }
            #expect(lines == Self.expectedLines(wire))
            #expect(lines.count == 2)
            #expect(lines.allSatisfy { (try? JSONValue.parse(Data($0))) != nil })
        }
    }

    /// Nesting far past every depth limit is refused, not a stack overflow.
    @Test(.timeLimit(.minutes(1)))
    func deepNestingFailsClosed() {
        let arrays = String(repeating: "[", count: 200_000)
        let objects = String(repeating: #"{"a":"#, count: 100_000)
        for text in [arrays, objects, arrays + String(repeating: "]", count: 200_000)] {
            for mode in Self.modes {
                #expect(throws: JSONParseError.tooDeep) {
                    try JSONValue.parse(text, maximumDepth: mode.depth, lenient: mode.lenient)
                }
            }
        }
    }

    /// Number spellings are kept verbatim at any length, and converting them
    /// for policy stays bounded.
    @Test(.timeLimit(.minutes(1)))
    func hugeNumbersKeepTheirSpelling() throws {
        let digits = "9" + String(repeating: "0", count: 100_000)
        for spelling in [digits, "-" + digits + ".5e-100001", "1e999999", "0e-999999", "1E+400", "-0.0e-0"] {
            let value = try JSONValue.parse("[\(spelling)]")
            #expect(value.arrayValue?.first == .number(spelling))
            #expect(Self.violations(parsing: Array("[\(spelling)]".utf8)).isEmpty)
        }
    }
}
