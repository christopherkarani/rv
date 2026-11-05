#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import RVDomain

/// Which catalog spelling a shell glob word can open. The shell expands
/// `cat .env*`, `cat {.env,x}`, and `head ~/.ss*/id_*` before the command
/// runs, so the literal word never names the secret the command reads.
///
/// Patterns follow the shell's own rule for dotfiles: a leading `.` must be
/// spelled (`*` never selects `.env`). A component of nothing but `*` and
/// `?` selects nothing here, so `cat *` and `rm -rf build/*` stay quiet;
/// a directory rule that is spelled literally (`~/.ssh/*`) already matches.
enum SecretPathGlob {
    /// Brace alternatives worth listing. Past it the word fails closed.
    static let expansionLimit = 1_024
    /// Spellings worth reporting for one word.
    static let selectionLimit = 16

    /// How a pattern selects names: the shell's own rule, or `find`'s.
    enum Matching: Sendable {
        /// A leading `.` must be spelled (`FNM_PERIOD`).
        case shell
        /// `find -name`/`-path`: `*` selects dotfiles too.
        case findName
        /// `find -iname`/`-ipath`: as `findName`, case-insensitive.
        case findNameFolded

        /// `FNM_PERIOD` is 0x04 and `FNM_CASEFOLD` 0x10 on Darwin and glibc.
        fileprivate var flags: Int32 {
            switch self {
            case .shell: return 0x04
            case .findName: return 0
            case .findNameFolded: return 0x10
            }
        }
    }

    /// Every catalog spelling `word` can select (up to `selectionLimit`), so
    /// an exemption on one (`.env`) never vouches for another (`.env.local`).
    static func selections(
        _ word: String,
        catalog: SecretPathCatalog,
        matching: Matching = .shell
    ) -> [String] {
        // Too many alternatives to prove none selects a secret: fail closed.
        // `find` patterns are fnmatch only; `{` is literal there.
        guard let globs = matching == .shell ? expandBraces(word, limit: expansionLimit) : [word] else {
            return representative(catalog).map { [$0] } ?? []
        }
        var found: [String] = []
        func add(_ path: String) {
            if found.count < selectionLimit, found.contains(path) == false { found.append(path) }
        }
        for glob in globs {
            if catalog.firstMatch(of: glob) != nil { add(glob) }
            let absolute = glob.hasPrefix("/")
            let parts = glob.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.isEmpty == false else { continue }
            for rule in catalog.rules {
                let spelled: [String]?
                switch rule.kind {
                case .basename(let name):
                    spelled = component(parts[parts.count - 1], selects: name, matching) ? Array(parts.dropLast()) + [name] : nil
                case .envVariant:
                    spelled = component(parts[parts.count - 1], selects: ".env.local", matching)
                        ? Array(parts.dropLast()) + [".env.local"] : nil
                case .homeSuffix(let suffix), .hostAuth(let suffix):
                    spelled = window(parts, selects: suffix, matching)
                }
                guard let spelled else { continue }
                let path = (absolute ? "/" : "") + spelled.joined(separator: "/")
                if catalog.firstMatch(of: path) != nil { add(path) }
            }
            if found.count >= selectionLimit { break }
        }
        return found
    }

    /// One concrete spelling of the catalog's first rule.
    private static func representative(_ catalog: SecretPathCatalog) -> String? {
        for rule in catalog.rules {
            let path: String
            switch rule.kind {
            case .basename(let name): path = name
            case .envVariant: path = ".env.local"
            case .homeSuffix(let parts), .hostAuth(let parts): path = "~/" + parts.joined(separator: "/")
            }
            if catalog.firstMatch(of: path) != nil { return path }
        }
        return nil
    }

    /// `parts` with the first run of components that can select `suffix`
    /// replaced by it.
    private static func window(
        _ parts: [String],
        selects suffix: [String],
        _ matching: Matching
    ) -> [String]? {
        guard suffix.isEmpty == false, parts.count >= suffix.count else { return nil }
        for start in 0...(parts.count - suffix.count) {
            let run = parts[start..<(start + suffix.count)]
            if zip(run, suffix).allSatisfy({ component($0, selects: $1, matching) }) {
                return Array(parts[..<start]) + suffix + Array(parts[(start + suffix.count)...])
            }
        }
        return nil
    }

    private static func component(_ pattern: String, selects name: String, _ matching: Matching) -> Bool {
        if pattern == name { return true }
        if matching == .findNameFolded, pattern.lowercased() == name.lowercased() { return true }
        guard pattern.contains(where: { "*?[\\".contains($0) }),
            pattern.contains(where: { $0 != "*" && $0 != "?" })
        else { return false }
        return fnmatch(pattern, name, matching.flags) == 0
    }

    /// Expands `{a,b}` groups (nested allowed) into plain globs; nil when the
    /// expansion would exceed `limit`. A group without a top-level comma is
    /// literal text in the shell, and stays as written.
    static func expandBraces(_ glob: String, limit: Int) -> [String]? {
        var pending = [glob]
        var done: [String] = []
        while let next = pending.popLast() {
            guard let group = firstGroup(in: next) else {
                done.append(next)
                continue
            }
            let (open, close, alternatives) = group
            let prefix = String(next[..<open])
            let suffix = String(next[next.index(after: close)...])
            for alternative in alternatives {
                pending.append(prefix + alternative + suffix)
            }
            if pending.count + done.count > limit { return nil }
        }
        return done
    }

    /// The first `{...}` group with a top-level comma, and its alternatives.
    private static func firstGroup(in text: String) -> (String.Index, String.Index, [String])? {
        var search = text.startIndex
        while let open = text[search...].firstIndex(of: "{") {
            var depth = 0
            var index = open
            var parts: [String] = []
            var current = ""
            var close: String.Index?
            while index < text.endIndex {
                let char = text[index]
                if char == "{" {
                    depth += 1
                    if depth > 1 { current.append(char) }
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        close = index
                        break
                    }
                    current.append(char)
                } else if char == ",", depth == 1 {
                    parts.append(current)
                    current = ""
                } else {
                    current.append(char)
                }
                index = text.index(after: index)
            }
            guard let close else { return nil }
            if parts.isEmpty == false {
                return (open, close, parts + [current])
            }
            search = text.index(after: open)
        }
        return nil
    }
}
