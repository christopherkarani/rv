import Foundation
import RVDomain

/// Credential redaction for a command line that leaves rvd as text (live
/// events now; the local decision log adopts it when J1b lands, so both
/// hide the same things). One implementation: change it here, not in a
/// caller.
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
        let base = ReviewSanitizer.redactCredentials(in: urlUserinfoRedacted(command))
        if base == placeholder { return base }
        var scan = Scan()
        return mapTokens(base) { scan.next($0) }
    }

    // MARK: - Token scan

    private enum Pending {
        /// The next token is a secret value (`--password hunter2`).
        case value
        /// The next token is `name:password` (`-u bob:hunter2`).
        case userPassword
        /// The next token starts a header (`-H 'Name: value'`).
        case header
        /// Tokens of a secret header's value, until `closing` (a quote) or,
        /// with no quote, this one token.
        case headerValue(closing: Character?)
    }

    private struct Scan {
        var pending: Pending?
        /// Words seen so far in this command segment (basenames), so a
        /// password flag is read in context wherever the program sits:
        /// `docker exec db mysql -pX`, `sudo -u root mysql -pX`,
        /// `sh -c "mysql -pX"`.
        var words: Set<String> = []

        mutating func next(_ token: String) -> String {
            let quoted = Quoted(token)
            if let pending {
                self.pending = nil
                switch pending {
                case .value, .userPassword:
                    // A flag where a value was expected: the earlier flag
                    // took none (a boolean, or a missing value). Never eat
                    // a flag; read this one as itself.
                    if Self.isFlag(quoted.body) || Self.separators.contains(quoted.body) { break }
                    if case .value = pending { return quoted.replacingBody(with: placeholder) }
                    return quoted.redactingAfterColon()
                case .header:
                    return header(quoted)
                case .headerValue(let closing):
                    if let closing, quoted.trailing.contains(closing) == false {
                        self.pending = .headerValue(closing: closing)
                    }
                    return quoted.replacingBody(with: placeholder)
                }
            }
            if Self.separators.contains(quoted.body) {
                words = []
                return token
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

        private mutating func flag(_ quoted: Quoted, token: String) -> String {
            let body = quoted.body
            if body == "-H" || body == "--header" {
                pending = .header
                return token
            }
            if body.hasPrefix("--header=") {
                let value = String(body.dropFirst("--header=".count))
                return quoted.leading + "--header=" + headerText(value) + quoted.trailing
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
                pending = .headerValue(closing: opening)
            } else if quoted.leading.isEmpty, valueHere == false {
                pending = .headerValue(closing: nil)
            }
            return valueHere ? quoted.leading + name + ":" + placeholder + quoted.trailing : quoted.text
        }

        private func headerText(_ value: String) -> String {
            guard let colon = value.firstIndex(of: ":") else { return value }
            let name = String(value[..<colon])
            return Self.isSecretHeader(name) ? name + ":" + placeholder : value
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
            let quotes: Set<Character> = ["'", "\""]
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
