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
/// suffix rules still match. Realpath requires the leaf and every ancestor
/// to exist, which is the point: only spellings that really reach a file on
/// disk are resolved, and phantom spellings stay right where the typed guard
/// found them.
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
        guard let target = posixRealpath(raw) else { return nil }
        guard let home else { return target }
        if target == home.rawValue {
            return "~"
        }
        if target.hasPrefix(home.rawValue + "/") {
            return "~/" + String(target.dropFirst(home.rawValue.count + 1))
        }
        return target
    }

    /// Nil when the path does not exist or is unreachable.
    private static func posixRealpath(_ path: String) -> String? {
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
