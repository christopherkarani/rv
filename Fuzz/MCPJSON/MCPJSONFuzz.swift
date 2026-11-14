// libFuzzer harness: the MCP gateway's line framing and JSON parser.
// Build and run: docs/fuzzing.md. In-suite twin: MCPJSONFuzzTests.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
@testable import RVMCP

@_cdecl("LLVMFuzzerTestOneInput")
public func rvFuzzMCPJSON(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let bytes = Array(UnsafeBufferPointer(start: data, count: size))
    checkDocument(bytes)
    if bytes.contains(10) || bytes.count > 64 * 1024 { checkLines(bytes) }
    return 0
}

/// The gateway's line default, `mcp.json`, and the lenient host configs.
private let modes: [(depth: Int, lenient: Bool)] = [(64, false), (16, false), (160, true)]

/// Accepted input serialises to one line, parses back to an equal value,
/// and serialises identically; a stricter mode's acceptance implies the
/// looser mode's, with the same value.
private func checkDocument(_ bytes: [UInt8]) {
    var accepted: [JSONValue?] = []
    for mode in modes {
        let value = try? JSONValue.parse(Data(bytes), maximumDepth: mode.depth, lenient: mode.lenient)
        accepted.append(value)
        guard let value else { continue }
        let compact = value.compactText
        precondition(compact.utf8.allSatisfy { $0 != 10 && $0 != 13 }, "compact text spans lines")
        guard let again = try? JSONValue.parse(compact, maximumDepth: mode.depth) else {
            preconditionFailure("compact text does not parse")
        }
        precondition(again == value, "compact text parses to a different value")
        precondition(again.compactText == compact, "compact text is not stable")
        precondition((try? JSONValue.parse(value.prettyText, maximumDepth: mode.depth)) == value, "pretty round trip")
        _ = value.domainValue
        _ = value.withExactNumbers()
    }
    if let strict = accepted[1] { precondition(accepted[0] == strict, "depth 16 accepted what depth 64 did not") }
    if let strict = accepted[0] { precondition(accepted[2] == strict, "lenient refused or changed strict input") }
}

/// `readLines` off a socket whose peer sent `bytes` and closed: LF framing,
/// one trailing CR stripped, empty lines skipped, the unterminated tail
/// delivered as is. Each line then goes through the parser.
private func checkLines(_ bytes: [UInt8]) {
    var fds: [Int32] = [-1, -1]
    #if os(Linux)
    let made = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    #else
    let made = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    #endif
    precondition(made == 0, "socketpair")
    var bufferSize: Int32 = 256 * 1024
    _ = setsockopt(fds[1], SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
    _ = setsockopt(fds[0], SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
    var sent = 0
    while sent < bytes.count {
        let count = bytes[sent...].withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }
        sent += count
    }
    close(fds[1])
    defer { close(fds[0]) }
    var lines: [[UInt8]] = []
    MCPGatewayRuntime.readLines(fds[0]) { lines.append(Array($0)) }
    var pieces = bytes.prefix(sent).split(separator: 10, omittingEmptySubsequences: false).map { Array($0) }
    let tail = pieces.removeLast()
    var expected: [[UInt8]] = []
    for var piece in pieces {
        if piece.last == 13 { piece.removeLast() }
        if piece.isEmpty == false { expected.append(piece) }
    }
    if tail.isEmpty == false { expected.append(tail) }
    precondition(lines == expected, "lines differ from LF framing")
    for line in lines { checkDocument(line) }
}
