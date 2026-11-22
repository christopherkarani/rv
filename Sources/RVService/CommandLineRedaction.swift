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
/// - a flag named like a secret and its separate value:
///   `--password hunter2`, `--token x`, `--api-key x`, `-pass x`
/// - MySQL-family `-pVALUE` (`mysql -phunter2`)
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
        var atCommandStart = true
        var program: String?

        mutating func next(_ token: String) -> String {
            let quoted = Quoted(token)
            if let pending {
                self.pending = nil
                switch pending {
                case .value:
                    return quoted.replacingBody(with: placeholder)
                case .userPassword:
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
                atCommandStart = true
                program = nil
                return token
            }
            if atCommandStart {
                if quoted.body.contains("=") && quoted.body.hasPrefix("-") == false { return token }
                if Self.prefixWords.contains(quoted.body) { return token }
                program = (quoted.body as NSString).lastPathComponent
                atCommandStart = false
            }
            if token.hasSuffix(";") || token.hasSuffix("&&") || token.hasSuffix("|") {
                atCommandStart = true
            }
            return flag(quoted, token: token)
        }

        private mutating func flag(_ quoted: Quoted, token: String) -> String {
            let body = quoted.body
            guard body.hasPrefix("-"), body.count > 1 else { return token }
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
            if let program, Self.mysqlFamily.contains(program),
               body.hasPrefix("-p"), body.hasPrefix("--") == false, body.count > 2
            {
                return quoted.leading + "-p" + placeholder + quoted.trailing
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
        static let prefixWords: Set<String> = ["sudo", "env", "command", "exec", "nohup", "time", "nice"]
        static let userFlags: Set<String> = ["-u", "--user", "-U", "--proxy-user"]
        static let mysqlFamily: Set<String> = [
            "mysql", "mysqldump", "mysqladmin", "mysqlimport", "mysqlshow", "mysqlcheck", "mariadb",
            "mariadb-dump", "mariadb-admin",
        ]

        static func isSecretFlag(_ flag: String) -> Bool {
            let name = fold(String(flag.drop(while: { $0 == "-" })))
            if name.hasSuffix("_stdin") { return false }
            if ["pass", "pw", "pwd", "auth", "key"].contains(name) { return true }
            return secretFragments.contains { name.contains($0) }
        }

        static func isSecretHeader(_ name: String) -> Bool {
            let folded = fold(name.trimmingCharacters(in: .whitespaces))
            return (secretFragments + ["auth", "cookie", "session", "signature"]).contains { folded.contains($0) }
        }

        static let secretFragments = [
            "password", "passwd", "passphrase", "secret", "token", "authorization", "credential",
            "api_key", "apikey", "private_key", "privatekey", "access_key", "accesskey",
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
