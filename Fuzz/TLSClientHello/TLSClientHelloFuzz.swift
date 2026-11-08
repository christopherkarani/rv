// libFuzzer harness: the egress proxy's ClientHello / SNI binding.
// Build and run: docs/fuzzing.md. In-suite twin: ClientHelloFuzzTests.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import RVIsolation

@_cdecl("LLVMFuzzerTestOneInput")
public func rvFuzzTLSClientHello(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let bytes = Array(UnsafeBufferPointer(start: data, count: size))
    checkServerName(bytes)
    // First byte picks how much arrived with the CONNECT; the rest streams.
    if let first = bytes.first, bytes.count <= 17_000 {
        let rest = Array(bytes.dropFirst())
        checkRecordReader(initial: Array(rest.prefix(Int(first))), streamed: Array(rest.dropFirst(Int(first))))
    }
    let header = String(decoding: bytes, as: UTF8.self)
    for target in [EgressProxy.parseCONNECT(header: header), EgressProxy.parseAbsoluteHTTP(header: header)] {
        guard let target else { continue }
        precondition(target.host.isEmpty == false && target.host.utf8.count <= 253)
        precondition((1...65535).contains(target.port))
    }
    return 0
}

private func checkServerName(_ bytes: [UInt8]) {
    guard let name = EgressProxy.tlsServerName(bytes) else { return }
    precondition(name.isEmpty == false)
    precondition(bytes.count >= 9 && bytes[0] == 0x16 && bytes[5] == 0x01, "name from a non-ClientHello")
    precondition(EgressProxy.tlsServerName(bytes + [0, 0, 0, 5, 0]) == name, "trailing bytes changed the name")
    precondition(EgressAdmission.checkSNI(expectedHost: name, serverName: name) == nil)
}

private func checkRecordReader(initial: [UInt8], streamed: [UInt8]) {
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
    while sent < streamed.count {
        let count = streamed[sent...].withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }
        sent += count
    }
    close(fds[1])
    defer { close(fds[0]) }
    guard let record = EgressProxy.readClientHello(client: fds[0], initial: initial) else { return }
    precondition(record.count >= 5 && record[0] == 0x16)
    let length = Int(record[3]) << 8 | Int(record[4])
    precondition(length <= 16_384 && record.count >= 5 + length)
    precondition((initial + streamed.prefix(sent)).starts(with: record))
    checkServerName(record)
}
