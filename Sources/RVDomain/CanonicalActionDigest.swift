import Foundation

/// Canonical security digest of one `ProposedAction` for approval binding.
///
/// Step 6 binds principal-bound approvals to this digest, not to the legacy
/// `ActionFingerprint` spellings. The legacy spellings concatenate trusted
/// and untrusted fields with `:` separators (`host:session:cwd:command` and
/// friends), so two different actions can share one fingerprint string — e.g.
/// `cwd="a:b", command="c"` versus `cwd="a", command="b:c"`. Those collisions
/// are fail-closed wherever the legacy fingerprint is still used (deny-lists
/// and describe-only APIs), but they are not sound enough to authorize an
/// exact action. This digest covers the full decoded action struct instead.
///
/// Properties:
/// - Deterministic: same action value always yields the same digest.
/// - Complete: every field of the action participates, including the case
///   discriminator, effects, resources, scope, supporting evidence, and
///   semantic analysis. Any material difference changes the digest.
/// - Domain-separated: the `rv-action-digest-v1` prefix keeps these digests
///   distinct from every other project hash (intent digests, query tokens).
/// - Memory-only contract: digests are compared against the service's
///   retained digest inside one authorizer lifetime and appear in audit as
///   descriptive hex. They are never persisted as authority and never
///   grant anything by possession.
///
/// A digest match authorizes nothing by itself. Consumption additionally
/// requires the authenticated live principal, the exact continuation, an
/// unexpired and unconsumed server-held grant, and the exact retained
/// action the service bound at creation.
public enum CanonicalActionDigest: Sendable {
    public static let domain = "rv-action-digest-v1"

    /// SHA-256 hex over domain-separated canonical bytes of `action`.
    public static func sha256Hex(of action: ProposedAction) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // ProposedAction is fully Encodable; a failure would mean memory
        // corruption. Fall back to a digest that can never match a real one.
        guard let body = try? encoder.encode(action) else {
            return RVDigest.sha256Hex(Array("\(domain):encode-failed".utf8))
        }
        var bytes = Array(domain.utf8)
        bytes.append(0)
        bytes.append(contentsOf: canonicalCaseLabel(of: action).utf8)
        bytes.append(0)
        bytes.append(contentsOf: body)
        return RVDigest.sha256Hex(bytes)
    }

    private static func canonicalCaseLabel(of action: ProposedAction) -> String {
        switch action {
        case .shell: return "shell"
        case .file: return "file"
        case .http: return "http"
        }
    }
}
