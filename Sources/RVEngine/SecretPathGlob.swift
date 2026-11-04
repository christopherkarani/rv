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
    static let expansionLimit = 64

    /// `fnmatch`'s `FNM_PERIOD`: 0x04 on both Darwin and glibc.
    private static let leadingPeriod: Int32 = 0x04

    /// A catalog spelling `word` can select, or nil.
    static func selects(_ word: String, catalog: SecretPathCatalog) -> String? {
        // Too many alternatives to list: each brace group can be anything.
        let globs = expandBraces(word, limit: expansionLimit) ?? [bracesAsStars(word)]
        for glob in globs {
            if catalog.firstMatch(of: glob) != nil { return glob }
            let absolute = glob.hasPrefix("/")
            let parts = glob.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.isEmpty == false else { continue }
            for rule in catalog.rules {
                let spelled: [String]?
                switch rule.kind {
                case .basename(let name):
                    spelled = component(parts[parts.count - 1], selects: name) ? Array(parts.dropLast()) + [name] : nil
                case .envVariant:
                    spelled = component(parts[parts.count - 1], selects: ".env.local")
                        ? Array(parts.dropLast()) + [".env.local"] : nil
                case .homeSuffix(let suffix), .hostAuth(let suffix):
                    spelled = window(parts, selects: suffix)
                }
                guard let spelled else { continue }
                let path = (absolute ? "/" : "") + spelled.joined(separator: "/")
                if catalog.firstMatch(of: path) != nil { return path }
            }
        }
        return nil
    }

    /// `parts` with the first run of components that can select `suffix`
    /// replaced by it.
    private static func window(_ parts: [String], selects suffix: [String]) -> [String]? {
        guard suffix.isEmpty == false, parts.count >= suffix.count else { return nil }
        for start in 0...(parts.count - suffix.count) {
            let run = parts[start..<(start + suffix.count)]
            if zip(run, suffix).allSatisfy({ component($0, selects: $1) }) {
                return Array(parts[..<start]) + suffix + Array(parts[(start + suffix.count)...])
            }
        }
        return nil
    }

    private static func component(_ pattern: String, selects name: String) -> Bool {
        if pattern == name { return true }
        guard pattern.contains(where: { "*?[".contains($0) }),
            pattern.contains(where: { $0 != "*" && $0 != "?" })
        else { return false }
        return fnmatch(pattern, name, leadingPeriod) == 0
    }

    /// Outermost `{...}` groups as `*`.
    private static func bracesAsStars(_ word: String) -> String {
        var out = ""
        var depth = 0
        for char in word {
            if char == "{" {
                if depth == 0 { out.append("*") }
                depth += 1
            } else if char == "}", depth > 0 {
                depth -= 1
            } else if depth == 0 {
                out.append(char)
            }
        }
        return out
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
