import Foundation

/// Pure parsing and classification for the egress proxy: request-line
/// targets, TLS ClientHello SNI, DNS name comparison, and public-unicast
/// address checks. No sockets, no clocks, no state, so each function is
/// tested and fuzzed on its own (`EgressProxyTests`, `EgressDestinationCheckTests`,
/// `Fuzz/TLSClientHello`). `EgressProxy` does the I/O around them;
/// `EgressAdmission` decides with their results.
enum EgressWire {
    /// CONNECT target from a header block. Strict: exactly `CONNECT
    /// host:port HTTP/1.x`, one colon, no userinfo, brackets, path, query,
    /// or whitespace. Returns nil for anything else.
    static func parseCONNECT(header: String) -> (host: String, port: Int)? {
        guard let lineEnd = header.range(of: "\r\n") else { return nil }
        let parts = header[..<lineEnd.lowerBound].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "CONNECT",
            parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
        else {
            return nil
        }
        let authority = String(parts[1])
        guard authority.isEmpty == false,
            authority.contains("@") == false,
            authority.contains("[") == false,
            authority.contains("]") == false,
            authority.contains("/") == false,
            authority.contains("?") == false,
            authority.contains("#") == false
        else {
            return nil
        }
        let segments = authority.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 2 else { return nil }
        let host = segments[0]
        guard host.isEmpty == false, host.utf8.count <= 253 else { return nil }
        guard let port = Int(segments[1]), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    /// Absolute-URI request target from a header block (`POST
    /// http://127.0.0.1:10100/v1/messages HTTP/1.1`). Plain-HTTP clients
    /// (loopback gateways, MCP servers) speak this instead of CONNECT.
    /// Strict: http scheme only, ASCII-uppercase method, no userinfo or
    /// brackets, explicit or default (:80) port, HTTP/1.x. Policy decides
    /// relay vs deny in `serveRequest` (loopback plus filtered public).
    static func parseAbsoluteHTTP(header: String) -> (host: String, port: Int)? {
        guard let lineEnd = header.range(of: "\r\n") else { return nil }
        let parts = header[..<lineEnd.lowerBound].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard parts[0].isEmpty == false,
            parts[0].allSatisfy({ $0.asciiValue.map { $0 >= 65 && $0 <= 90 } ?? false })
        else {
            return nil
        }
        guard parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return nil }
        let target = String(parts[1])
        guard target.count > 7, target.lowercased().hasPrefix("http://") else { return nil }
        let rest = String(target.dropFirst(7))
        let authority = rest.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard authority.isEmpty == false,
            authority.contains("@") == false,
            authority.contains("[") == false,
            authority.contains("]") == false
        else {
            return nil
        }
        let segments = authority.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard segments.count <= 2 else { return nil }
        let host = segments[0]
        guard host.isEmpty == false, host.utf8.count <= 253 else { return nil }
        if segments.count == 2 {
            guard let port = Int(segments[1]), (1...65535).contains(port) else { return nil }
            return (host, port)
        }
        return (host, 80)
    }

    /// The SNI host_name of a TLS ClientHello record, parsed with every
    /// length checked against the buffer. Nil for anything malformed,
    /// truncated, or without a host_name — callers fail closed.
    static func tlsServerName(_ bytes: [UInt8]) -> String? {
        func at(_ index: Int) -> UInt8? { bytes.indices.contains(index) ? bytes[index] : nil }
        func u16(_ index: Int) -> Int? {
            guard let high = at(index), let low = at(index + 1) else { return nil }
            return Int(high) << 8 | Int(low)
        }
        guard at(0) == 0x16, let recordLength = u16(3), bytes.count >= 5 + recordLength else { return nil }
        guard at(5) == 0x01 else { return nil }
        // Bound every walk to the handshake message the server will parse,
        // not just the record: rv-visible bytes past the handshake end
        // must not satisfy the check.
        guard let b6 = at(6), let b7 = at(7), let b8 = at(8) else { return nil }
        let handshakeLength = Int(b6) << 16 | Int(b7) << 8 | Int(b8)
        guard handshakeLength == recordLength - 4 else { return nil }
        let handshakeEnd = 5 + 4 + handshakeLength
        var cursor = 5 + 4 + 2 + 32 // handshake header, client version, random
        guard let sessionLength = at(cursor).map(Int.init) else { return nil }
        cursor += 1 + sessionLength
        guard let suitesLength = u16(cursor) else { return nil }
        cursor += 2 + suitesLength
        guard let compressionLength = at(cursor).map(Int.init) else { return nil }
        cursor += 1 + compressionLength
        guard let extensionsLength = u16(cursor) else { return nil }
        cursor += 2
        let extensionsEnd = cursor + extensionsLength
        guard extensionsEnd <= handshakeEnd else { return nil }
        while cursor + 4 <= extensionsEnd {
            guard let kind = u16(cursor), let length = u16(cursor + 2) else { return nil }
            let dataStart = cursor + 4
            let dataEnd = dataStart + length
            guard dataEnd <= extensionsEnd else { return nil }
            if kind == 0x0000 {
                guard let listLength = u16(dataStart) else { return nil }
                var entry = dataStart + 2
                let listEnd = entry + listLength
                guard listEnd <= dataEnd else { return nil }
                while entry + 3 <= listEnd {
                    guard let nameType = at(entry), let nameLength = u16(entry + 1) else { return nil }
                    let nameStart = entry + 3
                    let nameEnd = nameStart + nameLength
                    guard nameEnd <= listEnd else { return nil }
                    if nameType == 0 {
                        let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
                        return name.isEmpty ? nil : name
                    }
                    entry = nameEnd
                }
                return nil
            }
            cursor = dataEnd
        }
        return nil
    }

    /// DNS equality ignoring case and one trailing dot per side.
    static func dnsNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ name: String) -> String {
            let lowered = name.lowercased()
            return lowered.hasSuffix(".") ? String(lowered.dropLast()) : lowered
        }
        return normalized(lhs) == normalized(rhs)
    }
}
