/// Shared secret-path matching. Single matcher for `SecretPathCatalog` and `RulePinning`.
///
/// `SecretPathCatalog.firstMatch` is the declared single matcher; `RulePinning.secretPathHit`
/// must reuse the same predicate to avoid drift between the filesystem guard and the
/// allowlist hard-stop. This file owns the closed matching table.

// MARK: - Home alias

/// Whether `path` is exactly a home alias or has a trailing slash form.
/// Shared by `SecretPathCatalog`, `RulePinning`, and `RVEngine.analyzeFilesystem`.
public func isHomeAliasPath(_ path: String) -> Bool {
    path == "~" || path.hasPrefix("~/")
        || path == "$HOME" || path.hasPrefix("$HOME/")
        || path == "${HOME}" || path.hasPrefix("${HOME}/")
}

// MARK: - Kind matching (Sendable pure)

/// Pure matcher for a single `SecretPathKind`. Used by `SecretPathCatalog.firstMatch`
/// and `RulePinning.secretPathHit`. No I/O, no `Date()`.
public func secretPathKindMatches(_ candidate: String, _ kind: SecretPathKind) -> Bool {
    switch kind {
    case .basename(let name):
        return lastPathComponent(candidate) == name
    case .envVariant:
        return isEnvVariant(lastPathComponent(candidate))
    case .homeSuffix(let parts), .hostAuth(let parts):
        return matchesHomeSuffix(candidate, parts: parts)
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
    let joined = parts.joined(separator: "/")
    if hasPathPrefix(candidate, prefix: "~/" + joined) { return true }
    if hasPathPrefix(candidate, prefix: "$HOME/" + joined) { return true }
    if hasPathPrefix(candidate, prefix: "${HOME}/" + joined) { return true }
    let components = candidate.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    return containsContiguous(components, parts)
}
