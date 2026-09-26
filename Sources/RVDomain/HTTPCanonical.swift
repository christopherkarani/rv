import Foundation

/// HTTPS target after one parse. Policy and the dialer both use this value.
///
/// `classification` is derived from the address bytes or from the name rules.
/// A caller cannot mark a loopback address public.
public struct HTTPDestination: Hashable, Sendable, Equatable {
    public let host: String
    package let hostKind: HTTPHostKind
    public let port: Int
    public let path: String
    public let query: String?
    public let address: HTTPIPAddress?
    public let classification: HTTPAddressClass

    package init(
        host: String,
        hostKind: HTTPHostKind,
        port: Int,
        path: String,
        query: String?,
        address: HTTPIPAddress?
    ) {
        self.host = host
        self.hostKind = hostKind
        self.port = port
        self.path = path
        self.query = query
        if HTTPNames.isBlocked(host) {
            self.address = nil
            self.classification = .localName
            return
        }
        if let address {
            self.address = address
            self.classification = address.addressClass
        } else {
            self.address = nil
            self.classification = .reserved
        }
    }

    /// Public address that RV may dial. A blocked name never qualifies.
    public var isPublicPinned: Bool {
        guard HTTPNames.isBlocked(host) == false, let address else { return false }
        return address.isPublicGlobal && classification == .publicGlobal
    }

    public var origin: String {
        let shown = hostKind == .ipv6 ? "[\(host)]" : host
        return "https://\(shown):\(port)"
    }

    /// Scheme, host, port, and path. The query is omitted on purpose.
    public var auditedResource: String {
        origin + path
    }

    public var canonicalURL: String {
        guard let query else { return auditedResource }
        return auditedResource + "?" + query
    }

    public var requestTarget: String {
        guard let query else { return path }
        return path + "?" + query
    }

    public var hostHeader: String {
        switch hostKind {
        case .ipv6:
            return port == 443 ? "[\(host)]" : "[\(host)]:\(port)"
        case .dns, .ipv4:
            return port == 443 ? host : "\(host):\(port)"
        }
    }

    public func droppingQuery() -> HTTPDestination {
        HTTPDestination(
            host: host,
            hostKind: hostKind,
            port: port,
            path: path,
            query: nil,
            address: address
        )
    }
}

extension HTTPDestination: Codable {
    private enum CodingKeys: String, CodingKey {
        case host
        case hostKind
        case port
        case path
        case query
        case address
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let destination = HTTPDestination(
            host: try container.decode(String.self, forKey: .host),
            hostKind: try container.decode(HTTPHostKind.self, forKey: .hostKind),
            port: try container.decode(Int.self, forKey: .port),
            path: try container.decode(String.self, forKey: .path),
            query: try container.decodeIfPresent(String.self, forKey: .query),
            address: try container.decodeIfPresent(HTTPIPAddress.self, forKey: .address)
        )
        self = destination
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(hostKind, forKey: .hostKind)
        try container.encode(port, forKey: .port)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(query, forKey: .query)
        try container.encodeIfPresent(address, forKey: .address)
    }
}

/// Parsed request before DNS. A literal address is already pinned.
package struct HTTPCanonicalRequest: Sendable, Equatable {
    package var method: HTTPMethod
    package var host: String
    package var hostKind: HTTPHostKind
    package var port: Int
    package var path: String
    package var query: String?
    package var literalAddress: HTTPIPAddress?
    package var nameBlocked: Bool
}

package enum HTTPCanonicalError: Error, Sendable, Equatable {
    case malformed
    case unsupportedScheme
    case unsupportedMethod
}

public enum HTTPResolutionError: Error, Sendable, Equatable {
    case failed
    case empty
}

/// One admitted HTTPS GET. The fingerprint does not contain the query text.
public struct HTTPAction: Sendable, Equatable, Codable {
    public var fingerprint: ActionFingerprint
    public var method: HTTPMethod
    public var destination: HTTPDestination
    public var scope: ActionScope
    public var effects: ActionEffects
    public var resources: ActionResources

    package init(
        fingerprint: ActionFingerprint,
        method: HTTPMethod,
        destination: HTTPDestination,
        scope: ActionScope,
        effects: ActionEffects = ActionEffects(),
        resources: ActionResources = ActionResources()
    ) {
        self.fingerprint = fingerprint
        self.method = method
        self.destination = destination
        self.scope = scope
        self.effects = effects
        self.resources = resources
    }

    public func redactingQuery() -> HTTPAction {
        HTTPAction(
            fingerprint: fingerprint,
            method: method,
            destination: destination.droppingQuery(),
            scope: scope,
            effects: effects,
            resources: resources
        )
    }
}

/// Canonicalizes one request and attaches the address policy will judge.
///
/// `resolve` is not called for a literal address or a name blocked before lookup.
public func normalizeRuntimeHTTP(
    subject: RuntimeAdmissionSubject,
    method: String,
    url: String,
    resolve: (String) -> Result<[HTTPIPAddress], HTTPResolutionError>
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    let canonical: HTTPCanonicalRequest
    switch canonicalizeHTTP(method: method, url: url) {
    case .failure:
        return .failure(.failed)
    case .success(let value):
        canonical = value
    }
    let selection: HTTPAddressSelection
    if canonical.nameBlocked || canonical.literalAddress != nil {
        selection = .empty
    } else {
        switch resolve(canonical.host) {
        case .failure:
            return .failure(.failed)
        case .success(let addresses):
            selection = selectHTTPAddresses(addresses)
            if case .empty = selection {
                return .failure(.failed)
            }
        }
    }
    guard let action = makeRuntimeHTTPAction(
        subject: subject,
        canonical: canonical,
        resolved: selection
    ) else {
        return .failure(.failed)
    }
    return .success(.http(action))
}

/// Builds the action RV will authorize. DNS selection is ignored for literals
/// and for names that are blocked before lookup.
package func makeRuntimeHTTPAction(
    subject: RuntimeAdmissionSubject,
    canonical: HTTPCanonicalRequest,
    resolved: HTTPAddressSelection
) -> HTTPAction? {
    let address: HTTPIPAddress?
    if canonical.nameBlocked {
        address = nil
    } else if let literal = canonical.literalAddress {
        address = literal
    } else {
        switch resolved {
        case .empty:
            return nil
        case .pinned(let pinned):
            address = pinned
        case .forbidden(let forbidden):
            address = forbidden
        }
    }
    let destination = HTTPDestination(
        host: canonical.host,
        hostKind: canonical.hostKind,
        port: canonical.port,
        path: canonical.path,
        query: canonical.query,
        address: address
    )
    let token = canonical.query.map { HTTPDigest.sha256Hex(Array($0.utf8)) } ?? "none"
    let fingerprint = ActionFingerprint(
        rawValue: "runtime:\(subject.session.id.rawValue.uuidString):"
            + "\(subject.policyWorkspace.rawValue):http:GET:\(destination.auditedResource):q:\(token)"
    )
    return HTTPAction(
        fingerprint: fingerprint,
        method: canonical.method,
        destination: destination,
        scope: ActionScope(workingDirectory: subject.policyWorkspace)
    )
}

/// Canonicalizes one HTTPS URL. Unsupported schemes and methods fail here,
/// before DNS and before an HTTP action exists.
package func canonicalizeHTTP(
    method: String,
    url: String
) -> Result<HTTPCanonicalRequest, HTTPCanonicalError> {
    if method != HTTPMethod.get.rawValue {
        if isMethodToken(method) {
            return .failure(.unsupportedMethod)
        }
        return .failure(.malformed)
    }
    guard url.utf8.count <= HTTPEgressLimits.maxURLUTF8Bytes, url.isEmpty == false else {
        return .failure(.malformed)
    }
    if url.utf8.contains(where: { $0 > 127 || $0 < 0x21 || $0 == 0x7f }) {
        return .failure(.malformed)
    }
    if url.contains("\\") || url.contains("#") || url.contains("\"") || url.contains("<")
        || url.contains(">") || url.contains(" ")
    {
        return .failure(.malformed)
    }
    guard let separator = url.range(of: "://") else {
        return schemeFailure(String(url.prefix(while: { $0 != ":" })))
    }
    let scheme = String(url[..<separator.lowerBound])
    guard scheme.lowercased() == "https" else {
        return schemeFailure(scheme)
    }
    let remainder = url[separator.upperBound...]
    guard let authorityEnd = remainder.firstIndex(where: { $0 == "/" || $0 == "?" }) else {
        return parse(
            authority: String(remainder),
            tail: ""
        )
    }
    return parse(
        authority: String(remainder[..<authorityEnd]),
        tail: String(remainder[authorityEnd...])
    )
}

private func schemeFailure(_ scheme: String) -> Result<HTTPCanonicalRequest, HTTPCanonicalError> {
    if isMethodToken(scheme) {
        return .failure(.unsupportedScheme)
    }
    return .failure(.malformed)
}

private func isMethodToken(_ text: String) -> Bool {
    guard (1...20).contains(text.count) else { return false }
    return text.allSatisfy { character in
        guard let ascii = character.asciiValue else { return false }
        return (ascii >= 65 && ascii <= 90) || (ascii >= 97 && ascii <= 122)
    }
}

private func parse(
    authority: String,
    tail: String
) -> Result<HTTPCanonicalRequest, HTTPCanonicalError> {
    guard authority.isEmpty == false, authority.contains("@") == false else {
        return .failure(.malformed)
    }
    let host: ParsedHost
    do {
        host = try parseHost(authority)
    } catch {
        return .failure(.malformed)
    }
    let pathAndQuery: (String, String?)
    do {
        pathAndQuery = try parseTail(tail)
    } catch {
        return .failure(.malformed)
    }
    let request = HTTPCanonicalRequest(
        method: .get,
        host: host.name,
        hostKind: host.kind,
        port: host.port,
        path: pathAndQuery.0,
        query: pathAndQuery.1,
        literalAddress: host.literal,
        nameBlocked: host.nameBlocked
    )
    let probe = HTTPDestination(
        host: request.host,
        hostKind: request.hostKind,
        port: request.port,
        path: request.path,
        query: request.query,
        address: request.literalAddress
    )
    guard probe.canonicalURL.utf8.count <= HTTPEgressLimits.maxCanonicalUTF8Bytes else {
        return .failure(.malformed)
    }
    return .success(request)
}

private struct ParsedHost {
    var name: String
    var kind: HTTPHostKind
    var port: Int
    var literal: HTTPIPAddress?
    var nameBlocked: Bool
}

private struct HostParseError: Error {}

private func parseHost(_ authority: String) throws -> ParsedHost {
    if authority.hasPrefix("[") {
        guard let close = authority.firstIndex(of: "]") else { throw HostParseError() }
        let inner = String(authority[authority.index(after: authority.startIndex)..<close])
        let rest = authority[authority.index(after: close)...]
        guard inner.isEmpty == false, inner.contains("%") == false else { throw HostParseError() }
        guard let address = parseIPv6(inner) else { throw HostParseError() }
        let port = try parseHostPort(rest)
        return ParsedHost(
            name: address.presentation,
            kind: .ipv6,
            port: port,
            literal: address,
            nameBlocked: false
        )
    }
    let name: String
    let port: Int
    if let colon = authority.lastIndex(of: ":") {
        name = String(authority[..<colon])
        port = try parsePort(String(authority[authority.index(after: colon)...]))
    } else {
        name = authority
        port = 443
    }
    guard name.isEmpty == false, name.contains("%") == false else { throw HostParseError() }
    if looksNumeric(name) {
        guard let address = parseIPv4(name) else { throw HostParseError() }
        return ParsedHost(
            name: address.presentation,
            kind: .ipv4,
            port: port,
            literal: address,
            nameBlocked: false
        )
    }
    let dns = try parseDNS(name)
    return ParsedHost(
        name: dns.name,
        kind: .dns,
        port: port,
        literal: nil,
        nameBlocked: dns.blocked
    )
}

private func parseHostPort(_ rest: Substring) throws -> Int {
    if rest.isEmpty { return 443 }
    guard rest.first == ":" else { throw HostParseError() }
    return try parsePort(String(rest.dropFirst()))
}

private func parsePort(_ text: String) throws -> Int {
    guard text.count >= 1, text.count <= 5 else { throw HostParseError() }
    if text.count > 1, text.first == "0" { throw HostParseError() }
    guard text.allSatisfy(isASCIIDigit), let port = Int(text), (1...65_535).contains(port) else {
        throw HostParseError()
    }
    return port
}

private func looksNumeric(_ name: String) -> Bool {
    name.contains(".") && name.allSatisfy { isASCIIDigit($0) || $0 == "." }
}

private func parseDNS(_ raw: String) throws -> (name: String, blocked: Bool) {
    var name = raw
    if name.hasSuffix(".") {
        name.removeLast()
    }
    guard name.isEmpty == false, name.hasSuffix(".") == false, name.hasPrefix(".") == false else {
        throw HostParseError()
    }
    guard name.contains("..") == false, name.utf8.count <= 253 else { throw HostParseError() }
    guard name.allSatisfy({ $0.asciiValue != nil }) else { throw HostParseError() }
    name = name.lowercased()
    let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard labels.isEmpty == false, labels.allSatisfy({ $0.isEmpty == false }) else {
        throw HostParseError()
    }
    for label in labels {
        guard label.count <= 63 else { throw HostParseError() }
        guard label.first != "-", label.last != "-" else { throw HostParseError() }
        guard label.allSatisfy(isLDH) else { throw HostParseError() }
        if label.lowercased().hasPrefix("0x") { throw HostParseError() }
        if label.count > 1, label.first == "0", label.allSatisfy(isASCIIDigit) {
            throw HostParseError()
        }
    }
    if labels.allSatisfy({ $0.allSatisfy(isASCIIDigit) }) {
        throw HostParseError()
    }
    return (name, HTTPNames.isBlocked(name) || labels.count == 1)
}

private func parseTail(_ tail: String) throws -> (String, String?) {
    if tail.isEmpty {
        return ("/", nil)
    }
    let pathText: String
    let queryText: String?
    if tail.hasPrefix("?") {
        pathText = "/"
        queryText = String(tail.dropFirst())
    } else if tail.hasPrefix("/") {
        if let mark = tail.firstIndex(of: "?") {
            pathText = String(tail[..<mark])
            queryText = String(tail[tail.index(after: mark)...])
        } else {
            pathText = tail
            queryText = nil
        }
    } else {
        throw HostParseError()
    }
    let path = try normalizePath(pathText)
    let query = try queryText.map(normalizeQuery)
    return (path, query)
}

private func normalizePath(_ text: String) throws -> String {
    let decoded = try decodePercent(text, reject: [UInt8(ascii: "/"), UInt8(ascii: "\\"), UInt8(ascii: "?"), UInt8(ascii: "#")])
    guard let scalar = String(bytes: decoded, encoding: .utf8) else { throw HostParseError() }
    let removed = removeDotSegments(scalar)
    return encodePath(Array(removed.utf8))
}

private func normalizeQuery(_ text: String) throws -> String {
    let decoded = try decodePercent(text, reject: [UInt8(ascii: "#"), UInt8(ascii: "\\")])
    return encodeQuery(decoded)
}

private func decodePercent(_ text: String, reject: Set<UInt8>) throws -> [UInt8] {
    var output: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        let character = text[index]
        if character == "%" {
            guard let first = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
                let second = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
                second < text.endIndex,
                let byte = hexByte(text[first], text[second])
            else {
                throw HostParseError()
            }
            if byte < 0x20 || byte == 0x7f || reject.contains(byte) {
                throw HostParseError()
            }
            output.append(byte)
            index = text.index(after: second)
        } else {
            guard let ascii = character.asciiValue, ascii >= 0x21, ascii != UInt8(ascii: "\\") else {
                throw HostParseError()
            }
            output.append(ascii)
            index = text.index(after: index)
        }
    }
    return output
}

private func encodePath(_ bytes: [UInt8]) -> String {
    var text = ""
    for byte in bytes {
        if byte == UInt8(ascii: "/") || isUnreserved(byte) {
            text.append(Character(UnicodeScalar(byte)))
        } else {
            text += String(format: "%%%02X", byte)
        }
    }
    return text.isEmpty ? "/" : text
}

private func encodeQuery(_ bytes: [UInt8]) -> String {
    var text = ""
    for byte in bytes {
        if isUnreserved(byte) || isQuerySafe(byte) {
            text.append(Character(UnicodeScalar(byte)))
        } else {
            text += String(format: "%%%02X", byte)
        }
    }
    return text
}

private func isUnreserved(_ byte: UInt8) -> Bool {
    isASCIIDigit(Character(UnicodeScalar(byte)))
        || (byte >= 65 && byte <= 90)
        || (byte >= 97 && byte <= 122)
        || byte == UInt8(ascii: "-")
        || byte == UInt8(ascii: ".")
        || byte == UInt8(ascii: "_")
        || byte == UInt8(ascii: "~")
}

private func isQuerySafe(_ byte: UInt8) -> Bool {
    let allowed = Set<UInt8>([
        UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: ":"), UInt8(ascii: "@"),
        UInt8(ascii: "!"), UInt8(ascii: "$"), UInt8(ascii: "&"), UInt8(ascii: "'"),
        UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"),
        UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "="),
    ])
    return allowed.contains(byte)
}

private func hexByte(_ high: Character, _ low: Character) -> UInt8? {
    guard let left = hexValue(high), let right = hexValue(low) else { return nil }
    return (left << 4) | right
}

private func hexValue(_ character: Character) -> UInt8? {
    guard let ascii = character.asciiValue else { return nil }
    if ascii >= 48 && ascii <= 57 { return ascii - 48 }
    if ascii >= 65 && ascii <= 70 { return ascii - 55 }
    if ascii >= 97 && ascii <= 102 { return ascii - 87 }
    return nil
}

private func removeDotSegments(_ path: String) -> String {
    var input = path
    var output = ""
    while input.isEmpty == false {
        if input.hasPrefix("../") {
            input.removeFirst(3)
        } else if input.hasPrefix("./") {
            input.removeFirst(2)
        } else if input.hasPrefix("/./") {
            input.removeFirst(2)
        } else if input == "/." {
            input = "/"
        } else if input.hasPrefix("/../") {
            input.removeFirst(3)
            output = dropLastSegment(output)
        } else if input == "/.." {
            input = "/"
            output = dropLastSegment(output)
        } else if input == "." || input == ".." {
            input = ""
        } else if let next = input.dropFirst(input.hasPrefix("/") ? 1 : 0).firstIndex(of: "/") {
            output.append(contentsOf: input[..<next])
            input = String(input[next...])
        } else {
            output.append(contentsOf: input)
            input = ""
        }
    }
    if output.isEmpty { return "/" }
    return output
}

private func dropLastSegment(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    if slash == path.startIndex { return "" }
    return String(path[..<slash])
}

func parseIPv4(_ text: String) -> HTTPIPAddress? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var bytes: [UInt8] = []
    for part in parts {
        guard (1...3).contains(part.count) else { return nil }
        if part.count > 1, part.first == "0" { return nil }
        guard part.allSatisfy(isASCIIDigit), let value = Int(part), (0...255).contains(value) else {
            return nil
        }
        bytes.append(UInt8(value))
    }
    return HTTPIPAddress(ipv4: bytes)
}

func parseIPv6(_ text: String) -> HTTPIPAddress? {
    guard text.isEmpty == false, text.contains("%") == false else { return nil }
    guard let compression = text.range(of: "::") else {
        guard let groups = ipv6Groups(text), groups.count == 8 else { return nil }
        return HTTPIPAddress(ipv6: bytes(from: groups))
    }
    if text.range(of: "::", range: compression.upperBound..<text.endIndex) != nil {
        return nil
    }
    let leftText = String(text[..<compression.lowerBound])
    let rightText = String(text[compression.upperBound...])
    guard let left = ipv6Groups(leftText), let right = ipv6Groups(rightText) else { return nil }
    let missing = 8 - left.count - right.count
    guard missing >= 1 else { return nil }
    return HTTPIPAddress(ipv6: bytes(from: left + Array(repeating: 0, count: missing) + right))
}

private func ipv6Groups(_ text: String) -> [UInt16]? {
    if text.isEmpty { return [] }
    let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
    if pieces.contains(where: { $0.isEmpty }) { return nil }
    var values: [UInt16] = []
    for (index, piece) in pieces.enumerated() {
        if piece.contains(".") {
            guard index == pieces.count - 1, let address = parseIPv4(String(piece)) else { return nil }
            let bytes = address.bytes
            values.append((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            values.append((UInt16(bytes[2]) << 8) | UInt16(bytes[3]))
            continue
        }
        guard (1...4).contains(piece.count), let value = UInt16(piece, radix: 16) else { return nil }
        values.append(value)
    }
    return values
}

private func bytes(from groups: [UInt16]) -> [UInt8] {
    groups.flatMap { group in
        [UInt8(group >> 8), UInt8(group & 0xff)]
    }
}

private func isASCIIDigit(_ character: Character) -> Bool {
    guard let ascii = character.asciiValue else { return false }
    return ascii >= 48 && ascii <= 57
}

private func isLDH(_ character: Character) -> Bool {
    guard let ascii = character.asciiValue else { return false }
    return isASCIIDigit(character) || (ascii >= 97 && ascii <= 122) || ascii == 45
}

enum HTTPNames {
    private static let exact: Set<String> = [
        "localhost",
        "localhost.localdomain",
        "ip6-localhost",
        "ip6-loopback",
        "broadcasthost",
        "metadata",
        "metadata.google.internal",
        "metadata.goog",
        "host.docker.internal",
        "gateway.docker.internal",
        "kubernetes.default",
        "kubernetes.default.svc",
        "kubernetes.default.svc.cluster.local",
    ]

    private static let suffixes = [
        ".localhost",
        ".local",
        ".internal",
        ".localdomain",
        ".lan",
        ".home.arpa",
    ]

    static func isBlocked(_ host: String) -> Bool {
        let name = host.lowercased()
        if exact.contains(name) { return true }
        return suffixes.contains { name.hasSuffix($0) }
    }
}
