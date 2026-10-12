import Testing
import RVDomain

@Suite("MCPSecretsOwner")
struct MCPSecretsOwnerTests {
    @Test func scopedPrefixesEmbedSecondSegment() {
        for prefix in ["connection", "oauth", "oauth-client"] {
            #expect(MCPSecretsOwner.embeddedOwner(itemID: "\(prefix):org:a:b") == .org)
            #expect(MCPSecretsOwner.embeddedOwner(itemID: "\(prefix):user:a:b") == .user)
        }
        #expect(MCPSecretsOwner.scopedPrefixes == ["connection", "oauth", "oauth-client"])
    }

    @Test func legacyIdsEmbedNothing() {
        for id in ["github", "", "secret_abc123", "vault:org:x", "oauth:bogus:x", "oauth", "oauth:", ":"] {
            #expect(MCPSecretsOwner.embeddedOwner(itemID: id) == nil)
        }
    }

    @Test func ownerForItemIDFallsBackToCallerBinding() {
        #expect(
            MCPSecretsOwner.ownerForItemID("connection:user:a:b", defaultOwner: .org) == .user
        )
        #expect(MCPSecretsOwner.ownerForItemID("github", defaultOwner: .org) == .org)
        #expect(MCPSecretsOwner.ownerForItemID("github", defaultOwner: .user) == .user)
    }
}
