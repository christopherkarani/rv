import Foundation

/// Credential redaction for a command line that rv keeps or shows as text:
/// rvd's live events and the local decision log (both through
/// `DecisionRedaction.command`), and `rv log` again on read. One
/// implementation: change it here, not in a caller.
///
/// On top of `ReviewSanitizer.redactCredentials` (`KEY=value` with a
/// secret-shaped key, known token prefixes, `Bearer x`, PEM blocks) it
/// hides the value of the command-line forms a credential travels in:
///
/// - URL userinfo: `https://bob:pw@host` → `https://bob:[redacted]@host`
/// - `-u` / `--user` / `--proxy-user` `name:password` → `name:[redacted]`
/// - a flag whose whole name is a secret's and its separate value:
///   `--password hunter2`, `--token x`, `--api-key x`, `-pass x`; a flag
///   where the value should be is never eaten
/// - `-ubob:pw` (curl's attached form)
/// - per-program password flags, wherever the program sits in the
///   segment: MySQL-family `-pVALUE`, `sshpass -p pw`, `docker login -p
///   pw`, `redis-cli -a pw`
/// - a header with a secret-shaped name: `-H 'X-Api-Key: v'`,
///   `--header=Authorization:Basic v`, `-H "Cookie: v w"`
///
/// It works on whitespace-separated tokens and keeps quotes and spacing,
/// so the shape of the command stays readable. Over-redaction is the
/// failure it accepts; a missed credential is the one it guards against.
package enum CommandLineRedaction {
    package static let placeholder = ReviewSanitizer.redactedPlaceholder

    package static func redact(_ command: String) -> String {
        // JSON-shaped values first (they may span tokens), then the token
        // scan on the quotes as written: the sanitizer takes a `Bearer`
        // value whole, closing quote and all, and a header value whose
        // quote is gone would run to the end. The scan does the sanitizer's
        // scheme rule itself (`Bearer x`, `Basic x`), on the words as
        // written. Known token prefixes go last, wherever they sit.
        var scan = Scan()
        let scanned = mapTokens(jsonSecretsRedacted(urlUserinfoRedacted(command))) { scan.next($0) }
        return tokenPrefixesRedacted(ReviewSanitizer.redactCredentials(in: scanned))
    }

    // MARK: - Token scan

    private enum Pending {
        /// The next token is a secret value (`--password hunter2`).
        case value
        /// The next token is `name:password` (`-u bob:hunter2`).
        case userPassword
        /// The next token starts a header (`-H 'Name: value'`).
        case header
        /// Tokens of a secret value a quote opened (a header's value, a
        /// quoted password), until the token holding `closing`; with no
        /// quote, this one token.
        case rest(closing: Character?)
    }

    private struct Scan {
        var pending: Pending?
        /// Words seen so far in this command segment (basenames), so a
        /// password flag is read in context wherever the program sits:
        /// `docker exec db mysql -pX`, `sudo -u root mysql -pX`,
        /// `sh -c "mysql -pX"`.
        var words: Set<String> = []
        /// The previous token's word, folded, as written (before any
        /// redaction): `bearer` makes the next token a secret.
        var previousWord = ""

        mutating func next(_ token: String) -> String {
            let quoted = Quoted(token)
            let afterScheme = Self.schemeWords.contains(previousWord)
            previousWord = Self.fold(quoted.body)
            if let pending {
                self.pending = nil
                switch pending {
                case .value, .userPassword:
                    // A flag where a value was expected: the earlier flag
                    // took none (a boolean, or a missing value). Never eat
                    // a flag; read this one as itself.
                    if Self.isFlag(quoted.body) || Self.separators.contains(quoted.body) { break }
                    continueQuote(quoted)
                    if case .value = pending { return quoted.replacingBody(with: placeholder) }
                    return quoted.redactingAfterColon()
                case .header:
                    return header(quoted)
                case .rest(let closing):
                    if let closing, quoted.trailing.contains(closing) == false {
                        self.pending = .rest(closing: closing)
                    }
                    return quoted.replacingBody(with: placeholder)
                }
            }
            if Self.separators.contains(quoted.body) {
                words = []
                return token
            }
            // `Bearer x`, `Basic x`, `token x`: the sanitizer's scheme rule,
            // on the words as written.
            if afterScheme, Self.isFlag(quoted.body) == false {
                continueQuote(quoted)
                return quoted.replacingBody(with: placeholder)
            }
            // `aws configure set aws_secret_access_key VALUE`.
            if Self.isFlag(quoted.body) == false, words.contains("configure"), Self.isSecretKey(quoted.body) {
                pending = .value
            }
            let shown = Self.isFlag(quoted.body) ? flag(quoted, token: token) : token
            if Self.isFlag(quoted.body) == false {
                words.insert((quoted.body as NSString).lastPathComponent)
            }
            if token.hasSuffix(";") || token.hasSuffix("&&") || token.hasSuffix("|") {
                words = []
            }
            return shown
        }

        /// A value token that opens a quote it does not close: the value
        /// runs on to the token that closes it (`-p 'my secret'`).
        private mutating func continueQuote(_ quoted: Quoted) {
            if let opening = quoted.leading.last, quoted.trailing.isEmpty {
                pending = .rest(closing: opening)
            }
        }

        private mutating func flag(_ quoted: Quoted, token: String) -> String {
            let body = quoted.body
            if body == "-H" || body == "--header" {
                pending = .header
                return token
            }
            if body.hasPrefix("--header=") {
                let value = String(body.dropFirst("--header=".count))
                return quoted.leading + "--header=" + header(Quoted(value)) + quoted.trailing
            }
            if Self.userFlags.contains(body) {
                pending = .userPassword
                return token
            }
            if let equals = body.firstIndex(of: "="), Self.userFlags.contains(String(body[..<equals])) {
                let name = body[...equals]
                let value = Quoted(String(body[body.index(after: equals)...]))
                return quoted.leading + name + value.redactingAfterColon() + quoted.trailing
            }
            // `-ubob:pw` (curl's attached form): only `name:password` hides.
            if body.hasPrefix("-u"), body.hasPrefix("--") == false, body.count > 2 {
                let value = Quoted(String(body.dropFirst(2)))
                return quoted.leading + "-u" + value.redactingAfterColon() + quoted.trailing
            }
            if let short = Self.shortPasswordFlag(in: words), body.hasPrefix(short), body.hasPrefix("--") == false {
                if body == short {
                    if Self.separateValueAllowed(short, words: words) { pending = .value }
                    return token
                }
                if Self.attachedValueAllowed(short, words: words) {
                    return quoted.leading + short + placeholder + quoted.trailing
                }
            }
            if body.contains("=") == false, Self.isSecretFlag(body) {
                pending = .value
            }
            return token
        }

        /// The token after `-H`: a whole `Name:value`, or `Name:` with the
        /// value in the tokens after it.
        private mutating func header(_ quoted: Quoted) -> String {
            let body = quoted.body
            guard let colon = body.firstIndex(of: ":") else { return quoted.text }
            let name = String(body[..<colon])
            guard Self.isSecretHeader(name) else { return quoted.text }
            let valueHere = body[body.index(after: colon)...].isEmpty == false
            // A quote this token opens and does not close: the value runs
            // on to the token that closes it.
            if let opening = quoted.leading.last, quoted.trailing.isEmpty {
                pending = .rest(closing: opening)
            } else if quoted.leading.isEmpty, valueHere == false {
                pending = .rest(closing: nil)
            }
            return valueHere ? quoted.leading + name + ":" + placeholder + quoted.trailing : quoted.text
        }

        /// Words after which the next token is a credential (HTTP auth
        /// schemes; `token` as gh and others spell it).
        static let schemeWords: Set<String> = ["bearer", "basic", "token", "digest"]

        /// A positional key that names a secret (`aws_secret_access_key`).
        static func isSecretKey(_ word: String) -> Bool {
            let folded = fold(word)
            return secretFlagNames.contains(folded)
                || ["secret", "password", "passwd", "token"].contains { folded.contains($0) }
        }

        static let separators: Set<String> = ["&&", "||", ";", "|", "&"]
        static let userFlags: Set<String> = ["-u", "--user", "-U", "--proxy-user"]
        static let mysqlFamily: Set<String> = [
            "mysql", "mysqldump", "mysqladmin", "mysqlimport", "mysqlshow", "mysqlcheck", "mariadb",
            "mariadb-dump", "mariadb-admin",
        ]

        static func isFlag(_ body: String) -> Bool {
            body.hasPrefix("-") && body.count > 1
        }

        /// The short flag that carries a password for a program seen in this
        /// segment: `-p` (MySQL family, `sshpass`, `docker|podman login`),
        /// `-a` (`redis-cli`).
        static func shortPasswordFlag(in words: Set<String>) -> String? {
            if words.isDisjoint(with: mysqlFamily) == false || words.contains("sshpass") { return "-p" }
            if words.contains("login"), words.contains("docker") || words.contains("podman") { return "-p" }
            if words.contains("redis-cli") { return "-a" }
            return nil
        }

        /// `-p VALUE` with a space: a password for `sshpass` and `docker
        /// login`; for MySQL a bare `-p` prompts and the next word is a
        /// database.
        static func separateValueAllowed(_ short: String, words: Set<String>) -> Bool {
            if short == "-a" { return true }
            return words.contains("sshpass") || words.contains("login")
        }

        static func attachedValueAllowed(_ short: String, words: Set<String>) -> Bool {
            short == "-a" || words.isDisjoint(with: mysqlFamily) == false || words.contains("sshpass")
                || words.contains("login")
        }

        /// A flag whose whole name says it carries a secret value. Whole
        /// names only: `--max-tokens`, `--secret-id`, `--no-password` and
        /// `--password-stdin` name no secret value.
        static func isSecretFlag(_ flag: String) -> Bool {
            secretFlagNames.contains(fold(String(flag.drop(while: { $0 == "-" }))))
        }

        static let secretFlagNames: Set<String> = [
            "password", "passwd", "pass", "pw", "pwd", "passphrase", "db_password", "admin_password",
            "secret", "client_secret", "api_secret", "app_secret", "secret_key", "secret_access_key",
            "token", "api_token", "auth_token", "access_token", "refresh_token", "bearer_token",
            "session_token", "id_token", "github_token", "oauth_token", "personal_access_token",
            "api_key", "apikey", "access_key", "access_key_id", "private_key", "auth", "authorization",
            "bearer", "oauth2_bearer", "aws_secret_access_key", "aws_session_token",
        ]

        static func isSecretHeader(_ name: String) -> Bool {
            let folded = fold(name.trimmingCharacters(in: .whitespaces))
            return headerFragments.contains { folded.contains($0) }
        }

        static let headerFragments = [
            "password", "passwd", "secret", "token", "auth", "credential", "api_key", "apikey",
            "access_key", "cookie", "session", "signature",
        ]

        static func fold(_ text: String) -> String {
            String(text.lowercased().map { $0 == "-" || $0 == "." ? "_" : $0 })
        }
    }

    /// A token split into its surrounding quotes and its body.
    private struct Quoted {
        let text: String
        let leading: String
        let body: String
        let trailing: String

        init(_ text: String) {
            self.text = text
            // A backslash-escaped quote (`\"` inside `bash -c "…"`) is a
            // quote too.
            let quotes: Set<Character> = ["'", "\"", "\\"]
            let lead = text.prefix(while: { quotes.contains($0) })
            let afterLead = text.dropFirst(lead.count)
            let trail = String(afterLead.reversed().prefix(while: { quotes.contains($0) }).reversed())
            leading = String(lead)
            body = String(afterLead.dropLast(trail.count))
            trailing = trail
        }

        func replacingBody(with replacement: String) -> String {
            leading + replacement + trailing
        }

        /// `name:password` keeps the name; a bare name is left alone.
        func redactingAfterColon() -> String {
            guard let colon = body.firstIndex(of: ":") else { return text }
            return leading + body[...colon] + placeholder + trailing
        }
    }

    // MARK: - Text helpers

    /// Words that start a known credential, wherever they sit: inside
    /// quotes, after `=`, `:` or `/`. Each must be followed by enough token
    /// characters to be one (`sk-learn` is a word, not a key).
    static let tokenPrefixes: [(prefix: String, minimumTail: Int)] = [
        ("github_pat_", 8), ("ghp_", 8), ("gho_", 8), ("ghu_", 8), ("ghs_", 8), ("ghr_", 8),
        ("sk-", 8), ("sk_live_", 8), ("sk_test_", 8), ("rk_live_", 8),
        ("xoxb-", 8), ("xoxp-", 8), ("xoxa-", 8), ("xoxr-", 8), ("xoxs-", 8), ("xoxe-", 8),
        ("glpat-", 8), ("npm_", 8), ("AKIA", 12), ("ASIA", 12),
    ]

    /// Each known token prefix at a word boundary, with the token
    /// characters after it, becomes the placeholder.
    private static func tokenPrefixesRedacted(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0
        func isTokenCharacter(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }
        while index < characters.count {
            let atBoundary = index == 0 || isTokenCharacter(characters[index - 1]) == false
            if atBoundary, let match = tokenPrefixes.first(where: { entry in
                let prefix = Array(entry.prefix)
                return characters.count - index >= prefix.count && Array(characters[index..<index + prefix.count]) == prefix
            }) {
                var end = index + match.prefix.count
                while end < characters.count, isTokenCharacter(characters[end]) { end += 1 }
                if end - index - match.prefix.count >= match.minimumTail {
                    output += placeholder
                    index = end
                    continue
                }
            }
            output.append(characters[index])
            index += 1
        }
        return output
    }

    /// A JSON value under a secret-named key (`{"token":"x"}`,
    /// `{"password": "x y"}`, and `{\"token\":\"x\"}` inside a quoted
    /// script) becomes the placeholder. A value whose closing quote never
    /// comes (the command was cut) is hidden to the end.
    private static func jsonSecretsRedacted(_ text: String) -> String {
        let characters = Array(text)
        guard characters.contains(":") else { return text }
        var output = ""
        var index = 0
        func isKeyCharacter(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber || "_.-".contains(character))
        }
        while index < characters.count {
            // `"` or `\"` opening a key.
            let escaped = characters[index] == "\\" && index + 1 < characters.count && characters[index + 1] == "\""
            guard characters[index] == "\"" || escaped else {
                output.append(characters[index])
                index += 1
                continue
            }
            let quoteWidth = escaped ? 2 : 1
            var cursor = index + quoteWidth
            let keyStart = cursor
            while cursor < characters.count, isKeyCharacter(characters[cursor]) { cursor += 1 }
            let key = String(characters[keyStart..<cursor])
            func quote(at position: Int) -> Bool {
                escaped
                    ? position + 1 < characters.count && characters[position] == "\\" && characters[position + 1] == "\""
                    : position < characters.count && characters[position] == "\""
            }
            guard key.isEmpty == false, quote(at: cursor) else {
                output.append(characters[index])
                index += 1
                continue
            }
            cursor += quoteWidth
            while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
            guard cursor < characters.count, characters[cursor] == ":" else {
                output += String(characters[index..<cursor])
                index = cursor
                continue
            }
            cursor += 1
            while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
            guard quote(at: cursor), Scan.isSecretKey(key) || Scan.isSecretHeader(key) else {
                output += String(characters[index..<cursor])
                index = cursor
                continue
            }
            let valueStart = cursor + quoteWidth
            var valueEnd = valueStart
            while valueEnd < characters.count, quote(at: valueEnd) == false {
                // In a plain JSON string, `\"` is an escaped quote, not the end.
                valueEnd += escaped == false && characters[valueEnd] == "\\" ? 2 : 1
            }
            output += String(characters[index..<valueStart]) + placeholder
            index = min(valueEnd, characters.count)
        }
        return output
    }

    /// `scheme://user:password@host` keeps the user and hides the
    /// password (up to the last `@` of the authority, so a password may
    /// itself contain `@`).
    private static func urlUserinfoRedacted(_ text: String) -> String {
        let ends: Set<Character> = ["/", "?", "#", "'", "\""]
        var result = ""
        var rest = Substring(text)
        while let scheme = rest.range(of: "://") {
            result += rest[..<scheme.upperBound]
            rest = rest[scheme.upperBound...]
            let authority = rest.prefix(while: { $0.isWhitespace == false && ends.contains($0) == false })
            if let at = authority.lastIndex(of: "@"), let colon = authority[..<at].firstIndex(of: ":") {
                result += authority[..<colon] + ":" + placeholder
                rest = rest[at...]
            }
        }
        return result + rest
    }

    /// Applies `transform` to each whitespace-separated token, keeping the
    /// whitespace as it was.
    private static func mapTokens(_ text: String, _ transform: (String) -> String) -> String {
        var output = ""
        var token = ""
        for character in text {
            if character.isWhitespace {
                if token.isEmpty == false {
                    output += transform(token)
                    token = ""
                }
                output.append(character)
            } else {
                token.append(character)
            }
        }
        if token.isEmpty == false { output += transform(token) }
        return output
    }
}
