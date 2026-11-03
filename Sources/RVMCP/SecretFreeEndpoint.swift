#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Why a secret-free endpoint spelling is refused, as data. Adapters map
/// a kind to their own sentences; the classification itself never words a
/// refusal, so no sentence can echo the secret it refused.
public enum SecretFreeEndpointProblem: Sendable, Equatable {
    /// No scheme or no host to classify. The MCP adapter words this with
    /// its scheme sentence; the audit adapter asks for an absolute URL.
    case malformed
    /// Not https, and not http to a parsed loopback host.
    case scheme
    /// An IP host in a spelling `inet_pton` and a browser/`inet_aton`
    /// reader disagree on (short, one-integer, hex, leading-zero, zoned).
    case nonCanonicalHost
    case credentials
    case fragment
    case hostSecret
    case querySecret
    case pathSecret
    /// A `user:password@` spelling split across URL parts, so no per-part
    /// predicate sees it whole; only the raw spelling gives it away.
    case userinfoSpelling
}

/// The one endpoint classification module: https anywhere, http only to
/// parsed loopback, no credentials or fragment, and no secret hiding in
/// the host, query, path, or a split userinfo spelling. Its depth is the
/// leverage at this seam — `MCPRemoteServer.endpointProblem` (and through
/// it MCPOAuth) and audit forwarding's `destination` are thin adapters
/// over `problemKind`, each keeping its own sentences, so a spelling fix
/// lands once here instead of in two copied 7-predicate compositions.
/// First-problem order is the module's alone (REQ-T6): which kind a
/// multi-fault spelling reports may differ from either old copy.
public enum SecretFreeEndpoint {
    public static func problemKind(for url: URL) -> SecretFreeEndpointProblem? {
        problemKind(url: url, rawSpelling: url.absoluteString)
    }

    /// `rawSpelling` is the text as written, before `URL` normalization:
    /// the authority, raw-query, and split-userinfo predicates read
    /// spellings (`%40` in the authority, a `?` inside the password) that
    /// the parsed parts no longer show whole.
    public static func problemKind(url: URL, rawSpelling: String) -> SecretFreeEndpointProblem? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), let host = components.host, host.isEmpty == false
        else { return .malformed }
        if nonCanonicalIPSpelling(host) { return .nonCanonicalHost }
        guard scheme == "https" || (scheme == "http" && isLoopback(host)) else { return .scheme }
        if components.user != nil || components.password != nil { return .credentials }
        if components.fragment != nil { return .fragment }
        if MCPRedaction.hostCarriesSecret(host) || MCPRedaction.hostCarriesSecret(components.percentEncodedHost ?? "")
            || MCPRedaction.authorityCarriesPassword(rawSpelling)
        {
            return .hostSecret
        }
        let rawQuery = components.percentEncodedQuery ?? MCPRedaction.rawQuery(rawSpelling)
        if MCPRedaction.queryCarriesSecret(encoded: rawQuery, items: components.queryItems)
            || MCPRedaction.rawQuery(rawSpelling).map({ MCPRedaction.queryCarriesSecret(encoded: $0, items: nil) }) == true
        {
            return .querySecret
        }
        if MCPRedaction.pathCarriesSecret(components.percentEncodedPath) { return .pathSecret }
        // `user:/su?password@host` is split into a path and a query before
        // those checks; the raw spelling still reads as userinfo.
        if components.user == nil, components.password == nil,
            MCPRedaction.containsUserinfoSpelling(rawSpelling)
        {
            return .userinfoSpelling
        }
        return nil
    }

    /// Loopback by parsed address, not by string list: `127.1`,
    /// `2130706433`, `0x7f000001`, and `localhost.` are spellings browsers
    /// and `getaddrinfo` resolve to 127.0.0.1, so a literal list both
    /// misses real loopback and admits lookalikes. Non-canonical IP
    /// spellings are refused outright by `problemKind`.
    public static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if bare == "localhost" { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 {
            return (UInt32(bigEndian: v4.s_addr) >> 24) == 127
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, bare, &v6) == 1 {
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &v6, &text, socklen_t(text.count)) != nil else { return false }
            let canonical = String(cString: text)
            if canonical == "::1" { return true }
            if canonical.hasPrefix("::ffff:127.") { return true }
            return false
        }
        return false
    }

    /// An IP address written so `inet_pton` (and therefore rv) reads it one
    /// way while a browser's WHATWG parser or `inet_aton` reads it as
    /// another address: short forms, one-integer and hex forms, leading
    /// zeros, trailing dots, and IPv6 zone IDs.
    public static func nonCanonicalIPSpelling(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if bare.contains("@") { return false }
        // Zone IDs, named or numeric (`fe80::1%eth0`): only IPv6 literals
        // carry them, and inet_pton refuses them either way.
        if bare.contains("%"), bare.contains(":") { return true }
        if bare.contains(":"), bare.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" }) {
            var v6 = in6_addr()
            return inet_pton(AF_INET6, bare, &v6) != 1
        }
        // Any 0x-prefixed label (`0x7f.1`, `0x7f000001`) is an inet_aton
        // spelling of an address, never a DNS name worth accepting.
        if bare.split(separator: ".", omittingEmptySubsequences: false)
            .contains(where: { $0.hasPrefix("0x") && $0.count > 2 && $0.dropFirst(2).allSatisfy(\.isHexDigit) })
        {
            return true
        }
        let digitsAndDots = bare.isEmpty == false && bare.allSatisfy { $0.isNumber || $0 == "." }
        if digitsAndDots {
            var v4 = in_addr()
            guard inet_pton(AF_INET, bare, &v4) == 1 else { return true }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &v4, &text, socklen_t(text.count)) != nil else { return true }
            return String(cString: text) != bare
        }
        if bare.hasPrefix("0x") && bare.dropFirst(2).allSatisfy({ $0.isHexDigit }) && bare.count > 2 { return true }
        if bare.allSatisfy(\.isNumber) && bare.isEmpty == false { return true }
        return false
    }
}
