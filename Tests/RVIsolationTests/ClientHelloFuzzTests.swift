import Foundation
import Testing
@testable import RVIsolation

/// Seeded fuzz over the egress proxy's SNI binding: the ClientHello record
/// reader, `tlsServerName`, `checkSNI`, and the CONNECT / absolute-URI
/// request-line parsers in front of them. The libFuzzer twin is
/// `Fuzz/TLSClientHello` (docs/fuzzing.md).
@Suite("ClientHello fuzz")
struct ClientHelloFuzzTests {
    struct Extension {
        var kind: UInt16
        var data: [UInt8]
    }

    static func u16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// A ClientHello record with `extensions` in order. Session id and
    /// cipher suites vary so the cursor walk is exercised, not just the
    /// fixed offsets.
    static func clientHello(sessionID: [UInt8], suites: [UInt8], extensions: [Extension]) -> [UInt8] {
        var body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 0xAB, count: 32)
        body += [UInt8(sessionID.count)] + sessionID
        body += u16(suites.count) + suites + [0x01, 0x00]
        let encoded = extensions.flatMap { u16(Int($0.kind)) + u16($0.data.count) + $0.data }
        body += u16(encoded.count) + encoded
        let handshake: [UInt8] = [0x01, UInt8((body.count >> 16) & 0xFF)] + u16(body.count) + body
        return [0x16, 0x03, 0x01] + u16(handshake.count) + handshake
    }

    /// server_name extension data: entries of (name_type, name).
    static func serverName(_ entries: [(type: UInt8, name: [UInt8])]) -> Extension {
        let list = entries.flatMap { [$0.type] + u16($0.name.count) + $0.name }
        return Extension(kind: 0x0000, data: u16(list.count) + list)
    }

    static func randomBytes(_ count: Int, using random: inout FuzzRandom) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255, using: &random) }
    }

    static func randomHost(using random: inout FuzzRandom) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789-")
        let labels = (0..<Int.random(in: 1...4, using: &random)).map { _ in
            String((0..<Int.random(in: 1...20, using: &random)).map { _ in letters.randomElement(using: &random)! })
        }
        return labels.joined(separator: ".")
    }

    static func randomExtensions(using random: inout FuzzRandom) -> [Extension] {
        (0..<Int.random(in: 0...4, using: &random)).map { _ in
            Extension(
                kind: UInt16.random(in: 1...0xFFFF, using: &random),
                data: randomBytes(Int.random(in: 0...40, using: &random), using: &random))
        }
    }

    static let dictionary: [[UInt8]] = [
        [0x16, 0x03, 0x01], [0x16, 0x03, 0x03], [0x01, 0x00, 0x00], [0x00, 0x00], [0x00, 0x00, 0x00],
        [0xFF, 0xFF], [0x40, 0x00], [0x40, 0x01], Array("api.example.com".utf8), [0x2E], [0xC0, 0x80],
    ]

    static func seeds(using random: inout FuzzRandom) -> [[UInt8]] {
        (0..<32).map { _ in
            clientHello(
                sessionID: randomBytes(Int.random(in: 0...32, using: &random), using: &random),
                suites: randomBytes(2 * Int.random(in: 1...8, using: &random), using: &random),
                extensions: randomExtensions(using: &random)
                    + [serverName([(0, Array(randomHost(using: &random).utf8))])]
                    + randomExtensions(using: &random))
        }
    }

    /// Properties of one parse that hold for any bytes.
    static func violations(parsing bytes: [UInt8]) -> [String] {
        guard let name = EgressWire.tlsServerName(bytes) else { return [] }
        var broken: [String] = []
        if name.isEmpty { broken.append("empty server name") }
        if bytes.count < 9 || bytes[0] != 0x16 || bytes[5] != 0x01 { broken.append("name from a non-ClientHello") }
        // Bytes past the record are never read: appending must not change the answer.
        if EgressWire.tlsServerName(bytes + [0x00, 0x00, 0x00, 0x05, 0x00]) != name {
            broken.append("trailing bytes changed the name")
        }
        // A record one byte short is not a ClientHello.
        if bytes.count >= 5 {
            let recordEnd = 5 + (Int(bytes[3]) << 8 | Int(bytes[4]))
            if recordEnd <= bytes.count, EgressWire.tlsServerName(Array(bytes.prefix(recordEnd - 1))) != nil {
                broken.append("truncated record still named a server")
            }
        }
        if EgressAdmission.checkSNI(expectedHost: name, serverName: name) != nil {
            broken.append("checkSNI refused its own name")
        }
        return broken
    }

    /// Generated well-formed hellos: the parser must return exactly the
    /// first host_name entry, whatever surrounds it.
    @Test func generatedClientHellosRoundTripTheirServerName() {
        let budget = FuzzBudget.resolve(defaultSeed: 0x7115_0001, defaultIterations: 3_000)
        var random = FuzzRandom(seed: budget.seed)
        var failures: [String] = []
        for _ in 0..<budget.iterations {
            let host = Self.randomHost(using: &random)
            let leading: [(type: UInt8, name: [UInt8])] = (0..<Int.random(in: 0...2, using: &random)).map { _ in
                (UInt8.random(in: 1...255, using: &random), Self.randomBytes(Int.random(in: 1...8, using: &random), using: &random))
            }
            let hello = Self.clientHello(
                sessionID: Self.randomBytes(Int.random(in: 0...32, using: &random), using: &random),
                suites: Self.randomBytes(2 * Int.random(in: 1...16, using: &random), using: &random),
                extensions: Self.randomExtensions(using: &random)
                    + [Self.serverName(leading + [(0, Array(host.utf8)), (0, Array("decoy.example".utf8))])]
                    + Self.randomExtensions(using: &random))
            let parsed = EgressWire.tlsServerName(hello)
            if parsed != host { failures.append("\(host) parsed as \(parsed ?? "nil")") }
            if EgressAdmission.checkSNI(expectedHost: host.uppercased() + ".", serverName: parsed) != nil {
                failures.append("checkSNI refused \(host)")
            }
            if EgressAdmission.checkSNI(expectedHost: "decoy.example", serverName: parsed) == nil {
                failures.append("checkSNI admitted the second entry for \(host)")
            }
        }
        #expect(failures.isEmpty, "seed \(budget.seed): \(failures.count) failures, first \(failures.prefix(3))")
    }

    @Test(.timeLimit(.minutes(2)))
    func mutatedClientHellosKeepParserInvariants() {
        let budget = FuzzBudget.resolve(defaultSeed: 0x7115_0002, defaultIterations: 20_000)
        var random = FuzzRandom(seed: budget.seed)
        let seeds = Self.seeds(using: &random)
        var failures: [String] = []
        for _ in 0..<budget.iterations {
            let bytes = FuzzMutator.mutate(
                seeds.randomElement(using: &random)!, seeds: seeds, dictionary: Self.dictionary,
                maxLength: 17_000, using: &random)
            let broken = Self.violations(parsing: bytes)
            if broken.isEmpty == false { failures.append("\(broken) \(FuzzMutator.describe(bytes))") }
        }
        #expect(failures.isEmpty, "seed \(budget.seed): \(failures.count) failures, first \(failures.prefix(3))")
    }

    /// The record reader as `tunnel` drives it: some bytes arrived with the
    /// CONNECT, the rest come off the socket.
    @Test(.timeLimit(.minutes(2)))
    func mutatedStreamsKeepRecordReaderInvariants() {
        let budget = FuzzBudget.resolve(defaultSeed: 0x7115_0003, defaultIterations: 1_000)
        var random = FuzzRandom(seed: budget.seed)
        let seeds = Self.seeds(using: &random)
        var failures: [String] = []
        for _ in 0..<budget.iterations {
            let bytes = FuzzMutator.mutate(
                seeds.randomElement(using: &random)!, seeds: seeds, dictionary: Self.dictionary,
                maxLength: 17_000, using: &random)
            let split = Int.random(in: 0...bytes.count, using: &random)
            guard let socket = FuzzSocket.feeding(Array(bytes[split...])) else {
                failures.append("socketpair failed")
                continue
            }
            let initial = Array(bytes[..<split])
            let record = EgressProxy.readClientHello(client: socket.fd, initial: initial)
            socket.close()
            guard let record else { continue }
            let length = record.count >= 5 ? Int(record[3]) << 8 | Int(record[4]) : -1
            if record.count < 5 || record[0] != 0x16 || length > 16_384 || record.count < 5 + length
                || (initial + socket.delivered).starts(with: record) == false
            {
                failures.append("record reader returned \(record.count) bytes \(FuzzMutator.describe(bytes))")
            }
        }
        #expect(failures.isEmpty, "seed \(budget.seed): \(failures.count) failures, first \(failures.prefix(3))")
    }

    @Test(.timeLimit(.minutes(2)))
    func mutatedRequestLinesKeepProxyTargetInvariants() {
        let seeds = [
            "CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com\r\n\r\n",
            "POST http://127.0.0.1:10100/v1/messages HTTP/1.1\r\n\r\n",
            "GET http://example.com/ HTTP/1.0\r\n\r\n",
        ].map { Array($0.utf8) }
        let dictionary = [":", "@", "[", "]", "/", "?", "#", " ", "\r\n", "http://", "65536", "0", "-1", "é"]
            .map { Array($0.utf8) }
        let budget = FuzzBudget.resolve(defaultSeed: 0x7115_0004, defaultIterations: 20_000)
        var random = FuzzRandom(seed: budget.seed)
        var failures: [String] = []
        for _ in 0..<budget.iterations {
            let bytes = FuzzMutator.mutate(
                seeds.randomElement(using: &random)!, seeds: seeds, dictionary: dictionary,
                maxLength: 1_024, using: &random)
            let header = String(decoding: bytes, as: UTF8.self)
            for target in [EgressWire.parseCONNECT(header: header), EgressWire.parseAbsoluteHTTP(header: header)] {
                guard let target else { continue }
                if target.host.isEmpty || target.host.utf8.count > 253 || (1...65535).contains(target.port) == false
                    || target.host.contains(where: { "@[]/ ".contains($0) })
                {
                    failures.append("\(target) \(FuzzMutator.describe(bytes))")
                }
            }
        }
        #expect(failures.isEmpty, "seed \(budget.seed): \(failures.count) failures, first \(failures.prefix(3))")
    }
}
