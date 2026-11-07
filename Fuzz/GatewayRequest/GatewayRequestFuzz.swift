// libFuzzer harness: the secret gateway's request front end.
// Build and run: docs/fuzzing.md. In-suite twin: GatewayRequestFuzzTests.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
@testable import RVIsolation

@_cdecl("LLVMFuzzerTestOneInput")
public func rvFuzzGatewayRequest(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let bytes = Array(UnsafeBufferPointer(start: data, count: size))
    checkParse(bytes)
    if bytes.count <= 8_192 { checkReader(bytes) }
    return 0
}

private func checkParse(_ bytes: [UInt8]) {
    guard let head = GatewayRequestHead.parse(bytes) else { return }
    precondition(bytes.count <= GatewayRequestHead.maximumBytes, "oversized head accepted")
    precondition(head.method.utf8.allSatisfy { $0 >= 65 && $0 <= 90 } && head.method.isEmpty == false)
    precondition(head.target.hasPrefix("/"))
    precondition(head.headers.count <= GatewayRequestHead.maximumHeaders)
    for header in head.headers {
        precondition((header.name + header.value).utf8.allSatisfy { $0 != 13 && $0 != 10 && $0 != 0 })
    }
    var wire = "\(head.method) \(head.target) HTTP/1.1"
    for header in head.headers { wire += "\r\n\(header.name): \(header.value)" }
    precondition(GatewayRequestHead.parse(Array(wire.utf8)) == head, "serialize/parse round trip")
    if let route = GatewayRoute(target: head.target) {
        precondition(head.target == "/s/" + route.secret + route.remainder)
        precondition(route.remainder.contains("#") == false && route.remainder.split(separator: "/").contains("..") == false)
        if let url = route.upstreamURL(base: URL(string: "https://api.example.com/v1")!) {
            precondition(url.host == "api.example.com" && url.scheme == "https", "upstream escaped")
        }
    }
    let framing = gatewayBodyFraming(
        transferEncodings: head.headerValues("Transfer-Encoding"),
        contentLengths: head.headerValues("Content-Length"),
        maximum: 1_024
    )
    if case .fixed(let length) = framing { precondition((1...1_024).contains(length)) }
    _ = SecretPlaceholder.occurrences(in: bytes)
    _ = SecretPlaceholder.redactedPath(head.target)
}

/// Head then chunked body off a socket whose peer sent `bytes` and closed.
private func checkReader(_ bytes: [UInt8]) {
    var fds: [Int32] = [-1, -1]
    #if os(Linux)
    let made = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    #else
    let made = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    #endif
    precondition(made == 0, "socketpair")
    var bufferSize: Int32 = 64 * 1024
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
    let wire = Array(bytes.prefix(sent))
    let reader = GatewaySocket.Reader(fd: fds[0])
    guard let head = reader.readHead(limit: GatewayRequestHead.maximumBytes) else { return }
    precondition(wire.starts(with: head) && Array(wire.dropFirst(head.count).prefix(4)) == [13, 10, 13, 10])
    checkParse(head)
    if let body = reader.readChunked(limit: 1_024) { precondition(body.count <= 1_024) }
}
