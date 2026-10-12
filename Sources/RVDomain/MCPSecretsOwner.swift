/// Credential partition shared by the secrets providers.
///
/// Org credentials are shared across a tenant's members; user
/// credentials stay private to their subject. Ports Executor
/// `embeddedItemOwner`/`ownerForItemId` (`provider-item-owner.ts`):
/// `connection:`/`oauth:`/`oauth-client:` ids embed their owning
/// partition in the second colon segment; every other id (opaque V2
/// ids, legacy random `secret_*`) carries none and falls back to the
/// caller's binding.
///
/// Coexistence with `PolicyOwner`: that enum is policy-rule scope
/// (which rules outrank which — hence `Comparable`), living in the
/// policy layer. This enum is storage partition (which rows a
/// credential files under), living in the secrets layer. Same
/// `org`/`user` words, different questions — precedence vs filing —
/// so they stay separate types and never convert.
public enum MCPSecretsOwner: String, Sendable, Equatable {
    /// Shared partition (Executor `Owner "org"`).
    case org
    /// Private partition (Executor `Owner "user"`).
    case user

    /// Item-id prefixes whose second colon segment is the owning
    /// partition. Pinned verbatim from `provider-item-owner.ts`.
    public static let scopedPrefixes: Set<String> = [
        "connection", "oauth", "oauth-client",
    ]

    /// The owner an item id embeds, or nil for ids that carry none.
    /// Reads the second colon-segment of the owner-scoped prefixes;
    /// anything else (missing segment, unknown owner word, unknown
    /// prefix) is a legacy id with no embedded owner. The
    /// `:store-probe` tail inherits its credential's owner by hanging
    /// off the same id.
    public static func embeddedOwner(itemID: String) -> Self? {
        let segments = itemID.split(separator: ":", omittingEmptySubsequences: false)
        guard segments.count >= 2, scopedPrefixes.contains(String(segments[0])) else {
            return nil
        }
        switch segments[1] {
        case "org":
            return .org
        case "user":
            return .user
        default:
            return nil
        }
    }

    /// The partition a credential belongs to: the id-embedded owner
    /// when present, else the caller's binding (`defaultOwner`).
    public static func ownerForItemID(
        _ id: String, defaultOwner: Self
    ) -> Self {
        embeddedOwner(itemID: id) ?? defaultOwner
    }
}
