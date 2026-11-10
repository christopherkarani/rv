/// Shared secret-path matching. Single matcher for `SecretPathCatalog` and `RulePinning`.
///
/// `SecretPathCatalog.firstMatch` is the declared single matcher; `RulePinning.secretPathHit`
/// must reuse the same predicate to avoid drift between the filesystem guard and the
/// allowlist hard-stop. This file owns the closed matching table.

import Foundation

/// A path component as the filesystem compares it: Unicode case-folded on
/// Darwin (default APFS is case-insensitive), as written elsewhere.
public func foldedPathComponent(_ component: String) -> String {
    #if canImport(Darwin)
    component.folding(options: .caseInsensitive, locale: nil)
    #else
    component
    #endif
}

// MARK: - Home alias

/// Whether `path` is exactly a home alias or has a trailing slash form.
/// Shared by `SecretPathCatalog`, `RulePinning`, and `RVEngine.analyzeFilesystem`.
public func isHomeAliasPath(_ path: String) -> Bool {
    path == "~" || path.hasPrefix("~/")
        || path == "$HOME" || path.hasPrefix("$HOME/")
        || path == "${HOME}" || path.hasPrefix("${HOME}/")
}

// MARK: - Kind matching (Sendable pure)

extension SecretPathKind {
    /// Returns whether `path` matches this catalog kind. Used by
    /// `SecretPathCatalog.firstMatch` and `RulePinning`. No I/O, no `Date()`.
    ///
    /// Case-insensitive on Darwin (`foldedPathComponent`): the default APFS
    /// volume opens `~/.SSH/authorized_keys` as `~/.ssh/authorized_keys`,
    /// and a Write to a not-yet-existing leaf has no realpath to fall back
    /// on. User allow-path exemptions are matched elsewhere and stay
    /// case-sensitive, so a variant spelling is never exempted by accident.
    public func matches(_ path: String) -> Bool {
        let path = foldedPathComponent(path)
        switch self {
        case .basename(let name):
            return lastPathComponent(path) == foldedPathComponent(name)
        case .envVariant:
            return isEnvVariant(lastPathComponent(path))
        case .homeSuffix(let parts), .hostAuth(let parts):
            return matchesHomeSuffix(path, parts: parts.map(foldedPathComponent))
        }
    }
}

// MARK: - Private helpers

private let envVariantExemptions: Set<String> = [
    ".env.example",
    ".env.sample",
    ".env.template",
    ".env.defaults",
]

private func lastPathComponent(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
}

private func isEnvVariant(_ name: String) -> Bool {
    guard name.hasPrefix(".env.") else { return false }
    if envVariantExemptions.contains(name) { return false }
    if name.hasPrefix(".env.example.") { return false }
    if name.hasPrefix(".env.sample.") { return false }
    return true
}

private func hasPathPrefix(_ candidate: String, prefix: String) -> Bool {
    candidate == prefix || candidate.hasPrefix(prefix + "/")
}

private func containsContiguous(_ haystack: [String], _ needle: [String]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    let lastStart = haystack.count - needle.count
    var start = 0
    while start <= lastStart {
        var matched = true
        var offset = 0
        while offset < needle.count {
            if haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            offset += 1
        }
        if matched { return true }
        start += 1
    }
    return false
}

/// Conservative suffix matcher: any contiguous occurrence of `parts` in the path
/// counts, regardless of repository boundary. Intentionally over-denies
/// (e.g. `/tmp/.password-store/foo` is treated as protected) per
/// "Conservative extra host-secret shapes". Anchoring to a home root would be
/// more precise but risks missing exfiltrated copies.
private func matchesHomeSuffix(_ candidate: String, parts: [String]) -> Bool {
    if parts == rvConfigParts, isCageScratchPath(candidate) { return false }
    let joined = parts.joined(separator: "/")
    if hasPathPrefix(candidate, prefix: "~/" + joined) { return true }
    for home in ["$HOME/", "${HOME}/"].map(foldedPathComponent)
    where hasPathPrefix(candidate, prefix: home + joined) {
        return true
    }
    let components = candidate.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    return containsContiguous(components, parts)
}

private let rvConfigParts = [".config", "rv"]

/// A caged agent's own `$HOME`, `$XDG_CACHE_HOME` and `$TMPDIR` live at
/// `~/.config/rv/workspaces/<id>/{home,cache,tmp}` (`WorkspaceDeveloperHome`),
/// and the cage still runs rv's file-tool hooks, so the rv-config rule must
/// not deny them. Only that exact shape is exempt: the first `.config/rv`
/// must be followed by `workspaces/<id>/{home|cache|tmp}/...`, and a path
/// with a `.`/`..` component is never exempt (it could climb back out).
/// `bin` (rv-owned shims), the workspace root, and everything else under
/// the rv config dir stay protected. Symlinks are handled by the caller's
/// resolved spelling.
private func isCageScratchPath(_ candidate: String) -> Bool {
    let components = candidate.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard components.contains(where: { $0 == "." || $0 == ".." }) == false,
        let start = firstContiguousIndex(components, rvConfigParts)
    else { return false }
    let rest = components.dropFirst(start + rvConfigParts.count)
    guard rest.count >= 3, rest[rest.startIndex] == "workspaces" else { return false }
    let area = rest[rest.startIndex + 2]
    return area == "home" || area == "cache" || area == "tmp"
}

private func firstContiguousIndex(_ haystack: [String], _ needle: [String]) -> Int? {
    guard haystack.count >= needle.count else { return nil }
    return (0...(haystack.count - needle.count)).first { start in
        Array(haystack[start..<(start + needle.count)]) == needle
    }
}
