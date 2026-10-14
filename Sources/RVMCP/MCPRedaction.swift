import Foundation

/// What `rv mcp list` may show about a host's server entry. Env and header
/// values never leave this type; args and URLs are shown with anything
/// credential-like replaced.
public enum MCPRedaction {
    public static let mask = "<redacted>"

    static let secretWords: Set<String> = [
        "TOKEN", "KEY", "APIKEY", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "CREDENTIALS",
        "AUTH", "AUTHORIZATION", "BEARER", "PAT", "COOKIE",
    ]

    static let tokenPrefixes = [
        "sk-", "sk_", "pk_live_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-",
        "xoxb-", "xoxp-", "xapp-", "AKIA", "ASIA", "AIza", "hf_", "ctx7sk", "npm_", "pplx-", "shpat_",
        "dop_v1_", "lin_api_", "phc_", "phx_", "ntn_", "secret_", "figd_", "sbp_", "eyJ",
    ]

    /// Env var, header or flag names that usually carry a credential.
    public static func isSecretName(_ name: String) -> Bool {
        let words = name.uppercased().split { $0.isLetter == false && $0.isNumber == false }
        return words.contains { secretWords.contains(String($0)) }
    }

    /// `${VAR}`, `$VAR`, `${env:VAR}`, `{env:VAR}`, `${input:id}`: a pointer, not a value.
    public static func isReference(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("${"), trimmed.hasSuffix("}") { return true }
        if trimmed.hasPrefix("{env:"), trimmed.hasSuffix("}") { return true }
        if trimmed.hasPrefix("$"), trimmed.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
            trimmed.count > 1
        {
            return true
        }
        return false
    }

    public static func looksLikeToken(_ value: String) -> Bool {
        if value.contains("://") || value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix(".") { return false }
        if value.contains(" ") { return false }
        if tokenPrefixes.contains(where: { value.hasPrefix($0) && value.count >= $0.count + 8 }) { return true }
        guard value.count >= 24, value.contains("/") == false, value.contains("@") == false else { return false }
        let allowed = value.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_.=+".unicodeScalars.contains($0)
        }
        let digits = value.filter(\.isNumber).count
        let letters = value.filter(\.isLetter).count
        return allowed && digits >= 4 && letters >= 4
    }

    /// A path segment that is a token, including `.ghp_…`, `~ghp_…`, `/opt/ghp_…`,
    /// `ghp_… x`, `ingest\ghp_…`, `ingest#ghp_…`, and a token after `;`, `?`,
    /// `&`, `:`, `,`, `|`, `@`, or a decoded NUL.
    public static func pathSegmentCarriesToken(_ segment: String) -> Bool {
        let decoded = percentDecode(segment)
        if decoded.stoppedEarly { return true }
        // Drop format characters and U+00A0 before the prefix and length checks.
        // A no-break space inside `ghp_` would otherwise leave a 23-character piece.
        let text = withoutInvisibleBreaks(decoded.text)
        if looksLikeToken(text) { return true }
        if text.split(whereSeparator: isTokenSeparator).contains(where: { looksLikeToken(String($0)) }) {
            return true
        }
        return containsEmbeddedPrefix(text)
    }

    /// A known prefix such as `ghp_` or `sk-` counts even when `_`, `+`, or `-` hides it.
    /// Zero-width characters are removed first so they cannot split `ghp_`.
    private static func containsEmbeddedPrefix(_ text: String) -> Bool {
        let text = withoutInvisibleBreaks(text)
        for prefix in tokenPrefixes {
            var search = text.startIndex
            while let range = text.range(of: prefix, range: search..<text.endIndex) {
                if text[range.lowerBound...].count >= prefix.count + 8 { return true }
                search = range.upperBound
            }
        }
        return false
    }

    /// Strip by scalar. `U+200C` and `U+200D` glue to the neighboring letter, so a `Character` filter would keep them.
    /// Format characters and U+00A0 are removed the same way, before a prefix or length check.
    /// U+0020 stays: a space between two prefixes is still scanned, and it is not glued into one token.
    private static func withoutInvisibleBreaks(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x00A0, 0x034F, 0x061C, 0x180E, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2060, 0x2061, 0x2062,
                0x2063, 0x2064, 0xFEFF:
                return false
            case 0x202A...0x202E, 0x2066...0x2069:
                return false
            default:
                return true
            }
        }))
    }

    /// Percent-decode to a fixed point. A dangling `%` does not stop the other
    /// escapes. If the bound is hit while an encoded separator remains, callers
    /// treat the value as a secret.
    public static func repeatedDecode(_ value: String) -> String {
        percentDecode(value).text
    }

    private static let decodeBound = 32

    private struct PercentPass {
        var text: String
        var stoppedEarly: Bool
    }

    private static func percentDecode(_ value: String) -> PercentPass {
        var current = value
        for _ in 0..<decodeBound {
            guard current.contains("%") else { return PercentPass(text: current, stoppedEarly: false) }
            let next = current.removingPercentEncoding ?? lenientPercentDecode(current)
            if next == current { return PercentPass(text: current, stoppedEarly: false) }
            current = next
        }
        // The bound was hit before a fixed point. A leftover `%09`, `%0A`, `%0D`,
        // or an encoded token is still a secret. Do not peek for a mark set.
        guard current.contains("%") else { return PercentPass(text: current, stoppedEarly: false) }
        let next = current.removingPercentEncoding ?? lenientPercentDecode(current)
        return PercentPass(text: current, stoppedEarly: next != current)
    }

    private static func isTokenSeparator(_ character: Character) -> Bool {
        character == "." || character == "~" || character == "#" || character == "\\" || character == "/"
            || character == ";" || character == "?" || character == "&" || character == ":" || character == ","
            || character == "|" || character == "@" || character == "=" || character == "+"
            || character == "\"" || character == "'" || character == "\u{200B}"
            || character == "\0" || character.isWhitespace
    }

    /// Decode every valid `%HH` and leave a `%` that is not an escape in place.
    private static func lenientPercentDecode(_ value: String) -> String {
        var output = ""
        var bytes: [UInt8] = []
        func flush() {
            guard bytes.isEmpty == false else { return }
            if let text = String(bytes: bytes, encoding: .utf8) {
                output += text
            } else {
                output += String(String.UnicodeScalarView(bytes.compactMap(Unicode.Scalar.init)))
            }
            bytes.removeAll(keepingCapacity: true)
        }
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "%",
                let first = value.index(index, offsetBy: 1, limitedBy: value.endIndex), first < value.endIndex,
                let second = value.index(first, offsetBy: 1, limitedBy: value.endIndex), second < value.endIndex,
                let high = hexNibble(value[first]), let low = hexNibble(value[second])
            {
                bytes.append((high << 4) | low)
                index = value.index(after: second)
                continue
            }
            flush()
            output.append(value[index])
            index = value.index(after: index)
        }
        flush()
        return output
    }

    private static func hexNibble(_ character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 48...57: return ascii - 48
        case 65...70: return ascii - 55
        case 97...102: return ascii - 87
        default: return nil
        }
    }

    /// Repeated percent-decode, then treat `\` as `/`.
    public static func slashNormalized(_ value: String) -> String {
        repeatedDecode(value).replacingOccurrences(of: "\\", with: "/")
    }

    /// `user:password@host`, including an empty user (`:password@host`) and a
    /// path segment that is only that spelling.
    public static func containsUserinfoSpelling(_ text: String) -> Bool {
        let decoded = percentDecode(text)
        if decoded.stoppedEarly { return true }
        if colonThenAt(decoded.text) { return true }
        for piece in decoded.text.split(whereSeparator: isMaterialSeparator) {
            guard let at = piece.firstIndex(of: "@"), at > piece.startIndex else { continue }
            let userinfo = piece[..<at]
            guard let colon = userinfo.firstIndex(of: ":"), colon < at else { continue }
            return true
        }
        return false
    }

    /// `http`, `https`, `wss`, and `postgres` followed by `://`. `user://` is not one of these.
    private static let authoritySchemes: Set<String> = ["http", "https", "wss", "postgres"]

    /// `:password@host` and `user:password@host`. The password may contain `&`,
    /// `#`, `?`, a space, a slash, or start with `@`. Two slashes are userinfo
    /// unless they are the leading `http`, `https`, `wss`, or `postgres` scheme.
    /// A later copy of those names, including inside a path, is not a scheme.
    private static func colonThenAt(_ decoded: String) -> Bool {
        var index = decoded.startIndex
        while index < decoded.endIndex {
            if decoded[index] == ":" {
                if knownSchemeSlash(decoded, colon: index) == false {
                    let atStart = index == decoded.startIndex
                    let afterSlash = index > decoded.startIndex && decoded[decoded.index(before: index)] == "/"
                    let afterUser = usernameEnds(decoded, at: index)
                    if atStart || afterSlash || afterUser {
                        let after = decoded.index(after: index)
                        if after < decoded.endIndex, let at = decoded[after...].firstIndex(of: "@"), at >= after {
                            return true
                        }
                    }
                }
            }
            index = decoded.index(after: index)
        }
        return false
    }

    /// The leading `http://`, `https://`, `wss://`, or `postgres://` only.
    /// The same spelling later in a path is userinfo. `user://` is not a scheme.
    /// A second slash that came from `%2F` or `\` is `//` only after normalization.
    private static func knownSchemeSlash(_ text: String, colon: String.Index) -> Bool {
        let after = text.index(after: colon)
        guard after < text.endIndex, text[after] == "/" else { return false }
        let second = text.index(after: after)
        guard second < text.endIndex, text[second] == "/" else { return false }
        var start = colon
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isLetter { start = previous } else { break }
        }
        guard start == text.startIndex, start < colon else { return false }
        return authoritySchemes.contains(text[start..<colon].lowercased())
    }

    private static func usernameEnds(_ text: String, at colon: String.Index) -> Bool {
        guard colon > text.startIndex else { return false }
        return text[text.index(before: colon)] != "/"
    }

    /// A host label that is a token, or userinfo percent-decoded into the host.
    public static func hostCarriesSecret(_ host: String) -> Bool {
        let decoded = repeatedDecode(host)
        if containsUserinfoSpelling(decoded) { return true }
        return pathSegmentCarriesToken(decoded)
    }

    /// A path with a token segment, a decoded `#` token, a backslash token, or `user:secret@`.
    public static func pathCarriesSecret(_ path: String) -> Bool {
        let decoded = percentDecode(path)
        if decoded.stoppedEarly { return true }
        let normalized = decoded.text.replacingOccurrences(of: "\\", with: "/")
        if containsUserinfoSpelling(normalized) { return true }
        return normalized.split(whereSeparator: { $0 == "/" || $0 == "#" }).contains { segment in
            let text = String(segment)
            return pathSegmentCarriesToken(text) || containsUserinfoSpelling(text)
        }
    }

    /// A query name or value: token, `.ghp_…`, `ghp_… x`, userinfo, or a nested URL.
    public static func queryPieceCarriesSecret(_ value: String, depth: Int = 0) -> Bool {
        if value.isEmpty { return false }
        let decoded = slashNormalized(value)
        if isSecretName(decoded) || looksLikeToken(decoded) || pathSegmentCarriesToken(decoded) { return true }
        if containsUserinfoSpelling(decoded) || pathCarriesSecret(decoded) { return true }
        return urlCarriesSecret(decoded, depth: depth + 1)
    }

    /// Protocol-relative `//user:pass@host`, or a path segment that is a token.
    /// A bare token (`ctx7sk-…`, `sk-…`) is not a path: import stores it as a
    /// keychain reference. A `postgres://user:pass@…` flag value is not this
    /// case either; the review shows it.
    public static func argumentCarriesRefusedSecret(_ arg: String) -> Bool {
        var candidates = [arg]
        if arg.hasPrefix("-") {
            let body = arg.drop { $0 == "-" }
            if let equals = body.firstIndex(of: "=") {
                candidates.append(String(body[body.index(after: equals)...]))
            }
        }
        for candidate in candidates {
            let pass = percentDecode(candidate)
            if pass.stoppedEarly { return true }
            let decoded = pass.text.replacingOccurrences(of: "\\", with: "/")
            if decoded.hasPrefix("//"), containsUserinfoSpelling(decoded) || urlCarriesSecret(decoded) { return true }
            // `/:password@host` and `user:password@host` are not scheme URLs.
            // Authority userinfo on `postgres://user:pass@…` still stays, so the
            // review can show it. Path userinfo and a later `://` do not.
            if argumentUserinfoIsRefused(decoded) { return true }
            if let query = rawQuery(decoded), queryCarriesSecret(encoded: query, items: nil) { return true }
            // A ctx7sk-, sk-, or ghp_ prefix returns before `/` or `#`. Decode
            // first. A prefix that also carries a path, fragment, userinfo, or
            // another secret is not stored. A bare token is ${secret:NAME}.
            // An encoded token the raw spelling would copy in the clear is refused.
            if looksLikeToken(decoded) {
                if hidesAnotherSecret(decoded) || looksLikeToken(candidate) == false { return true }
                continue
            }
            if decoded.split(whereSeparator: { $0 == "/" || $0 == "#" }).contains(where: { pathSegmentCarriesToken(String($0)) }) {
                return true
            }
        }
        return false
    }

    /// Path userinfo is refused. A plain `postgres://user:password@host` stays visible.
    /// `user://`, a password that starts with `/` or `@`, and path userinfo do not.
    private static func argumentUserinfoIsRefused(_ decoded: String) -> Bool {
        guard containsUserinfoSpelling(decoded) else { return false }
        guard let restStart = schemeAuthorityStart(decoded) else { return true }
        let rest = decoded[restStart...]
        if let at = rest.firstIndex(of: "@") {
            let before = rest[..<at]
            if before.contains(":/") || before.hasSuffix(":") { return true }
        }
        guard let slash = rest.firstIndex(of: "/") else { return false }
        return containsUserinfoSpelling(String(rest[slash...]))
    }

    /// Index just after `http://`, `https://`, `wss://`, or `postgres://`.
    private static func schemeAuthorityStart(_ decoded: String) -> String.Index? {
        var start = decoded.startIndex
        if decoded.hasPrefix("-"), let equals = decoded.firstIndex(of: "=") {
            start = decoded.index(after: equals)
        }
        guard let range = decoded[start...].range(of: "://") else { return nil }
        let scheme = decoded[start..<range.lowerBound]
        guard authoritySchemes.contains(scheme.lowercased()) else { return nil }
        return range.upperBound
    }

    /// An env or header value that hides a second token prefix.
    /// The scan runs even when `looksLikeToken` is false: a space, `://`, a leading
    /// `.` or `x`, or a tab still leaves two prefixes in one stored value.
    static func credentialHidesAnotherSecret(_ value: String) -> Bool {
        let pass = percentDecode(value)
        let decoded = withoutInvisibleBreaks(pass.text)
        if nonOverlappingPrefixCount(decoded) >= 2 { return true }
        guard looksLikeToken(decoded) else { return false }
        if pass.stoppedEarly { return true }
        return hidesAnotherSecret(decoded)
    }

    /// Known prefixes that do not overlap. `ctx7sk-…` is one prefix: the `sk-` inside it is not a second token.
    private static func nonOverlappingPrefixCount(_ text: String) -> Int {
        let text = withoutInvisibleBreaks(text)
        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if let match = tokenPrefixes.filter({ rest.hasPrefix($0) && rest.count >= $0.count + 8 })
                .max(by: { $0.count < $1.count })
            {
                count += 1
                index = text.index(index, offsetBy: match.count)
            } else {
                index = text.index(after: index)
            }
        }
        return count
    }

    /// True when a token-shaped value also carries a path, fragment, userinfo, or a second token.
    private static func hidesAnotherSecret(_ decoded: String) -> Bool {
        if decoded.contains("/") || decoded.contains("#") || decoded.contains("|") || decoded.contains("@") { return true }
        if containsUserinfoSpelling(decoded) { return true }
        let pieces = decoded.split(whereSeparator: isTokenSeparator)
        if pieces.dropFirst().contains(where: { pathSegmentCarriesToken(String($0)) }) { return true }
        guard let prefix = leadingTokenPrefix(decoded) else { return containsEmbeddedPrefix(decoded) }
        return containsEmbeddedPrefix(String(decoded.dropFirst(prefix.count)))
    }

    /// The longest known prefix at the start, so `ctx7sk-…` is not read as a shorter prefix.
    private static func leadingTokenPrefix(_ text: String) -> String? {
        tokenPrefixes.filter { text.hasPrefix($0) && text.count >= $0.count + 8 }
            .max(by: { $0.count < $1.count })
    }

    /// A query value that is itself a URL with userinfo, a fragment, a token
    /// path, or another nested secret. `//user:pass@host` counts. Backslashes
    /// and repeated percent-encoding are decoded first.
    public static func urlCarriesSecret(_ value: String, depth: Int = 0) -> Bool {
        if depth > 4 { return true }
        let trimmed = slashNormalized(value).trimmingCharacters(in: .whitespacesAndNewlines)
        // Userinfo is read from the text itself. A space or a second encoding layer
        // can make URLComponents fail before it would have set user and password.
        if containsUserinfoSpelling(trimmed) { return true }
        guard trimmed.contains("://") || trimmed.hasPrefix("//") else { return false }
        guard let components = URLComponents(string: trimmed), let host = components.host, host.isEmpty == false else {
            return pathCarriesSecret(trimmed)
        }
        if components.user != nil || components.password != nil || components.fragment != nil { return true }
        if hostCarriesSecret(host) { return true }
        if pathCarriesSecret(components.percentEncodedPath) { return true }
        if queryCarriesSecret(encoded: components.percentEncodedQuery ?? rawQuery(trimmed), items: components.queryItems, depth: depth) {
            return true
        }
        return false
    }

    /// The query string from `text`, including a dangling `%` that makes `queryItems` nil.
    public static func rawQuery(_ text: String) -> String? {
        guard let question = text.firstIndex(of: "?") else { return nil }
        let rest = text[text.index(after: question)...]
        if let hash = rest.firstIndex(of: "#") { return String(rest[..<hash]) }
        return String(rest)
    }

    /// Parsed items and the raw query. An invalid percent escape must not skip the query.
    public static func queryCarriesSecret(encoded: String?, items: [URLQueryItem]?, depth: Int = 0) -> Bool {
        if let encoded, encoded.isEmpty == false, queryTextCarriesSecret(encoded, depth: depth) { return true }
        for item in items ?? [] {
            if queryPieceCarriesSecret(item.name, depth: depth) || queryPieceCarriesSecret(item.value ?? "", depth: depth) {
                return true
            }
        }
        return false
    }

    private static func queryTextCarriesSecret(_ query: String, depth: Int) -> Bool {
        let pass = percentDecode(query)
        if pass.stoppedEarly { return true }
        let decoded = pass.text.replacingOccurrences(of: "\\", with: "/")
        // A raw `&`, `#`, or `?` inside `user:password@host` must be seen before the split.
        if containsUserinfoSpelling(decoded) || pathSegmentCarriesToken(decoded) { return true }
        for part in query.split(separator: "&", omittingEmptySubsequences: false) {
            let text = String(part)
            if let equals = text.firstIndex(of: "=") {
                let name = String(text[..<equals])
                let value = String(text[text.index(after: equals)...])
                if queryPieceCarriesSecret(name, depth: depth) || queryPieceCarriesSecret(value, depth: depth) { return true }
            } else if queryPieceCarriesSecret(text, depth: depth) {
                return true
            }
        }
        return false
    }

    private static func isMaterialSeparator(_ character: Character) -> Bool {
        character == "/" || character == "?" || character == "#" || character == "&" || character == "\\" || character.isWhitespace
    }

    /// Args with credentials masked, plus what was masked (flag names or positions).
    public static func args(_ args: [String]) -> (shown: [String], credentials: [String]) {
        var shown: [String] = []
        var credentials: [String] = []
        var maskNext: String?
        for (index, arg) in args.enumerated() {
            if let flag = maskNext, arg.hasPrefix("-") == false {
                shown.append(mask)
                credentials.append(flag)
                maskNext = nil
                continue
            }
            maskNext = nil
            if arg.hasPrefix("-") {
                let body = arg.drop { $0 == "-" }
                if let equals = body.firstIndex(of: "=") {
                    let flag = String(arg[arg.startIndex..<equals])
                    let value = String(body[body.index(after: equals)...])
                    if isSecretName(String(body[..<equals])) || looksLikeToken(value) {
                        shown.append(flag + "=" + mask)
                        credentials.append(flag)
                        continue
                    }
                } else if isSecretName(String(body)) {
                    maskNext = arg
                }
                shown.append(arg)
            } else if arg.contains("://") {
                let (display, leaked) = url(arg)
                shown.append(display)
                if leaked { credentials.append("argument \(index + 1) URL") }
            } else if looksLikeToken(arg) {
                shown.append(mask)
                credentials.append("argument \(index + 1)")
            } else {
                shown.append(arg)
            }
        }
        return (shown, credentials)
    }

    /// `scheme://host[:port]`, with `/…` when a path or query was dropped.
    /// `leaked` when the URL carries userinfo, a fragment, a token path, or a
    /// query value that is itself a secret or a URL carrying one.
    public static func url(_ raw: String) -> (display: String, leaked: Bool) {
        guard let components = URLComponents(string: raw), let scheme = components.scheme, let host = components.host else {
            return ("<url>", looksLikeToken(raw) || urlCarriesSecret(raw))
        }
        let hostLeaked = hostCarriesSecret(host)
        var display = hostLeaked ? "\(scheme)://…" : "\(scheme)://\(host)"
        if let port = components.port { display += ":\(port)" }
        let path = components.percentEncodedPath
        if (path.isEmpty == false && path != "/") || components.percentEncodedQuery != nil {
            display += "/…"
        }
        let encodedQuery = components.percentEncodedQuery ?? rawQuery(raw)
        let queryLeak = queryCarriesSecret(encoded: encodedQuery, items: components.queryItems)
            || rawQuery(raw).map { queryCarriesSecret(encoded: $0, items: nil) } == true
        let credential = components.user != nil || components.password != nil || components.fragment != nil
        return (display, credential || hostLeaked || queryLeak || pathCarriesSecret(path))
    }

    /// Names of env vars or headers that hold a literal credential.
    public static func literalCredentials(_ values: [String: String]) -> [String] {
        values.compactMap { name, value in
            guard value.isEmpty == false, isReference(value) == false else { return nil }
            return isSecretName(name) || looksLikeToken(value) ? name : nil
        }.sorted()
    }
}
