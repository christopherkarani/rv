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
    /// `ghp_… x`, `ingest\ghp_…`, and `ingest#ghp_…`.
    public static func pathSegmentCarriesToken(_ segment: String) -> Bool {
        let decoded = repeatedDecode(segment)
        if looksLikeToken(decoded) { return true }
        let pieces = decoded.split { character in
            character == "." || character == "~" || character == "#" || character == "\\" || character == "/"
                || character.isWhitespace
        }
        return pieces.contains { looksLikeToken(String($0)) }
    }

    /// Percent-decode until the text stops changing, so `%253A` becomes `:`.
    public static func repeatedDecode(_ value: String) -> String {
        var current = value
        for _ in 0..<6 {
            guard current.contains("%"), let next = current.removingPercentEncoding, next != current else { return current }
            current = next
        }
        return current
    }

    /// Repeated percent-decode, then treat `\` as `/`.
    public static func slashNormalized(_ value: String) -> String {
        repeatedDecode(value).replacingOccurrences(of: "\\", with: "/")
    }

    /// `user:password@host`, including when it is only a path segment.
    public static func containsUserinfoSpelling(_ text: String) -> Bool {
        let decoded = repeatedDecode(text)
        for piece in decoded.split(whereSeparator: isMaterialSeparator) {
            guard let at = piece.firstIndex(of: "@"), at > piece.startIndex else { continue }
            let userinfo = piece[..<at]
            guard let colon = userinfo.firstIndex(of: ":"), colon > userinfo.startIndex, userinfo.index(after: colon) < at else {
                continue
            }
            return true
        }
        return false
    }

    /// A host label that is a token, or userinfo percent-decoded into the host.
    public static func hostCarriesSecret(_ host: String) -> Bool {
        let decoded = repeatedDecode(host)
        if containsUserinfoSpelling(decoded) { return true }
        return pathSegmentCarriesToken(decoded)
    }

    /// A path with a token segment, a decoded `#` token, a backslash token, or `user:secret@`.
    public static func pathCarriesSecret(_ path: String) -> Bool {
        let normalized = slashNormalized(path)
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
    /// A `postgres://user:pass@…` flag value is not this case; the review shows it.
    public static func argumentCarriesRefusedSecret(_ arg: String) -> Bool {
        var candidates = [arg]
        if arg.hasPrefix("-") {
            let body = arg.drop { $0 == "-" }
            if let equals = body.firstIndex(of: "=") {
                candidates.append(String(body[body.index(after: equals)...]))
            }
        }
        for candidate in candidates {
            let decoded = slashNormalized(candidate)
            if decoded.hasPrefix("//"), containsUserinfoSpelling(decoded) || urlCarriesSecret(decoded) { return true }
            if decoded.split(whereSeparator: { $0 == "/" || $0 == "#" }).contains(where: { pathSegmentCarriesToken(String($0)) }) {
                return true
            }
        }
        return false
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
        for item in components.queryItems ?? [] {
            if queryPieceCarriesSecret(item.name, depth: depth) || queryPieceCarriesSecret(item.value ?? "", depth: depth) {
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
        let queryLeak = (components.queryItems ?? []).contains { item in
            queryPieceCarriesSecret(item.name) || queryPieceCarriesSecret(item.value ?? "")
        }
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
