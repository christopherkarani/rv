import Foundation
import RVDomain

/// Claude tools that read or write files but are not `Read` / `Edit` / `Write`.
/// They route through the same file gate as their closest kind:
/// `Grep` / `Glob` read, `NotebookEdit` / `MultiEdit` edit.
///
/// Residual: a `Grep` / `Glob` with no `path` (defaults to cwd) and no
/// secret-named glob decodes as foreign and is allowed. A directory-wide
/// search (including a bare `*` / `**` glob) can still match inside
/// non-ignored secret files below that directory.
struct ClaudeSearchInput {
    var path: String?
    var pattern: String?
    var glob: String?
    var notebookPath: String?
    var filePath: String?
}

enum ClaudeSearchTarget {
    /// Maps a search/edit tool call onto a file action; nil means "not ours" or
    /// "nothing to gate" (cwd-wide benign search).
    static func action(toolName: String?, input: ClaudeSearchInput) -> FileToolAction? {
        switch toolName {
        case "Grep":
            return readAction(path: input.path, glob: input.glob)
        case "Glob":
            return readAction(path: input.path, glob: input.pattern)
        case "NotebookEdit":
            return FileToolAction.make(toolName: "Edit", filePath: input.notebookPath)
        case "MultiEdit":
            return FileToolAction.make(toolName: "Edit", filePath: input.filePath)
        default:
            return nil
        }
    }

    private static func readAction(path: String?, glob: String?) -> FileToolAction? {
        let explicit = path.flatMap { isBlank($0) ? nil : $0 }
        if let glob, let target = secretGlobTarget(glob) {
            return FileToolAction.make(toolName: "Read", filePath: join(explicit, target))
        }
        guard let explicit else { return nil }
        return FileToolAction.make(toolName: "Read", filePath: explicit)
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func join(_ directory: String?, _ name: String) -> String {
        guard let directory else { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// A concrete secret spelling the glob could select, or nil. Whole-glob
    /// directory rules (`.ssh/*`) match the glob text itself; basename rules
    /// match when the glob's last component can select a catalog name.
    static func secretGlobTarget(_ glob: String) -> String? {
        let catalog = SecretPathCatalog.dayOne
        let names = secretNames(catalog)
        // Too many alternatives to prove none selects a secret: fail closed.
        guard let globs = expandBraces(glob) else { return names.first }
        for expanded in globs {
            if catalog.firstMatch(of: expanded) != nil { return expanded }
            let last = lastComponent(expanded)
            if last.allSatisfy({ $0 == "*" }) { continue }
            if let name = names.first(where: { fnmatch(last, $0, 0) == 0 }) {
                return name
            }
        }
        return nil
    }

    private static func secretNames(_ catalog: SecretPathCatalog) -> [String] {
        var names: [String] = []
        for rule in catalog.rules {
            switch rule.kind {
            case .basename(let name):
                names.append(name)
            case .envVariant:
                names.append(".env.local")
            case .homeSuffix(let parts), .hostAuth(let parts):
                if let tail = parts.last { names.append(tail) }
            }
        }
        return names.filter { catalog.firstMatch(of: $0) != nil }
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    /// Expands `{a,b}` groups (nested allowed) into plain globs; nil when the
    /// expansion would exceed `limit`.
    static func expandBraces(_ glob: String, limit: Int = 64) -> [String]? {
        var pending = [glob]
        var done: [String] = []
        while let next = pending.popLast() {
            guard let open = next.firstIndex(of: "{"),
                  let close = matchingBrace(in: next, from: open)
            else {
                done.append(next)
                continue
            }
            let prefix = String(next[..<open])
            let suffix = String(next[next.index(after: close)...])
            let body = String(next[next.index(after: open)..<close])
            for alt in splitTopLevel(body) {
                pending.append(prefix + alt + suffix)
            }
            if pending.count + done.count > limit { return nil }
        }
        return done
    }

    private static func matchingBrace(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func splitTopLevel(_ body: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for char in body {
            if char == "{" { depth += 1 }
            if char == "}" { depth -= 1 }
            if char == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        parts.append(current)
        return parts
    }
}
