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
        let decoded = revealedDecode(segment)
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

    /// Strip by scalar. `U+200C`, `U+200D`, and grapheme extenders glue to the neighboring letter,
    /// so a `Character` filter would keep them. Variation selectors, including U+E0100–U+E01EF, glue
    /// the same way. C0 controls other than LF and CR, DEL, and C1 controls other than U+0085 are
    /// removed before a prefix or length check. U+0020 stays, so a space still separates two intact prefixes.
    private static func withoutInvisibleBreaks(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            if scalar.properties.isGraphemeExtend { return false }
            switch scalar.value {
            case 0x0000...0x0009, 0x000B...0x000C, 0x000E...0x001F, 0x007F, 0x0080...0x0084, 0x0086...0x009F:
                return false
            case 0x00A0, 0x00AD, 0x034F, 0x061C, 0x180B, 0x180C, 0x180D, 0x180E,
                0x2007, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2028, 0x2029, 0x202F, 0xFEFF:
                return false
            case 0x202A...0x202E, 0x2060...0x206F, 0xFE00...0xFE0F, 0xE0100...0xE01EF:
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

    /// Decode, then while stripping a byte joins `%` to the following hex, decode that
    /// spelling again. Each pass uses the same cap. `%%0067hp_` is `%` + NUL + `67hp_`
    /// until the NUL is gone, and a second NUL inside the next escape is the same step.
    /// A strip that does not unlock another escape keeps the spelling already in hand, so a
    /// variation selector after `://` is still visible to the userinfo check.
    private static func revealedDecode(_ value: String) -> PercentPass {
        var pass = percentDecode(value)
        if pass.stoppedEarly { return pass }
        for _ in 0..<decodeBound {
            let stripped = withoutInvisibleBreaks(pass.text)
            if stripped == pass.text { return pass }
            let again = percentDecode(stripped)
            if again.stoppedEarly { return again }
            if again.text == stripped { return pass }
            pass = again
        }
        let stripped = withoutInvisibleBreaks(pass.text)
        guard stripped != pass.text else { return pass }
        let again = percentDecode(stripped)
        if again.stoppedEarly || again.text != stripped {
            return PercentPass(text: pass.text, stoppedEarly: true)
        }
        return pass
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
        // `%%0040` is `@` only after a strip joins `%` to `40`. A nested scheme in a path or query uses that `@`.
        let decoded = revealedDecode(text)
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
    /// `%40` stays inside the host for `URLComponents`, so `password@host` never sets `user`.
    public static func hostCarriesSecret(_ host: String) -> Bool {
        let decoded = repeatedDecode(host)
        if decoded.contains("@") { return true }
        if containsUserinfoSpelling(decoded) { return true }
        return pathSegmentCarriesToken(decoded)
    }

    /// `https://password@host` after percent-decode, including `%40` and an encoded leading scheme.
    /// `https://user:password@host` is not this shape and stays visible on a non-secret flag.
    public static func authorityCarriesPassword(_ text: String) -> Bool {
        passwordSitsInAuthority(text)
    }

    /// A path with a token segment, a decoded `#` token, a backslash token, or `user:secret@`.
    public static func pathCarriesSecret(_ path: String) -> Bool {
        let decoded = revealedDecode(path)
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
            let pass = revealedDecode(candidate)
            if pass.stoppedEarly { return true }
            let decoded = pass.text.replacingOccurrences(of: "\\", with: "/")
            if decoded.hasPrefix("//"), containsUserinfoSpelling(decoded) || urlCarriesSecret(decoded) { return true }
            // `/:password@host` and `user:password@host` are not scheme URLs.
            // Authority userinfo on `postgres://user:pass@…` still stays, so the
            // review can show it. Path userinfo and a later `://` do not.
            // The raw spelling keeps `%2F` inside the user. The revealed spelling is what
            // `%%0040`, `%%002F`, and a tab hidden in `%00` become.
            if argumentUserinfoIsRefused(decoded) || passwordSitsInAuthority(candidate) || passwordSitsInAuthority(pass.text) {
                return true
            }
            if let query = rawQuery(decoded), queryCarriesSecret(encoded: query, items: nil) { return true }
            // A ctx7sk-, sk-, or ghp_ prefix returns before `/` or `#`. Decode
            // first. A prefix that also carries a path, fragment, userinfo, or
            // another secret is not stored. A bare token is ${secret:NAME}.
            // An encoded token the raw spelling would copy in the clear is refused.
            // The same prefix count as an env value, so a mark inside `ghp_` is a second token.
            if secretPrefixCount(decoded) >= 2 { return true }
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
    /// A nested scheme may use `\` for its slash, and an earlier `@` must not hide a later one.
    private static func argumentUserinfoIsRefused(_ decoded: String) -> Bool {
        let decoded = decoded.replacingOccurrences(of: "\\", with: "/")
        guard containsUserinfoSpelling(decoded) else { return false }
        guard let restStart = schemeAuthorityStart(decoded) else { return true }
        let rest = decoded[restStart...]
        var index = rest.startIndex
        while let at = rest[index...].firstIndex(of: "@") {
            let before = rest[..<at]
            if schemeSlashIgnoringLineBreaks(before) || before.hasSuffix(":") { return true }
            index = rest.index(after: at)
        }
        guard let slash = rest.firstIndex(of: "/") else { return false }
        return containsUserinfoSpelling(String(rest[slash...]))
    }

    /// `:/` with a tab, LF, or CR between the colon and the slash. U+0020 stays, so it still separates them.
    private static func schemeSlashIgnoringLineBreaks(_ text: Substring) -> Bool {
        var index = text.startIndex
        while let colon = text[index...].firstIndex(of: ":") {
            var next = text.index(after: colon)
            while next < text.endIndex, text[next] == "\t" || text[next] == "\n" || text[next] == "\r" {
                next = text.index(after: next)
            }
            if next < text.endIndex, text[next] == "/" { return true }
            index = text.index(after: colon)
        }
        return false
    }

    /// The authority of a leading `http://`, `https://`, `wss://`, or `postgres://` is
    /// `password@host`. `knownSchemeSlash` skips that one colon, so the user check never
    /// sees it. `user:password@host` still has a colon in the user part and is not this case.
    /// An encoded `/`, `\`, `?`, or `#` is still inside the user when `@` comes later: a raw
    /// delimiter ends the authority, and `host/@path` does not. `:password@host` is an empty user.
    private static func passwordSitsInAuthority(_ text: String) -> Bool {
        if rawUserinfoIsPassword(text) { return true }
        let pass = revealedDecode(text)
        if pass.text != text || pass.stoppedEarly {
            let revealed = pass.text.replacingOccurrences(of: "\\", with: "/")
            if rawUserinfoIsPassword(pass.text) || decodedPasswordSitsInAuthority(revealed) { return true }
            // An unfinished decode in a path is still a secret, but it is not this authority.
            return false
        }
        return decodedPasswordSitsInAuthority(slashNormalized(text))
    }

    /// Userinfo bounded by a raw `/`, `?`, or `#`. A raw `\` stays in the user: curl and Python
    /// keep it there, and Node drops a leading `\`. Extra `/` or `\` after the scheme, and a tab,
    /// LF, or CR in front of those, are still the scheme. An empty first `@` stays in the user.
    /// Percent-encoded delimiters stay in the user.
    private static func rawUserinfoIsPassword(_ text: String) -> Bool {
        let body = authorityBody(text)
        guard let schemeEnd = rawSchemeEnd(body) else { return false }
        var index = skipExtraAuthorityMarks(body, from: schemeEnd)
        let userStart = index
        while index < body.endIndex {
            if body[index] == "%", let after = indexAfterPercentEscape(body, index) {
                index = after
                continue
            }
            let character = body[index]
            if isAtSign(character) {
                let user = body[userStart..<index]
                if userinfoIsPasswordOnly(user) { return true }
                if user.isEmpty {
                    index = body.index(after: index)
                    continue
                }
                return false
            }
            if character == "/" || character == "?" || character == "#" { return false }
            index = body.index(after: index)
        }
        return false
    }

    /// `/`, `\`, or a tab, LF, or CR glued to the scheme. Node drops those and still reads the user.
    /// U+0020 is not one of these.
    private static func isExtraAuthorityMark(_ character: Character) -> Bool {
        character == "/" || character == "\\" || character == "\t" || character == "\n" || character == "\r"
    }

    private static func skipExtraAuthorityMarks(_ text: Substring, from index: String.Index) -> String.Index {
        var index = index
        while index < text.endIndex, isExtraAuthorityMark(text[index]) {
            index = text.index(after: index)
        }
        return index
    }

    /// `password@host`, `:password@host`, or a tab, LF, or CR in front of that colon.
    /// `user:password@host` and a space or VT in front of the colon stay visible.
    private static func userinfoIsPasswordOnly(_ user: Substring) -> Bool {
        guard user.isEmpty == false else { return false }
        var index = user.startIndex
        while index < user.endIndex, user[index] == "\t" || user[index] == "\n" || user[index] == "\r" {
            index = user.index(after: index)
        }
        let rest = user[index...]
        if rest.first == ":" { return true }
        return rest.contains(":") == false
    }

    private static func authorityBody(_ text: String) -> Substring {
        if text.hasPrefix("-"), let equals = text.firstIndex(of: "=") {
            return text[text.index(after: equals)...]
        }
        return Substring(text)
    }

    /// `scheme://`, `scheme:/\`, or `scheme:%2F%2F` at the start of the authority body.
    /// A `\` in the second slash is still the scheme. Node rewrites it to `/`.
    private static func rawSchemeEnd(_ body: Substring) -> String.Index? {
        for scheme in authoritySchemes {
            guard let schemeEnd = body.index(body.startIndex, offsetBy: scheme.count, limitedBy: body.endIndex),
                schemeEnd < body.endIndex,
                body[body.startIndex..<schemeEnd].lowercased() == scheme,
                body[schemeEnd] == ":"
            else { continue }
            let afterColon = body.index(after: schemeEnd)
            if let end = rawSlashPairEnd(body, afterColon) { return end }
        }
        return nil
    }

    /// Two scheme slashes. Each one may be `/`, `\`, or `%2F`.
    private static func rawSlashPairEnd(_ body: Substring, _ index: String.Index) -> String.Index? {
        guard let first = indexAfterSchemeSlash(body, index) else { return nil }
        return indexAfterSchemeSlash(body, first)
    }

    private static func indexAfterSchemeSlash(_ body: Substring, _ index: String.Index) -> String.Index? {
        guard index < body.endIndex else { return nil }
        if body[index] == "/" || body[index] == "\\" { return body.index(after: index) }
        return indexAfterEncodedSlash(body, index)
    }

    /// `@` plus U+FE0F, U+FE0E, U+034F, or U+200D is one grapheme, and that grapheme is not `"@"`.
    private static func isAtSign(_ character: Character) -> Bool {
        character.unicodeScalars.first?.value == 0x40
    }

    private static func indexAfterEncodedSlash(_ body: Substring, _ index: String.Index) -> String.Index? {
        guard let end = indexAfterPercentEscape(body, index), body[index..<end].lowercased() == "%2f" else { return nil }
        return end
    }

    private static func indexAfterPercentEscape(_ text: Substring, _ index: String.Index) -> String.Index? {
        guard text[index] == "%" else { return nil }
        guard let first = text.index(index, offsetBy: 1, limitedBy: text.endIndex), first < text.endIndex,
            let second = text.index(first, offsetBy: 1, limitedBy: text.endIndex), second < text.endIndex,
            hexNibble(text[first]) != nil, hexNibble(text[second]) != nil
        else { return nil }
        return text.index(after: second)
    }

    /// Decoded `password@host`, including a delimiter glued to `@`. A raw `host/@path` whose host
    /// has no dot stays visible. `:password@host` is refused here too.
    private static func decodedPasswordSitsInAuthority(_ decoded: String) -> Bool {
        guard let restStart = schemeAuthorityStart(decoded) else { return false }
        let rest = decoded[restStart...]
        var index = skipExtraAuthorityMarks(rest, from: rest.startIndex)
        let userStart = index
        while index < rest.endIndex {
            let character = rest[index]
            if isAtSign(character) {
                let user = rest[userStart..<index]
                if userinfoIsPasswordOnly(user) { return true }
                if user.isEmpty {
                    index = rest.index(after: index)
                    continue
                }
                return false
            }
            if character == "/" || character == "?" || character == "#" {
                var next = rest.index(after: index)
                while next < rest.endIndex, withoutInvisibleBreaks(String(rest[next])).isEmpty {
                    next = rest.index(after: next)
                }
                guard next < rest.endIndex, isAtSign(rest[next]) else { return false }
                let user = rest[..<index]
                let hostStart = rest.index(after: next)
                guard user.isEmpty == false, user.contains(":") == false else { return false }
                let hostEnd = rest[hostStart...].firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
                return rest[hostStart..<hostEnd].contains(".")
            }
            index = rest.index(after: index)
        }
        return false
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

    /// An env or header value that hides a second token prefix, or a token that
    /// appears only after percent-decode. A bare `ctx7sk-` or `sk-` still looks like
    /// a token and stays `${secret:NAME}`. An unfinished percent-decode is a secret
    /// even when the partial text is not a token.
    static func credentialHidesAnotherSecret(_ value: String) -> Bool {
        let pass = revealedDecode(value)
        if pass.stoppedEarly { return true }
        let decoded = withoutInvisibleBreaks(pass.text)
        if secretPrefixCount(decoded) >= 2 { return true }
        // `%67hp_` still contains `hp_`, so a raw prefix search is not enough.
        // A strip that does not form `%HH` leaves `pass.text` unchanged; the token is in `decoded`.
        // A bare `ctx7sk-` or `sk-` is unchanged on both, so it stays `${secret:NAME}`.
        if pass.text != value || decoded != pass.text {
            if looksLikeToken(decoded) || containsEmbeddedPrefix(decoded) { return true }
        }
        // Whitespace other than U+0020, a format scalar, and a spacing mark whose NFKD contains U+0020
        // join one `ghp_`. The prefix count stays 1. U+0020 stays, so `Bearer ` plus a token is still one secret reference.
        let joined = textJoiningHiddenBreaks(decoded)
        if joined != decoded, looksLikeToken(joined) || containsEmbeddedPrefix(joined) { return true }
        // The raw spelling keeps `%2F` inside the user. The revealed spelling is what `%%0040` becomes,
        // including a nested scheme and the same URL in a query.
        if passwordSitsInAuthority(value) || passwordSitsInAuthority(pass.text) { return true }
        if argumentUserinfoIsRefused(pass.text) { return true }
        guard looksLikeToken(decoded) else { return false }
        return hidesAnotherSecret(decoded)
    }

    /// Drop whitespace other than U+0020, a default-ignorable or format scalar, and a spacing mark
    /// whose NFKD contains U+0020 (U+00A8 and the other marks the prefix count already drops).
    /// `Bearer ` (U+0020) plus one token stays intact.
    private static func textJoiningHiddenBreaks(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            if scalar.value == 0x20 { return true }
            if scalar.properties.isWhitespace { return false }
            if scalar.properties.isDefaultIgnorableCodePoint { return false }
            if scalar.properties.generalCategory == .format { return false }
            if dropsForPrefixCount(scalar) { return false }
            return true
        }))
    }

    /// Separators dropped only for the prefix count. `-` and `_` stay, so `sk-` and `ctx7sk` still match.
    /// U+0020 is whitespace here and is not removed from the stored value.
    /// A compatibility twin (NFKD) of one of these separators is the same separator. U+037E is `;`.
    private static func textForPrefixCount(_ text: String) -> String {
        let scalars = withoutInvisibleBreaks(text).unicodeScalars.filter { scalar in
            if scalar.properties.isWhitespace { return false }
            return dropsForPrefixCount(scalar) == false
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// An ASCII scalar other than a letter, a digit, `-`, or `_` splits `ghp_`, the same way `$` and `#` do.
    /// U+0020 is whitespace and is not removed from the value. U+2044 and U+2215 are separators, so a
    /// vulgar fraction or a square sign whose NFKD contains one is dropped. A self-NFKD solidus or slash
    /// glyph is a separator, including U+2298 and U+2F03, as are U+2212, U+22C5, U+2219, U+02D7, and
    /// U+E002F. A self-NFKD box-drawing diagonal is a separator too: U+2571–U+2573, U+1FBA0–U+1FBAE,
    /// U+1FBBD–U+1FBBF, the block diagonals U+1FB3C–U+1FB67, and U+292B / U+292C. U+292F and U+2930
    /// are the diagonal crossings next to those. Saltires are separators too: U+1FBC0, U+2613, U+26DD,
    /// U+26DE, U+2B59, and U+1F7A8–U+1F7AE. U+2213, U+2214, U+2217, U+2218, U+22C6, U+22C7, and U+27CC sit
    /// next to those listed operators and are separators as well.
    /// A default-ignorable scalar such as U+E0001 is a separator too, as is a format scalar
    /// the property does not mark, including U+FFF9–U+FFFB. U+0020 is not one.
    /// Non-ASCII punctuation is a separator even when it folds to `-` or `_`. A decomposition that
    /// contains one of these separators is dropped too, including U+2025 (`..`) and U+2260.
    private static func dropsForPrefixCount(_ scalar: Unicode.Scalar) -> Bool {
        if isPrefixSeparator(scalar) { return true }
        let folded = String(scalar).decomposedStringWithCompatibilityMapping
        return folded.unicodeScalars.contains { isPrefixSeparator($0) }
    }

    private static func isPrefixSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2044, 0x2215, 0xFF0E,
            0x2216, 0x29F5, 0x29F6, 0x29F7, 0x29F8, 0x29F9, 0x2AFD, 0x2AFB, 0x1F67C, 0x1F67D,
            0x2212, 0x2213, 0x2214, 0x22C5, 0x22C6, 0x22C7, 0x2217, 0x2218, 0x2219, 0x02D7, 0xE002F,
            0x2298, 0x29B8, 0x233F, 0x2340, 0x2341, 0x2342, 0x2349, 0x244A,
            0x27C8, 0x27C9, 0x27CB, 0x27CC, 0x27CD, 0x292B, 0x292C, 0x292F, 0x2930, 0x29C4, 0x29C5, 0x2F03,
            0x2571...0x2573, 0x2613, 0x26DD, 0x26DE, 0x2B59, 0x1F7A8...0x1F7AE, 0x1FBA0...0x1FBAE,
            0x1FBBD...0x1FBC0, 0x1FB3C...0x1FB67:
            return true
        default:
            break
        }
        if scalar.properties.isDefaultIgnorableCodePoint { return true }
        // U+FFF9–U+FFFB are format and are not marked default-ignorable here.
        if scalar.properties.generalCategory == .format { return true }
        if scalar.isASCII == false, isPunctuation(scalar) { return true }
        guard scalar.isASCII else { return false }
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F:
            return false
        default:
            return true
        }
    }

    /// ASCII `-` and `_` are not punctuation here. `sk-` and `ghp_` still match.
    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
            .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    /// Known prefixes. A match leaves its last character in place, so `AKIA`/`AIza` share that
    /// character and both count. `sk-` inside `ctx7sk` does not start on the last character, so
    /// `ctx7sk-…` stays one prefix.
    /// Separators and whitespace are not part of a prefix. Dropping them for the count rejoins
    /// `g.hp_`, `g/hp_`, and `g hp_` without removing U+0020 from the value itself. A space
    /// between two intact prefixes still counts as two.
    private static func secretPrefixCount(_ text: String) -> Int {
        let text = textForPrefixCount(text)
        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if let match = tokenPrefixes.filter({ rest.hasPrefix($0) && rest.count >= $0.count + 8 })
                .max(by: { $0.count < $1.count })
            {
                count += 1
                let step = max(match.count - 1, 1)
                index = text.index(index, offsetBy: step)
            } else {
                index = text.index(after: index)
            }
        }
        return count
    }

    /// True when a token-shaped value also carries a path, fragment, userinfo, or a second token.
    private static func hidesAnotherSecret(_ decoded: String) -> Bool {
        let decoded = withoutInvisibleBreaks(decoded)
        if decoded.contains("/") || decoded.contains("#") || decoded.contains("|") || decoded.contains("@") { return true }
        if containsUserinfoSpelling(decoded) { return true }
        let pieces = decoded.split(whereSeparator: isTokenSeparator)
        if pieces.dropFirst().contains(where: { pathSegmentCarriesToken(String($0)) }) { return true }
        guard let prefix = leadingTokenPrefix(decoded) else { return containsEmbeddedPrefix(decoded) }
        let drop = prefix.count > 1 ? prefix.count - 1 : prefix.count
        return containsEmbeddedPrefix(String(decoded.dropFirst(drop)))
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
        let pass = revealedDecode(query)
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
        return (display, credential || hostLeaked || queryLeak || pathCarriesSecret(path) || authorityCarriesPassword(raw))
    }

    /// Names of env vars or headers that hold a literal credential.
    public static func literalCredentials(_ values: [String: String]) -> [String] {
        values.compactMap { name, value in
            guard value.isEmpty == false, isReference(value) == false else { return nil }
            return isSecretName(name) || looksLikeToken(value) ? name : nil
        }.sorted()
    }
}
