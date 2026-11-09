#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
#error("Unsupported platform for SecretPathCandidateResolver")
#endif

import Foundation
import RVEngine
import RVDomain
import RVPolicy

/// Filesystem-backed candidate resolution for the SecretPathGuard seam.
///
/// Expands one typed candidate operand to the path it actually targets
/// through POSIX `realpath`, normalizing home paths back to `~`-form so
/// suffix rules still match. A missing leaf (or missing tail) resolves
/// through its deepest existing ancestor, so a file about to be created
/// under a symlinked secret directory is still seen there; the typed
/// spelling is always judged as well.
enum SecretPathCandidateResolver {
    /// Per-request resolution seam wired into `GatedEvaluate`'s engine calls.
    /// Stateless: the returned `SecretPathResolution` is `Sendable`.
    static func resolution(home: HomeDirectory?, cwd: WorkingDirectory?) -> SecretPathResolution {
        SecretPathResolution { candidate in
            expanded(candidate, home: home, cwd: cwd)
        }
    }

    /// Expands one guard candidate to its filesystem-resolved `~`-normalized
    /// form, or nil when it has no distinct on-disk target.
    static func expanded(_ candidate: String, home: HomeDirectory?, cwd: WorkingDirectory?) -> String? {
        let raw: String
        if candidate == "~" || candidate.hasPrefix("~/") {
            guard let home else { return nil }
            raw = candidate == "~"
                ? home.rawValue
                : home.rawValue + "/" + String(candidate.dropFirst(2))
        } else if candidate.hasPrefix("${HOME}/") {
            guard let home else { return nil }
            raw = home.rawValue + String(candidate.dropFirst(7))
        } else if candidate.hasPrefix("$HOME/") {
            guard let home else { return nil }
            raw = home.rawValue + String(candidate.dropFirst(5))
        } else if candidate.hasPrefix("/") {
            raw = candidate
        } else {
            // Relative operand: meaningless without a known cwd.
            guard let cwd else { return nil }
            raw = cwd.rawValue + "/" + candidate
        }
        guard let target = resolvedPath(raw) else { return nil }
        guard let home else { return target }
        if target == home.rawValue {
            return "~"
        }
        if target.hasPrefix(home.rawValue + "/") {
            return "~/" + String(target.dropFirst(home.rawValue.count + 1))
        }
        return target
    }

    /// `raw` (absolute) as the filesystem resolves it, through its deepest
    /// existing ancestor when the leaf is missing.
    static func resolvedPath(_ raw: String) -> String? {
        posixRealpath(raw) ?? resolvedThroughAncestor(raw)
    }

    /// A path whose leaf does not exist yet (a Write creating a file) has
    /// no realpath, but its directory does: resolve the deepest existing
    /// ancestor and re-append the missing tail, so `~/link/authorized_keys`
    /// with `~/link -> ~/.ssh` resolves into `~/.ssh`. Nil when no ancestor
    /// below `/` resolves or nothing is missing.
    private static func resolvedThroughAncestor(_ path: String) -> String? {
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var missing: [String] = []
        while components.isEmpty == false {
            missing.insert(components.removeLast(), at: 0)
            guard components.isEmpty == false else { return nil }
            if let ancestor = posixRealpath("/" + components.joined(separator: "/")) {
                let base = ancestor == "/" ? "" : ancestor
                return base + "/" + missing.joined(separator: "/")
            }
        }
        return nil
    }

    /// Nil when the path does not exist or is unreachable.
    static func posixRealpath(_ path: String) -> String? {
        path.withCString { raw in
            #if canImport(Darwin)
            let target = Darwin.realpath(raw, nil)
            #else
            let target = Glibc.realpath(raw, nil)
            #endif
            guard let target else { return nil }
            defer { free(target) }
            return String(cString: target)
        }
    }
}
