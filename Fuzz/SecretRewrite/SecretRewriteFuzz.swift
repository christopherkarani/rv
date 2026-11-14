// libFuzzer harness: the secret gateway's placeholder substitution and
// response scrubber. Build and run: docs/fuzzing.md. In-suite twin:
// SecretRewriteFuzzTests, which decodes the same layout and draws the same
// choices, so a crash file replays there through `violations(_:)`.
import Foundation
@testable import RVIsolation

/// `[mode][secret length][secret][pre length][pre][post]`. Mode bit 7 picks
/// the scrubber; otherwise its low three bits pick the substitution
/// position (mod 5: header, Basic user, Basic password, path, query) and
/// bit 3 the `sk-` prefix.
@_cdecl("LLVMFuzzerTestOneInput")
public func rvFuzzSecretRewrite(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let bytes = Array(UnsafeBufferPointer(start: data, count: size))
    guard bytes.count >= 2 else { return 0 }
    var index = 1
    func field() -> [UInt8] {
        guard index < bytes.count else { return [] }
        let end = min(bytes.count, index + 1 + Int(bytes[index]))
        defer { index = end }
        return Array(bytes[(index + 1)..<end])
    }
    let mode = bytes[0]
    let secret = field()
    let pre = field()
    let post = index < bytes.count ? Array(bytes[index...].prefix(1_024)) : []
    guard SecretValue(secret) != nil else { return 0 }
    if mode & 0x80 == 0 {
        checkSubstitution(mode: mode, secret: secret, pre: pre, post: post)
    } else {
        checkScrub(mode: mode, secret: secret, pre: pre, post: post, mix: Mix(bytes))
    }
    return 0
}

private let token = "0123456789abcdef0123456789abcdef"

/// SplitMix64 seeded by FNV-1a of the input; identical in the twin.
private struct Mix {
    var state: UInt64

    init(_ bytes: [UInt8]) {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        state = hash
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        bound <= 1 ? 0 : Int(next() % UInt64(bound))
    }
}

private func filler(_ bytes: [UInt8], dropping: String) -> String {
    var kept = String.UnicodeScalarView()
    for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars
    where dropping.unicodeScalars.contains(scalar) == false {
        kept.append(scalar)
    }
    return String(kept)
}

private func count(_ byte: UInt8, in bytes: some Sequence<UInt8>) -> Int {
    bytes.reduce(0) { $0 + ($1 == byte ? 1 : 0) }
}

// MARK: Substitution

/// A successful substitution keeps the request's shape whatever the
/// secret's bytes: no CR, LF or NUL in a header value, the same header
/// names, one request-line token with the same `?`/`#` split, no path
/// segment decoding to `..` that the placeholder's did not, the same query
/// separators, and the agent's Basic user/password split and line bytes.
private func checkSubstitution(mode: UInt8, secret: [UInt8], pre: [UInt8], post: [UInt8]) {
    let position = Int(mode & 0x07) % 5
    // KNOWN GAP ("." + "." -> ".." path case,
    // SecretRewriteFuzzTests.dotSecretBesideADotIsRefusedInAPath):
    // a "." secret completes an agent-written "." into "..". GatewayRoute
    // refuses that target before forwarding; skipped so new shapes still trap.
    if position == 3, secret == [46] { return }
    let prefix = mode & 0x08 == 0 ? "" : "sk-"
    let placeholder = prefix + "rvph_" + token
    var credentials: [UInt8]?
    var user = ""
    var password = ""
    let text: String
    switch position {
    case 0:
        text = "GET /s/KEY/v1 HTTP/1.1\r\nAuthorization: \(filler(pre, dropping: "\r\n\0"))"
            + "\(placeholder)\(filler(post, dropping: "\r\n\0"))\r\nX-Other: keep"
    case 1, 2:
        user = filler(pre, dropping: ":")
        password = filler(post, dropping: "")
        let decoded = position == 1 ? user + placeholder + ":" + password : user + ":" + placeholder + password
        credentials = Array(decoded.utf8)
        text = "GET /s/KEY/v1 HTTP/1.1\r\nAuthorization: Basic \(Data(decoded.utf8).base64EncodedString())"
    case 3:
        text = "GET /s/KEY/\(filler(pre, dropping: " \r\n\0?#"))\(placeholder)"
            + "\(filler(post, dropping: " \r\n\0?#")) HTTP/1.1\r\nX: y"
    default:
        text = "GET /s/KEY/v1?\(filler(pre, dropping: " \r\n\0#"))\(placeholder)"
            + "\(filler(post, dropping: " \r\n\0#")) HTTP/1.1\r\nX: y"
    }
    guard let value = SecretValue(secret), let head = GatewayRequestHead.parse(Array(text.utf8)),
        let route = GatewayRoute(target: head.target)
    else { return }
    let everything = GatewayAccessRule(methods: nil, path: "/**").map { [$0] } ?? []
    for rules in [[], everything] {
        let live = GatewaySubstitution.Live(
            token: token, secret: "KEY", prefix: prefix, value: value, surfaces: Set(GatewaySurface.allCases),
            rules: rules)
        guard case .success(let result) = GatewaySubstitution.apply(head, route: route, lookup: { $0 == token ? live : nil })
        else { continue }
        let rewritten = result.head
        precondition(rewritten.method == head.method, "method changed")
        precondition(rewritten.headers.map(\.name) == head.headers.map(\.name), "header names changed")
        for header in rewritten.headers {
            precondition(header.value.utf8.allSatisfy { $0 != 13 && $0 != 10 && $0 != 0 }, "header carries CR, LF or NUL")
        }
        let target = Array(rewritten.target.utf8)
        let before = Array(head.target.utf8)
        precondition(target.first == 47 && target.allSatisfy { $0 != 32 && $0 != 13 && $0 != 10 && $0 != 0 }, "target")
        for mark in Array("?#".utf8) { precondition(count(mark, in: target) == count(mark, in: before), "?/# count") }
        let cut = target.firstIndex(of: 63) ?? target.endIndex
        let beforeCut = before.firstIndex(of: 63) ?? before.endIndex
        let segments = target[..<cut].split(separator: 47, omittingEmptySubsequences: false)
        let beforeSegments = before[..<beforeCut].split(separator: 47, omittingEmptySubsequences: false)
        precondition(segments.count == beforeSegments.count, "path segment count changed")
        for (new, old) in zip(segments, beforeSegments) where Array(new) != Array(old) {
            precondition(GatewaySubstitution.percentDecoded(Array(new)) != [46, 46], "secret made a traversal segment")
        }
        for mark in Array("&=;+".utf8) {
            precondition(count(mark, in: target[cut...]) == count(mark, in: before[beforeCut...]), "query separators")
        }
        guard let credentials else { continue }
        guard let header = rewritten.header("Authorization"), header.hasPrefix("Basic "),
            let decoded = Data(base64Encoded: String(header.dropFirst(6)))
        else { preconditionFailure("Basic header unreadable") }
        let rewrittenCredentials = Array(decoded)
        for byte: UInt8 in [13, 10, 0] {
            precondition(count(byte, in: rewrittenCredentials) == count(byte, in: credentials), "Basic line bytes")
        }
        if position == 1 {
            let tail = [58] + Array(password.utf8)
            precondition(Array(rewrittenCredentials.suffix(tail.count)) == tail, "Basic password changed")
            precondition(rewrittenCredentials.firstIndex(of: 58) == rewrittenCredentials.count - tail.count, "split moved")
        } else {
            precondition(rewrittenCredentials.starts(with: Array(user.utf8) + [58]), "Basic user changed")
        }
    }
}

// MARK: Scrubber

private let placeholder = Array(("rvph_" + token).utf8)

private func hex(_ byte: UInt8, upper: Bool) -> [UInt8] {
    let digits = Array((upper ? "0123456789ABCDEF" : "0123456789abcdef").utf8)
    return [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
}

private func jsonUnit(_ unit: UInt16, mix: inout Mix) -> [UInt8] {
    let high = hex(UInt8(unit >> 8), upper: mix.below(2) == 0)
    let low = hex(UInt8(unit & 0xFF), upper: mix.below(2) == 0)
    return [92, 117] + high + low
}

/// `secret` in encoding `kind` and the run the scrubber must remove (nil
/// when too short to be covered): raw, percent, JSON-escaped, base64,
/// base64url, unpadded base64 (inside a blob at a random alignment),
/// contiguous hex, space-separated hex.
private func encode(_ secret: [UInt8], kind: Int, mix: inout Mix) -> (bytes: [UInt8], covered: [UInt8]?) {
    switch kind {
    case 1:
        var out: [UInt8] = []
        for byte in secret {
            switch mix.below(3) {
            case 0 where byte == 32: out.append(43)
            case 0, 1: out += [37] + hex(byte, upper: mix.below(2) == 0)
            default: out.append(byte)
            }
        }
        return (out, out)
    case 2:
        guard let text = String(validating: secret, as: UTF8.self) else { return (secret, secret) }
        var out: [UInt8] = []
        for scalar in text.unicodeScalars {
            let short: UInt8? = switch scalar {
            case "\"": 34
            case "\\": 92
            case "/": 47
            case "\n": 110
            case "\r": 114
            case "\t": 116
            case "\u{08}": 98
            case "\u{0C}": 102
            default: nil
            }
            let mustEscape = scalar == "\"" || scalar == "\\" || scalar.value < 0x20
            let choice = mix.below(3)
            if let short, choice == 0 || (mustEscape && choice == 2) {
                out += [92, short]
            } else if choice == 1 || mustEscape {
                for unit in String(scalar).utf16 { out += jsonUnit(unit, mix: &mix) }
            } else {
                out += Array(String(scalar).utf8)
            }
        }
        return (out, out)
    case 3, 4, 5:
        let lead = (0..<mix.below(6)).map { _ in UInt8(truncatingIfNeeded: mix.next()) }
        let tail = (0..<mix.below(6)).map { _ in UInt8(truncatingIfNeeded: mix.next()) }
        var text = Array(Data(lead + secret + tail).base64EncodedString().utf8)
        if kind == 4 { text = text.map { $0 == 43 ? 45 : $0 == 47 ? 95 : $0 } }
        if kind == 5 { text = text.filter { $0 != 61 } }
        let first = (8 * lead.count + 5) / 6
        let end = 8 * (lead.count + secret.count) / 6
        return (text, end - first >= 8 ? Array(text[first..<end]) : nil)
    case 6, 7:
        let upper = mix.below(2) == 0
        let text = Array(secret.map { hex($0, upper: upper) }.joined(separator: kind == 7 ? [32] : []))
        return (text, text.count >= 8 ? text : nil)
    default:
        return (secret, secret)
    }
}

private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard needle.isEmpty == false, haystack.count >= needle.count else { return false }
    for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
        if haystack[start..<(start + needle.count)].elementsEqual(needle) { return true }
    }
    return false
}

/// A needle that could only appear by touching a replacement the scrubber
/// wrote (inside, around, or across its edge) is not checked.
private func touchesReplacement(_ needle: [UInt8]) -> Bool {
    [placeholder, SecretScrubber.redactionMarker].contains { replacement in
        if contains(replacement, needle) || contains(needle, replacement) { return true }
        return (1...min(needle.count, replacement.count)).contains { k in
            needle.suffix(k).elementsEqual(replacement.prefix(k)) || needle.prefix(k).elementsEqual(replacement.suffix(k))
        }
    }
}

/// The secret in one to three covered encodings between `pre` and `post`,
/// cut into random chunks: the concatenated scrubbed output holds neither
/// the raw secret nor any covered run.
private func checkScrub(mode: UInt8, secret: [UInt8], pre: [UInt8], post: [UInt8], mix: Mix) {
    var mix = mix
    var body = pre
    var needles: [[UInt8]] = [secret]
    for index in 0..<(1 + mix.below(3)) {
        let kind = index == 0 ? Int(mode & 0x07) : mix.below(8)
        let form = encode(secret, kind: kind, mix: &mix)
        body += form.bytes
        if let covered = form.covered { needles.append(covered) }
        if mix.below(2) == 0 { body.append([32, 34, 44, 61, 10, 120][mix.below(6)]) }
    }
    body += post
    let byteAtATime = mix.below(4) == 0
    var scrubber = SecretScrubber([(needle: secret, replacement: placeholder)])
    var output: [UInt8] = []
    var index = 0
    while index < body.count {
        let left = body.count - index
        let size = byteAtATime ? 1 : 1 + mix.below(min(left, mix.below(2) == 0 ? 8 : 4_096))
        output += scrubber.process(Array(body[index..<(index + size)]))
        index += size
    }
    output += scrubber.finish()
    for needle in needles where touchesReplacement(needle) == false {
        precondition(contains(output, needle) == false, "scrubbed output still holds an encoded secret")
    }
}
