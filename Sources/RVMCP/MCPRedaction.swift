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

    /// A path segment that is a token, including `.ghp_…` and `ghp_… x`.
    public static func pathSegmentCarriesToken(_ segment: String) -> Bool {
        if looksLikeToken(segment) { return true }
        let pieces = segment.split { $0 == "." || $0.isWhitespace }
        return pieces.contains { looksLikeToken(String($0)) }
    }

    /// A query value that is itself a URL with userinfo, a fragment, a token
    /// path, or another nested secret. `//user:pass@host` counts.
    public static func urlCarriesSecret(_ value: String, depth: Int = 0) -> Bool {
        if depth > 4 { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("://") || trimmed.hasPrefix("//") else { return false }
        guard let components = URLComponents(string: trimmed), let host = components.host, host.isEmpty == false else {
            return false
        }
        if components.user != nil || components.password != nil || components.fragment != nil { return true }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath
        if path.split(separator: "/").contains(where: { pathSegmentCarriesToken(String($0)) }) { return true }
        for item in components.queryItems ?? [] {
            if isSecretName(item.name) || looksLikeToken(item.value ?? "") { return true }
            if let nested = item.value, urlCarriesSecret(nested, depth: depth + 1) { return true }
        }
        return false
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
        var display = "\(scheme)://\(host)"
        if let port = components.port { display += ":\(port)" }
        let path = components.percentEncodedPath
        if (path.isEmpty == false && path != "/") || components.percentEncodedQuery != nil {
            display += "/…"
        }
        let decoded = path.removingPercentEncoding ?? path
        let queryLeak = (components.queryItems ?? []).contains { item in
            isSecretName(item.name) || looksLikeToken(item.value ?? "") || urlCarriesSecret(item.value ?? "")
        }
        let pathLeak = decoded.split(separator: "/").contains { pathSegmentCarriesToken(String($0)) }
        let credential = components.user != nil || components.password != nil || components.fragment != nil
        return (display, credential || queryLeak || pathLeak)
    }

    /// Names of env vars or headers that hold a literal credential.
    public static func literalCredentials(_ values: [String: String]) -> [String] {
        values.compactMap { name, value in
            guard value.isEmpty == false, isReference(value) == false else { return nil }
            return isSecretName(name) || looksLikeToken(value) ? name : nil
        }.sorted()
    }
}
