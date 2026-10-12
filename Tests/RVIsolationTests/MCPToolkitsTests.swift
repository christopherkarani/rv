import Foundation
import RVDomain
import RVPolicy
import Synchronization
import Testing
@testable import RVIsolation

/// Toolkits, policy-store mutation, and the provider hook.
///
/// Oracle map: `server.test.ts` (toolkit CRUD, slug uniqueness, implicit-deny
/// resolution, dynamic scope, legacy connection approves, broad-over-narrow),
/// `policies.test.ts` (`executor.policies` CRUD, placement, provider
/// allowlists, prepared scopes). Every ported behavior names its oracle.
@Suite("MCPToolkits")
struct MCPToolkitsTests {
    private func address(_ literal: String) throws -> MCPToolAddress {
        try MCPToolAddress.parse(literal)
    }

    private func segments(_ raw: String) throws -> SegmentPattern {
        try SegmentPattern.parse(raw)
    }

    private func createdToolkit(
        name: String = "Deploy Kit",
        owner: PolicyOwner = .org,
        slug: String? = nil
    ) throws -> (MCPToolkitStore, MCPToolkit) {
        try MCPToolkitStore().create(owner: owner, name: name, slug: slug).get()
    }

    // MARK: - Slugs (server.ts:92-116)

    @Test func slugParseNormalizesCaseAndPadding() throws {
        #expect(try MCPToolkitSlug.parse("  Deploy-Kit ").rawValue == "deploy-kit")
        #expect(try MCPToolkitSlug.parse("a").rawValue == "a")
        #expect(try MCPToolkitSlug.parse(String(repeating: "a", count: 63)).rawValue.count == 63)
        #expect(try MCPToolkitSlug.parse("a-9-z").rawValue == "a-9-z")
    }

    @Test(arguments: ["", "-", "-a", "a-", "a_b", "a.b", "a b", "a/b", String(repeating: "a", count: 64)])
    func slugParseRejectsBadShapes(_ raw: String) {
        #expect(throws: MCPToolkitError.invalidSlug) { try MCPToolkitSlug.parse(raw) }
    }

    @Test func slugValidityMatchesParse() {
        #expect(MCPToolkitSlug.isValid("deploy-kit"))
        #expect(MCPToolkitSlug.isValid("a"))
        #expect(MCPToolkitSlug.isValid("9"))
        #expect(MCPToolkitSlug.isValid("") == false)
        #expect(MCPToolkitSlug.isValid("-ab") == false)
        #expect(MCPToolkitSlug.isValid("ab-") == false)
        #expect(MCPToolkitSlug.isValid("ab_cd") == false)
        #expect(MCPToolkitSlug.isValid(String(repeating: "a", count: 64)) == false)
    }

    @Test func slugifyCollapsesRunsAndTrims() {
        #expect(MCPToolkitSlug.slugify("Deploy Kit") == "deploy-kit")
        #expect(MCPToolkitSlug.slugify("  Deploy   Kit!! ") == "deploy-kit")
        #expect(MCPToolkitSlug.slugify("---") == "")
        #expect(MCPToolkitSlug.slugify("!!!") == "")
        #expect(MCPToolkitSlug.slugify("") == "")
        #expect(MCPToolkitSlug.slugify("a") == "a")
        #expect(MCPToolkitSlug.slugify("UPPER lower 9") == "upper-lower-9")
    }

    @Test func slugifyCapsAt63Characters() {
        let slugified = MCPToolkitSlug.slugify(String(repeating: "a", count: 100))
        #expect(slugified == String(repeating: "a", count: 63))
        #expect(MCPToolkitSlug.isValid(slugified))
    }

    // MARK: - Toolkit CRUD (server.test.ts: creates/rejects)

    @Test func createDerivesSlugFromName() throws {
        // Oracle: "creates toolkits and manages ordered policy rules" (slug "deploy-kit").
        let (_, toolkit) = try createdToolkit()
        #expect(toolkit.slug.rawValue == "deploy-kit")
        #expect(toolkit.name == "Deploy Kit")
        #expect(toolkit.owner == .org)
        #expect(toolkit.policies.isEmpty)
        #expect(toolkit.connections.isEmpty)
    }

    @Test func createHonorsExplicitSlug() throws {
        let (_, toolkit) = try createdToolkit(name: "Deploy Kit", slug: "  SHIP-IT ")
        #expect(toolkit.slug.rawValue == "ship-it")
    }

    @Test func createRejectsEmptyName() {
        #expect(throws: MCPToolkitError.invalidName) {
            try MCPToolkitStore().create(owner: .org, name: "   ").get()
        }
    }

    @Test func createRejectsUnslugifiableName() {
        // slugify yields "" which parse rejects: same ToolkitError as explicit bad slugs.
        #expect(throws: MCPToolkitError.invalidSlug) {
            try MCPToolkitStore().create(owner: .org, name: "!!!").get()
        }
    }

    @Test func createRejectsExplicitBadSlug() {
        #expect(throws: MCPToolkitError.invalidSlug) {
            try MCPToolkitStore().create(owner: .org, name: "Kit", slug: "-bad-").get()
        }
    }

    @Test func createRejectsDuplicateSlugAcrossOwners() throws {
        // Oracle: "rejects duplicate visible slugs".
        let (store, _) = try createdToolkit()
        #expect(throws: MCPToolkitError.slugInUse) {
            try store.create(owner: .user, name: "Deploy Kit").get()
        }
        #expect(throws: MCPToolkitError.slugInUse) {
            try store.create(owner: .org, name: "Other", slug: "deploy-kit").get()
        }
    }

    @Test func listOrdersOrgFirstThenNameThenSlug() throws {
        var store = MCPToolkitStore()
        let (s1, _) = try store.create(owner: .user, name: "Mango").get()
        let (s2, _) = try s1.create(owner: .org, name: "Zebra").get()
        let (s3, _) = try s2.create(owner: .org, name: "Apple").get()
        store = s3
        let listed = store.list()
        #expect(listed.map(\.name) == ["Apple", "Zebra", "Mango"])
        #expect(listed.map(\.owner) == [.org, .org, .user])
        // Slug tiebreak (hand-built: same name, distinct slugs).
        let first = MCPToolkit(
            id: "1", owner: .org, slug: try MCPToolkitSlug.parse("b-kit"), name: "Same"
        )
        let second = MCPToolkit(
            id: "2", owner: .org, slug: try MCPToolkitSlug.parse("a-kit"), name: "Same"
        )
        #expect(MCPToolkitStore(toolkits: [first, second]).list().map(\.id) == ["2", "1"])
    }

    @Test func updateRenamesAndReslugsKeepingRules() throws {
        let (store, toolkit) = try createdToolkit()
        let (store2, _) = try store.createPolicy(toolkit.id, pattern: "tools.a.*", action: .block).get()
        let (store3, updated) = try store2.update(toolkit.id, name: "Ship Kit", slug: "ship-kit").get()
        #expect(updated.name == "Ship Kit")
        #expect(updated.slug.rawValue == "ship-kit")
        #expect(updated.policies.count == 1)
        #expect(try store3.listPolicies(toolkit.id).get().count == 1)
    }

    @Test func updateKeepsFieldsWhenNil() throws {
        let (store, toolkit) = try createdToolkit()
        let (_, renamed) = try store.update(toolkit.id, name: "New Name").get()
        #expect(renamed.name == "New Name")
        #expect(renamed.slug == toolkit.slug)
        let (_, reslugged) = try store.update(toolkit.id, slug: "new-slug").get()
        #expect(reslugged.name == toolkit.name)
        #expect(reslugged.slug.rawValue == "new-slug")
        let (_, noop) = try store.update(toolkit.id).get()
        #expect(noop == toolkit)
    }

    @Test func updateAcceptsItsOwnSlug() throws {
        let (store, toolkit) = try createdToolkit()
        let (_, updated) = try store.update(toolkit.id, slug: "deploy-kit").get()
        #expect(updated.slug == toolkit.slug)
    }

    @Test func updateRejectsMissingEmptyBadAndColliding() throws {
        let (store, toolkit) = try createdToolkit()
        let (store2, _) = try store.create(owner: .user, name: "Other Kit").get()
        #expect(throws: MCPToolkitError.toolkitNotFound) {
            try store2.update("no-such-id", name: "X").get()
        }
        #expect(throws: MCPToolkitError.invalidName) {
            try store2.update(toolkit.id, name: "   ").get()
        }
        #expect(throws: MCPToolkitError.invalidSlug) {
            try store2.update(toolkit.id, slug: "-bad-").get()
        }
        #expect(throws: MCPToolkitError.slugInUse) {
            try store2.update(toolkit.id, slug: "other-kit").get()
        }
    }

    @Test func removeCascadesRules() throws {
        let (store, toolkit) = try createdToolkit()
        let (store2, _) = try store.createPolicy(toolkit.id, pattern: "tools.a.*", action: .block).get()
        let (store3, _) = try store2.createConnection(toolkit.id, pattern: "tools.a.*").get()
        let removed = try store3.remove(toolkit.id).get()
        #expect(removed.list().isEmpty)
        #expect(removed.resolvePolicyForSlug("deploy-kit", toolID: "tools.a.b.c.d", defaultAction: .approve).action == .block)
        #expect(throws: MCPToolkitError.toolkitNotFound) { try removed.remove(toolkit.id).get() }
    }

    // MARK: - Toolkit policies (server.test.ts: ordered rules)

    @Test func createdPoliciesListNewestFirst() throws {
        // Oracle: "creates toolkits and manages ordered policy rules" ([second, first]).
        let (store, toolkit) = try createdToolkit()
        let (store2, first) = try store.createPolicy(
            toolkit.id, pattern: "tools.github.org.main.repos.*", action: .approve
        ).get()
        let (store3, second) = try store2.createPolicy(
            toolkit.id, pattern: "tools.github.*", action: .block
        ).get()
        #expect(second.position < first.position)
        let listed = try store3.listPolicies(toolkit.id).get()
        #expect(listed.map(\.id) == [second.id, first.id])
    }

    @Test func createPolicyDefaultsToZeroOnEmptyToolkit() throws {
        let (store, toolkit) = try createdToolkit()
        let (_, policy) = try store.createPolicy(toolkit.id, pattern: "tools.a.*", action: .block).get()
        #expect(policy.position == FractionalIndex(value: 0))
    }

    @Test func createPolicyHonorsExplicitPosition() throws {
        let (store, toolkit) = try createdToolkit()
        let (_, policy) = try store.createPolicy(
            toolkit.id, pattern: "tools.a.*", action: .block, position: FractionalIndex(value: 42)
        ).get()
        #expect(policy.position == FractionalIndex(value: 42))
    }

    @Test func createPolicyRejectsBadPatternAndMissingToolkit() throws {
        let (store, toolkit) = try createdToolkit()
        #expect(throws: MCPToolkitError.invalidPattern) {
            try store.createPolicy(toolkit.id, pattern: "tools..bad", action: .block).get()
        }
        #expect(throws: MCPToolkitError.toolkitNotFound) {
            try store.createPolicy("no-such-id", pattern: "tools.a.*", action: .block).get()
        }
    }

    @Test func updatePolicyMutatesInPlace() throws {
        // Oracle: updatePolicy action visible through policyRulesForSlug.
        let (store, toolkit) = try createdToolkit()
        let (store2, policy) = try store.createPolicy(
            toolkit.id, pattern: "tools.github.org.main.repos.*", action: .approve
        ).get()
        let (store3, updated) = try store2.updatePolicy(toolkit.id, policy.id, action: .requireApproval).get()
        #expect(updated.action == .requireApproval)
        #expect(updated.id == policy.id)
        #expect(updated.pattern == policy.pattern)
        let rules = store3.policyRulesForSlug("deploy-kit")
        #expect(rules.first { $0.id == policy.id }?.action == .requireApproval)
    }

    @Test func updatePolicyRewritesPatternAndPosition() throws {
        let (store, toolkit) = try createdToolkit()
        let (store2, first) = try store.createPolicy(toolkit.id, pattern: "tools.a.*", action: .block).get()
        let (store3, second) = try store2.createPolicy(toolkit.id, pattern: "tools.b.*", action: .block).get()
        #expect(try store3.listPolicies(toolkit.id).get().map(\.id) == [second.id, first.id])
        let (store4, moved) = try store3.updatePolicy(
            toolkit.id, first.id,
            pattern: "tools.c.*",
            position: FractionalIndex(value: second.position.value - 1)
        ).get()
        #expect(moved.pattern.rawValue == "tools.c.*")
        #expect(try store4.listPolicies(toolkit.id).get().map(\.id) == [first.id, second.id])
        let (_, noop) = try store4.updatePolicy(toolkit.id, first.id).get()
        #expect(noop == moved)
    }

    @Test func updatePolicyRejectsBadPatternAndMissingRows() throws {
        let (store, toolkit) = try createdToolkit()
        let (store2, policy) = try store.createPolicy(toolkit.id, pattern: "tools.a.*", action: .block).get()
        #expect(throws: MCPToolkitError.invalidPattern) {
            try store2.updatePolicy(toolkit.id, policy.id, pattern: "tools..bad").get()
        }
        #expect(throws: MCPToolkitError.toolkitNotFound) {
            try store2.updatePolicy("no-such-kit", policy.id, action: .approve).get()
        }
        #expect(throws: MCPToolkitError.policyNotFound) {
            try store2.updatePolicy(toolkit.id, "no-such-policy", action: .approve).get()
        }
    }

    @Test func removePolicyDropsOneRule() throws {
        let (store, toolkit) = try createdToolkit()
        let (store2, policy) = try store.createPolicy(toolkit.id, pattern: "tools.a.*", action: .block).get()
        let removed = try store2.removePolicy(toolkit.id, policy.id).get()
        #expect(try removed.listPolicies(toolkit.id).get().isEmpty)
        #expect(throws: MCPToolkitError.policyNotFound) {
            try removed.removePolicy(toolkit.id, policy.id).get()
        }
        #expect(throws: MCPToolkitError.toolkitNotFound) {
            try removed.removePolicy("no-such-kit", policy.id).get()
        }
    }

    @Test func listPoliciesRejectsMissingToolkit() throws {
        let (store, _) = try createdToolkit()
        #expect(throws: MCPToolkitError.toolkitNotFound) { try store.listPolicies("no-such-id").get() }
    }

    // MARK: - Connections (server.test.ts: duplicate grant)

    @Test func duplicateConnectionReturnsExistingGrant() throws {
        // Oracle: duplicateConnection.id == connection.id.
        let (store, toolkit) = try createdToolkit()
        let (store2, connection) = try store.createConnection(toolkit.id, pattern: "tools.github.org.main.*").get()
        let (store3, duplicate) = try store2.createConnection(toolkit.id, pattern: "tools.github.org.main.*").get()
        #expect(duplicate.id == connection.id)
        #expect(try store3.listConnections(toolkit.id).get().count == 1)
        #expect(store3 == store2)
    }

    @Test func distinctConnectionPatternsCoexist() throws {
        let (store, toolkit) = try createdToolkit()
        let (store2, _) = try store.createConnection(toolkit.id, pattern: "tools.a.*").get()
        let (store3, second) = try store2.createConnection(toolkit.id, pattern: "tools.b.*").get()
        #expect(try store3.listConnections(toolkit.id).get().count == 2)
        #expect(second.position == FractionalIndex(value: -1))
    }

    @Test func createConnectionHonorsExplicitPosition() throws {
        let (store, toolkit) = try createdToolkit()
        let (_, connection) = try store.createConnection(
            toolkit.id, pattern: "tools.a.*", position: FractionalIndex(value: 9)
        ).get()
        #expect(connection.position == FractionalIndex(value: 9))
    }

    @Test func createConnectionRejectsBadPatternAndMissingToolkit() throws {
        let (store, toolkit) = try createdToolkit()
        #expect(throws: MCPToolkitError.invalidPattern) {
            try store.createConnection(toolkit.id, pattern: "tools..bad").get()
        }
        #expect(throws: MCPToolkitError.toolkitNotFound) {
            try store.createConnection("no-such-id", pattern: "tools.a.*").get()
        }
    }

    @Test func removeConnectionDropsOneGrant() throws {
        let (store, toolkit) = try createdToolkit()
        let (store2, connection) = try store.createConnection(toolkit.id, pattern: "tools.a.*").get()
        let removed = try store2.removeConnection(toolkit.id, connection.id).get()
        #expect(try removed.listConnections(toolkit.id).get().isEmpty)
        #expect(throws: MCPToolkitError.connectionNotFound) {
            try removed.removeConnection(toolkit.id, connection.id).get()
        }
        #expect(throws: MCPToolkitError.toolkitNotFound) {
            try removed.removeConnection("no-such-kit", connection.id).get()
        }
        #expect(throws: MCPToolkitError.toolkitNotFound) { try removed.listConnections("no-such-kit").get() }
    }

    // MARK: - Resolution (server.test.ts: implicit deny + owner limits)

    private func workspaceKit() throws -> MCPToolkitStore {
        let (store, toolkit) = try createdToolkit(name: "Workspace Kit")
        return try store.createConnection(toolkit.id, pattern: "tools.github.org.main.*").get().0
    }

    @Test func connectedToolFallsThroughToInjectedDefault() throws {
        // Oracle: "resolves toolkit policies with implicit deny and workspace owner limits".
        let store = try workspaceKit()
        let approved = store.resolvePolicyForSlug(
            "workspace-kit", toolID: "tools.github.org.main.repos.list", defaultAction: .approve
        )
        #expect(approved.action == .approve)
        #expect(approved.match == nil)
        let prompted = store.resolvePolicyForSlug(
            "workspace-kit", toolID: "tools.github.org.main.repos.delete", defaultAction: .requireApproval
        )
        #expect(prompted.action == .requireApproval)
        #expect(prompted.match == nil)
    }

    @Test func explicitPolicyWinsOverDefault() throws {
        let (store, toolkit) = try createdToolkit(name: "Workspace Kit")
        let (store2, _) = try store.createConnection(toolkit.id, pattern: "tools.github.org.main.*").get()
        let (store3, policy) = try store2.createPolicy(
            toolkit.id, pattern: "tools.github.org.main.repos.delete", action: .approve
        ).get()
        let verdict = store3.resolvePolicyForSlug(
            "workspace-kit", toolID: "tools.github.org.main.repos.delete", defaultAction: .requireApproval
        )
        #expect(verdict.action == .approve)
        #expect(verdict.match == MCPToolkitMatch(id: policy.id, owner: .org))
    }

    @Test func orgToolkitBlocksPersonalTools() throws {
        let store = try workspaceKit()
        let verdict = store.resolvePolicyForSlug(
            "workspace-kit", toolID: "tools.github.user.main.repos.list", defaultAction: .approve
        )
        #expect(verdict.action == .block)
        #expect(verdict.match == nil)
    }

    @Test func unconnectedToolBlocksAtBoundary() throws {
        let store = try workspaceKit()
        let verdict = store.resolvePolicyForSlug(
            "workspace-kit", toolID: "tools.slack.org.main.chat.post", defaultAction: .approve
        )
        #expect(verdict.action == .block)
        #expect(verdict.match == nil)
    }

    @Test func personalToolkitAllowsPersonalTools() throws {
        let (store, toolkit) = try createdToolkit(name: "Personal Kit", owner: .user)
        let store2 = try store.createConnection(toolkit.id, pattern: "tools.github.user.main.*").get().0
        let verdict = store2.resolvePolicyForSlug(
            "personal-kit", toolID: "tools.github.user.main.repos.list", defaultAction: .approve
        )
        #expect(verdict.action == .approve)
    }

    @Test func unknownSlugBlocks() throws {
        let store = try workspaceKit()
        #expect(
            store.resolvePolicyForSlug("no-such-kit", toolID: "tools.github.org.main.x", defaultAction: .approve).action
                == .block
        )
        #expect(store.policyRulesForSlug("no-such-kit").isEmpty)
    }

    @Test func degenerateToolIDBlocks() throws {
        // A literal without an owner segment is not personal, just unmatched.
        let store = try workspaceKit()
        #expect(
            store.resolvePolicyForSlug("workspace-kit", toolID: "wat", defaultAction: .approve).action == .block
        )
    }

    @Test func firstMatchWinsRegardlessOfRestrictiveness() throws {
        // Toolkit rules are first-match (unlike the cross-owner most-restrictive reduction).
        let (store, toolkit) = try createdToolkit()
        let (store2, _) = try store.createConnection(toolkit.id, pattern: "tools.a.*").get()
        let (store3, _) = try store2.createPolicy(toolkit.id, pattern: "tools.a.*", action: .block).get()
        let (store4, _) = try store3.createPolicy(toolkit.id, pattern: "tools.a.*", action: .approve).get()
        // Newest lists first, so approve wins despite being weaker.
        #expect(
            store4.resolvePolicyForSlug("deploy-kit", toolID: "tools.a.b.c.d", defaultAction: .block).action
                == .approve
        )
    }

    @Test func positionTieBreaksByID() throws {
        let slug = try MCPToolkitSlug.parse("kit")
        let toolkit = MCPToolkit(
            id: "tk", owner: .org, slug: slug, name: "Kit",
            policies: [
                MCPToolkitPolicy(
                    id: "zebra", pattern: try segments("tools.a.*"), action: .approve,
                    position: FractionalIndex(value: 1)
                ),
                MCPToolkitPolicy(
                    id: "apple", pattern: try segments("tools.a.*"), action: .block,
                    position: FractionalIndex(value: 1)
                ),
            ],
            connections: [
                MCPToolkitConnection(
                    id: "c", pattern: try segments("tools.a.*"), position: FractionalIndex(value: 0)
                )
            ]
        )
        #expect(toolkit.policies.map(\.id) == ["apple", "zebra"])
        let verdict = toolkit.resolve(literal: "tools.a.b.c.d", defaultAction: .approve)
        #expect(verdict.action == .block)
        #expect(verdict.match?.id == "apple")
    }

    @Test func toolkitInitSortsHandBuiltRules() throws {
        let slug = try MCPToolkitSlug.parse("kit")
        let toolkit = MCPToolkit(
            id: "tk", owner: .user, slug: slug, name: "Kit",
            policies: [
                MCPToolkitPolicy(
                    id: "b", pattern: try segments("tools.b.*"), action: .block,
                    position: FractionalIndex(value: 2)
                ),
                MCPToolkitPolicy(
                    id: "a", pattern: try segments("tools.a.*"), action: .block,
                    position: FractionalIndex(value: 1)
                ),
            ],
            connections: [
                MCPToolkitConnection(
                    id: "d", pattern: try segments("tools.d.*"), position: FractionalIndex(value: 2)
                ),
                MCPToolkitConnection(
                    id: "c", pattern: try segments("tools.c.*"), position: FractionalIndex(value: 1)
                ),
            ]
        )
        #expect(toolkit.policies.map(\.id) == ["a", "b"])
        #expect(toolkit.connections.map(\.id) == ["c", "d"])
    }

    @Test func emptyToolkitBlocksEverything() throws {
        let (store, _) = try createdToolkit()
        #expect(
            store.resolvePolicyForSlug("deploy-kit", toolID: "tools.a.b.c.d", defaultAction: .approve).action
                == .block
        )
    }

    @Test func verdictMapsOntoEffectivePolicy() throws {
        let matched = MCPToolkitVerdict(action: .requireApproval, match: MCPToolkitMatch(id: "p", owner: .user))
        #expect(
            matched.effectivePolicy()
                == EffectivePolicy(action: .requireApproval, provenance: .pattern(id: "p", owner: .user))
        )
        let boundary = MCPToolkitVerdict(action: .block)
        #expect(boundary.effectivePolicy() == EffectivePolicy(action: .block, provenance: .fallback))
        let fallback = MCPToolkitVerdict(action: .approve)
        #expect(fallback.effectivePolicy().isFallback)
    }

    @Test func slugLookupNormalizesAndPrefersOrg() throws {
        // Hand-built duplicate slugs: org wins (server.ts getBySlugEntry).
        let slug = try MCPToolkitSlug.parse("dupe")
        let user = MCPToolkit(
            id: "u", owner: .user, slug: slug, name: "User",
            connections: [MCPToolkitConnection(id: "c", pattern: try segments("tools.a.*"), position: FractionalIndex(value: 0))]
        )
        let org = MCPToolkit(
            id: "o", owner: .org, slug: slug, name: "Org",
            connections: [MCPToolkitConnection(id: "c", pattern: try segments("tools.b.*"), position: FractionalIndex(value: 0))]
        )
        let store = MCPToolkitStore(toolkits: [user, org])
        // The org toolkit's grant (tools.b.*) applies, not the user's (tools.a.*).
        #expect(
            store.resolvePolicyForSlug("  DUPE ", toolID: "tools.b.x.y.z", defaultAction: .approve).action
                == .approve
        )
        #expect(
            store.resolvePolicyForSlug("dupe", toolID: "tools.a.x.y.z", defaultAction: .approve).action
                == .block
        )
    }

    // MARK: - Legacy connection approves

    @Test func coveredConnectionRootApproveStaysAnOrderedPolicy() throws {
        // Oracle: "treats a persisted connection-root approve as an access policy".
        let (store, toolkit) = try createdToolkit(name: "Core Tools Kit")
        let (store2, _) = try store.createConnection(toolkit.id, pattern: "tools.executor.coreTools.*").get()
        let (store3, policy) = try store2.createPolicy(
            toolkit.id, pattern: "tools.executor.coreTools.*", action: .approve
        ).get()
        let verdict = store3.resolvePolicyForSlug(
            "core-tools-kit", toolID: "tools.executor.coreTools.connections.remove",
            defaultAction: .requireApproval
        )
        #expect(verdict.action == .approve)
        #expect(verdict.match?.id == policy.id)
        let rules = store3.policyRulesForSlug("core-tools-kit")
        #expect(rules.map(\.id).contains(policy.id))
    }

    @Test func broadApproveAppliesOverNarrowerConnection() throws {
        // Oracle: "applies a broad approve policy over a narrower connection".
        let (store, toolkit) = try createdToolkit(name: "Docs Kit")
        let (store2, _) = try store.createConnection(toolkit.id, pattern: "tools.google_docs.org.main.*").get()
        let (store3, policy) = try store2.createPolicy(
            toolkit.id, pattern: "tools.google_docs.org.*", action: .approve
        ).get()
        let verdict = store3.resolvePolicyForSlug(
            "docs-kit", toolID: "tools.google_docs.org.main.documents.update",
            defaultAction: .requireApproval
        )
        #expect(verdict.action == .approve)
        #expect(verdict.match?.id == policy.id)
        #expect(store3.policyRulesForSlug("docs-kit").map(\.id).contains(policy.id))
    }

    @Test func uncoveredConnectionRootApproveGrantsAccessOnly() throws {
        // A legacy row (approve at connection-root shape, no covering grant)
        // joins the access set but is excluded from ordered policies.
        let (store, toolkit) = try createdToolkit()
        let (store2, legacy) = try store.createPolicy(
            toolkit.id, pattern: "tools.github.org.main.*", action: .approve
        ).get()
        let verdict = store2.resolvePolicyForSlug(
            "deploy-kit", toolID: "tools.github.org.main.repos.list", defaultAction: .requireApproval
        )
        #expect(verdict.action == .requireApproval)
        #expect(verdict.match == nil)
        #expect(store2.policyRulesForSlug("deploy-kit").map(\.id).contains(legacy.id) == false)
    }

    @Test func nonApproveRootShapesStayOrdered() throws {
        // block/requireApproval at a root shape are real policies, not access grants.
        let (store, toolkit) = try createdToolkit()
        let (store2, _) = try store.createConnection(toolkit.id, pattern: "tools.github.org.main.*").get()
        let (store3, blocked) = try store2.createPolicy(
            toolkit.id, pattern: "tools.github.org.main.*", action: .block
        ).get()
        let verdict = store3.resolvePolicyForSlug(
            "deploy-kit", toolID: "tools.github.org.main.repos.list", defaultAction: .approve
        )
        #expect(verdict.action == .block)
        #expect(verdict.match?.id == blocked.id)
    }

    @Test func nonRootApproveShapesStayOrdered() throws {
        // approve rows that are exact, too short, or too deep are ordered policies.
        let (store, toolkit) = try createdToolkit()
        let (store2, _) = try store.createConnection(toolkit.id, pattern: "tools.*").get()
        let (store3, exact) = try store2.createPolicy(
            toolkit.id, pattern: "tools.a.b.c.d", action: .approve
        ).get()
        let (store4, short) = try store3.createPolicy(
            toolkit.id, pattern: "tools.a.*", action: .approve
        ).get()
        let (store5, deep) = try store4.createPolicy(
            toolkit.id, pattern: "tools.a.b.c.d.*", action: .approve
        ).get()
        let ids = store5.policyRulesForSlug("deploy-kit").map(\.id)
        #expect(ids.contains(exact.id) && ids.contains(short.id) && ids.contains(deep.id))
    }

    // MARK: - Dynamic scope (policies.ts:147-164, server.test.ts: prepares)

    @Test func orgToolkitScopePinsAndDrops() throws {
        // Oracle: "prepares a dynamic scope from the toolkit's access patterns".
        let (store, toolkit) = try createdToolkit(name: "Org Kit")
        var current = store
        for pattern in [
            "tools.github.org.main.*",
            "tools.slack.*",
            "tools.linear.*.*.issues.list",
            "tools.github.user.alice.*",
            "tools.executor.coreTools.*",
        ] {
            current = try current.createConnection(toolkit.id, pattern: pattern).get().0
        }
        let scopes = try #require(current.preparePolicyResolverForSlug("org-kit").dynamicScope)
        #expect(Set(scopes) == Set([
            MCPDynamicToolScope(integration: "github", owner: "org", connection: "main"),
            MCPDynamicToolScope(integration: "linear", owner: "org", connection: nil),
            MCPDynamicToolScope(integration: "slack", owner: "org", connection: nil),
        ]))
    }

    @Test func personalToolkitScopeKeepsUserPrefixes() throws {
        let (store, toolkit) = try createdToolkit(name: "Me Kit", owner: .user)
        let store2 = try store.createConnection(toolkit.id, pattern: "tools.github.user.alice.*").get().0
        let scopes = try #require(store2.preparePolicyResolverForSlug("me-kit").dynamicScope)
        #expect(scopes == [MCPDynamicToolScope(integration: "github", owner: "user", connection: "alice")])
    }

    @Test func preparedResolverMatchesDirectResolution() throws {
        let store = try workspaceKit()
        let prepared = store.preparePolicyResolverForSlug("workspace-kit")
        let connected = try address("tools.github.org.main.repos.list")
        #expect(prepared.resolve(connected, .approve).action == .approve)
        let personal = try address("tools.github.user.alice.repos.list")
        #expect(prepared.resolve(personal, .approve).action == .block)
        let missing = store.preparePolicyResolverForSlug("no-such-kit")
        #expect(missing.dynamicScope == [])
        #expect(missing.resolve(connected, .approve).action == .block)
        #expect(missing.resolve(connected, .approve).provenance == .fallback)
    }

    @Test func preparedUserToolkitSkipsPersonalPin() throws {
        let (store, toolkit) = try createdToolkit(owner: .user)
        let store2 = try store.createConnection(toolkit.id, pattern: "tools.*").get().0
        let prepared = store2.preparePolicyResolverForSlug(toolkit.slug.rawValue)
        #expect(prepared.resolve(try address("tools.a.user.b.c"), .approve).action == .approve)
    }

    @Test func scopeForPatternBattery() throws {
        // Oracle: dynamicToolScopeForPattern ("reads the connection prefix",
        // "mid-segment wildcard as any value", "unbounded for universal",
        // "no scope for static-only patterns").
        #expect(MCPDynamicToolScope.forPattern(.any)?.isUnbounded == true)
        #expect(
            MCPDynamicToolScope.forPattern(try segments("tools.github.org.main.*"))
                == MCPDynamicToolScope(integration: "github", owner: "org", connection: "main")
        )
        #expect(
            MCPDynamicToolScope.forPattern(try segments("tools.github.org.main.list"))
                == MCPDynamicToolScope(integration: "github", owner: "org", connection: "main")
        )
        #expect(
            MCPDynamicToolScope.forPattern(try segments("tools.*.org.*"))
                == MCPDynamicToolScope(integration: nil, owner: "org", connection: nil)
        )
        #expect(
            MCPDynamicToolScope.forPattern(try segments("tools.*.org.main.list"))
                == MCPDynamicToolScope(integration: nil, owner: "org", connection: "main")
        )
        #expect(
            MCPDynamicToolScope.forPattern(try segments("tools.a.*"))
                == MCPDynamicToolScope(integration: "a", owner: nil, connection: nil)
        )
        #expect(MCPDynamicToolScope.forPattern(try segments("tools.executor.coreTools.*")) == nil)
        #expect(MCPDynamicToolScope.forPattern(try segments("tools.a.b")) == nil)
        #expect(MCPDynamicToolScope.forPattern(.exact(segments: [])) == nil)
        #expect(MCPDynamicToolScope.forPattern(.exact(segments: ["tools"])) == nil)
        // Prefix-less patterns keep Executor counting (safe over-approximation).
        #expect(
            MCPDynamicToolScope.forPattern(try segments("github.org.main.*"))
                == MCPDynamicToolScope(integration: "github", owner: "org", connection: "main")
        )
    }

    @Test func scopeContainmentAndAllowCheck() throws {
        let target = try address("tools.github.org.main.read")
        let scope = MCPDynamicToolScope(integration: "github", owner: "org", connection: "main")
        #expect(scope.contains(target))
        #expect(scope.isUnbounded == false)
        #expect(MCPDynamicToolScope(integration: nil, owner: nil, connection: nil).isUnbounded)
        #expect(MCPDynamicToolScope(integration: "other", owner: nil, connection: nil).contains(target) == false)
        #expect(MCPDynamicToolScope(integration: nil, owner: "user", connection: nil).contains(target) == false)
        #expect(MCPDynamicToolScope(integration: nil, owner: nil, connection: "x").contains(target) == false)
        // Oracle: "an empty scope reads no dynamic rows" vs unrestricted nil.
        #expect(MCPDynamicToolScope.allows(target, scopes: nil))
        #expect(MCPDynamicToolScope.allows(target, scopes: []) == false)
        #expect(MCPDynamicToolScope.allows(target, scopes: [scope]))
        #expect(
            MCPDynamicToolScope.allows(
                target, scopes: [MCPDynamicToolScope(integration: "other", owner: nil, connection: nil)]
            ) == false
        )
    }

    // MARK: - Store mutation (executor.policies)

    private func policyStore() -> MCPPolicyStore {
        MCPPolicyStore(pluginDefault: .approve)
    }

    @Test func policyListIsEmptyWhenNoRulesExist() {
        // Oracle: "list is empty when no rules exist".
        #expect(policyStore().list().isEmpty)
    }

    @Test func policyCreateDefaultsAboveEquallyOrLessSpecific() throws {
        // Oracle: "create defaults new rules above equally-or-less-specific ones".
        let (store, first) = try policyStore().create(
            owner: .org, pattern: "tools.vercel.*", action: .requireApproval
        ).get()
        let (_, second) = try store.create(owner: .org, pattern: "tools.vercel.delete", action: .block).get()
        #expect(second.position < first.position)
    }

    @Test func policyCreatePlacesBroadBelowNarrow() throws {
        // Oracle: "create places a broad rule below an existing narrower one".
        let (store, _) = try policyStore().create(
            owner: .org, pattern: "tools.vercel.*.*.records.create", action: .block
        ).get()
        let (store2, _) = try store.create(
            owner: .org, pattern: "tools.vercel.*.*.records.*", action: .requireApproval
        ).get()
        #expect(store2.list().map(\.pattern) == [
            .segments(try segments("tools.vercel.*.*.records.create")),
            .segments(try segments("tools.vercel.*.*.records.*")),
        ])
    }

    @Test func policyCreateStoresAtRequestedOwnerUserFirst() throws {
        // Oracle: "create stores rules at the requested owner" (user rows list first).
        let (store, _) = try policyStore().create(owner: .org, pattern: "tools.vercel.*", action: .requireApproval).get()
        let (store2, _) = try store.create(owner: .user, pattern: "tools.github.*", action: .approve).get()
        #expect(store2.list().map(\.owner) == [.user, .org])
        let created = try store2.create(
            owner: .user, pattern: "tools.x.*", action: .block, position: FractionalIndex(value: 7)
        ).get().1
        #expect(created.position == FractionalIndex(value: 7))
        #expect(created.pattern == .segments(try segments("tools.x.*")))
    }

    @Test func policyCreateRejectsMalformedPatterns() {
        // Oracle: "rejects malformed patterns".
        #expect(throws: MCPToolPolicyMutationError.invalidPattern) {
            try self.policyStore().create(owner: .org, pattern: "tools.vercel..bad", action: .block).get()
        }
    }

    @Test func policyUpdateMutatesRowInPlace() throws {
        // Oracle: "update mutates the row in place".
        let (store, created) = try policyStore().create(
            owner: .org, pattern: "tools.vercel.*", action: .requireApproval
        ).get()
        let (store2, updated) = try store.update(id: created.id, owner: .org, action: .block).get()
        #expect(updated.id == created.id)
        #expect(updated.action == .block)
        #expect(store2.list().first?.action == .block)
        let (store3, repatterned) = try store2.update(
            id: created.id, owner: .org, pattern: "tools.vercel.dns.*",
            position: FractionalIndex(value: 3)
        ).get()
        #expect(repatterned.pattern == .segments(try segments("tools.vercel.dns.*")))
        #expect(repatterned.position == FractionalIndex(value: 3))
        let (_, noop) = try store3.update(id: created.id, owner: .org).get()
        #expect(noop == repatterned)
    }

    @Test func policyUpdateFailsWhenRowVanishes() throws {
        // Oracle: "fails when the policy vanishes during update".
        let (store, created) = try policyStore().create(
            owner: .org, pattern: "tools.vercel.*", action: .requireApproval
        ).get()
        #expect(throws: MCPToolPolicyMutationError.policyNotFound) {
            try store.update(id: "no-such-id", owner: .org, action: .block).get()
        }
        #expect(throws: MCPToolPolicyMutationError.policyNotFound) {
            try store.update(id: created.id, owner: .user, action: .block).get()
        }
        // A bad pattern wins over a missing id (Executor validates first).
        #expect(throws: MCPToolPolicyMutationError.invalidPattern) {
            try store.update(id: "no-such-id", owner: .org, pattern: "tools..bad").get()
        }
    }

    @Test func policyRemoveDeletesRuleAndIsIdempotent() throws {
        // Oracle: "remove deletes the rule".
        let (store, created) = try policyStore().create(
            owner: .org, pattern: "tools.vercel.*", action: .block
        ).get()
        let removed = store.remove(id: created.id, owner: .org)
        #expect(removed.list().isEmpty)
        #expect(removed.remove(id: created.id, owner: .org).list().isEmpty)
        #expect(removed.remove(id: "no-such-id", owner: .user).list().isEmpty)
    }

    @Test func policyRemoveIsOwnerScoped() throws {
        let (store, org) = try policyStore().create(owner: .org, pattern: "tools.a.*", action: .block).get()
        let (store2, user) = try store.create(owner: .user, pattern: "tools.a.*", action: .block).get()
        #expect(store2.remove(id: org.id, owner: .user).list().count == 2)
        #expect(store2.remove(id: org.id, owner: .org).list().map(\.id) == [user.id])
    }

    @Test func mutationsPreservePinsAndFallbackWithoutProvider() throws {
        let target = try address("tools.github.acme.main.read")
        let pin = StaticFqidPin(address: target, action: .approve)
        let store = MCPPolicyStore(staticFqids: [pin], pluginDefault: .block)
        let (store2, created) = try store.create(owner: .user, pattern: "tools.a.*", action: .block).get()
        // Pins survive the rebase and win on the providerless plane.
        #expect(store2.resolve(target).provenance == .staticPin(literal: target.literal))
        #expect(store2.resolve(target).action == .approve)
        let (store3, _) = try store2.update(id: created.id, owner: .user, action: .approve).get()
        #expect(store3.resolve(target).provenance == .staticPin(literal: target.literal))
        #expect(store3.remove(id: created.id, owner: .user).resolve(target).action == .approve)
        // The fallback still applies off-pin.
        #expect(store3.resolve(try address("tools.other.x.y.z")).action == .block)
    }

    @Test func mutationsPreserveProvider() throws {
        let provider = ListOnlyProvider(rules: [])
        let store = MCPPolicyStore(pluginDefault: .block, provider: provider)
        let (store2, created) = try store.create(owner: .user, pattern: "tools.a.*", action: .block).get()
        // The provider still replaces the pattern tier after every mutation
        // (empty allowlist blocks, even where the fresh row would match).
        let fresh = try address("tools.a.b.c.d")
        #expect(store2.resolve(fresh).action == .block)
        let (store3, _) = try store2.update(id: created.id, owner: .user, action: .approve).get()
        #expect(store3.resolve(fresh).action == .block)
        #expect(store3.remove(id: created.id, owner: .user).resolve(fresh).action == .block)
    }

    @Test func resolveRanksBothOwnersWithoutProvider() throws {
        // No provider: each owner contributes its first match, then the most
        // restrictive contribution wins.
        let (store, _) = try policyStore().create(
            owner: .org, pattern: "tools.a.*", action: .requireApproval
        ).get()
        let (store2, _) = try store.create(owner: .user, pattern: "tools.a.*", action: .block).get()
        let verdict = store2.resolve(try address("tools.a.b.c.d"))
        let userID = try #require(store2.list().first(where: { $0.owner == .user })?.id)
        #expect(verdict.action == .block)
        #expect(verdict.provenance == .pattern(id: userID, owner: .user))
    }

    @Test func resolveTiesBreakToOrgWithoutProvider() throws {
        // Equal actions resolve to the higher-ranked owner.
        let (store, _) = try policyStore().create(owner: .user, pattern: "tools.a.*", action: .block).get()
        let (store2, _) = try store.create(owner: .org, pattern: "tools.a.*", action: .block).get()
        let verdict = store2.resolve(try address("tools.a.b.c.d"))
        let orgID = try #require(store2.list().first(where: { $0.owner == .org })?.id)
        #expect(verdict.action == .block)
        #expect(verdict.provenance == .pattern(id: orgID, owner: .org))
    }

    @Test func connectedToolKeepsBlockDefault() throws {
        // RV extension beyond Executor's boolean default: a store with a
        // block default keeps it for connected-but-unmatched tools.
        let store = try workspaceKit()
        let verdict = store.resolvePolicyForSlug(
            "workspace-kit", toolID: "tools.github.org.main.repos.list", defaultAction: .block
        )
        #expect(verdict.action == .block)
        #expect(verdict.match == nil)
        #expect(verdict.effectivePolicy() == EffectivePolicy(action: .block, provenance: .fallback))
    }

    @Test func policyListOrdersWithinOwnerByPositionThenID() throws {
        let (store, _) = try policyStore().create(
            owner: .user, pattern: "tools.b.*", action: .block, position: FractionalIndex(value: 2)
        ).get()
        let (store2, _) = try store.create(
            owner: .user, pattern: "tools.a.*", action: .block, position: FractionalIndex(value: 1)
        ).get()
        #expect(store2.list().map(\.pattern) == [
            .segments(try segments("tools.a.*")),
            .segments(try segments("tools.b.*")),
        ])
    }

    // MARK: - Provider hook (active tool-policy provider)

    @Test func providerDefaultsToUnimplementedResolveAndPrepare() throws {
        let provider = ListOnlyProvider(rules: [])
        #expect(provider.resolve(try address("tools.a.b.c.d"), defaultAction: .approve) == nil)
        #expect(provider.prepare() == nil)
    }

    @Test func providerDoublesServeEveryWitness() throws {
        // Helper smoke only: asserts the test doubles' own witnesses behave
        // (the precedence tests deliberately never reach these arms, since
        // prepared beats resolve beats list). Excluded from production-
        // behavior coverage claims: it pins doubles, not the store.
        let rule = MCPToolPolicyProviderRule(
            id: "r", pattern: try segments("tools.a.*"),
            action: .block, position: FractionalIndex(value: 0), owner: .user
        )
        let verdict = EffectivePolicy(action: .approve, provenance: .fallback)
        let prepared = MCPPreparedToolPolicy(resolve: { _, _ in verdict }, dynamicScope: [])
        #expect(prepared.resolve(try address("tools.a.b.c.d"), .block) == verdict)
        #expect(ResolveOnlyProvider(rules: [rule], verdict: verdict).list() == [rule])
        let full = FullProvider(verdict: verdict, prepared: prepared)
        #expect(full.list().isEmpty)
        #expect(full.resolve(try address("tools.a.b.c.d"), defaultAction: .block) == verdict)
        #expect(CountingProvider(counter: CallCounter(), rules: [rule]).list() == [rule])
    }

    @Test func activeProviderReplacesStoreRows() throws {
        // Oracle: "uses provider rules as an allowlist for list, schema, and execute".
        // Scoping enforcement: only the active toolkit's rules apply.
        let (store, _) = try policyStore().create(owner: .org, pattern: "tools.*", action: .approve).get()
        let toolkits = try workspaceKit()
        let provider = MCPToolkitPolicyProvider(store: toolkits, slug: "workspace-kit")
        #expect(provider.list().isEmpty)
        let scoped = MCPPolicyStore(
            policies: store.list(), pluginDefault: .approve, provider: provider
        )
        // The store's own approve-all row is ignored: unconnected tools block.
        #expect(scoped.resolve(try address("tools.slack.org.main.chat.post")).action == .block)
        #expect(scoped.resolve(try address("tools.github.org.main.repos.list")).action == .approve)
    }

    @Test func toolkitProviderServesListResolveAndPrepare() throws {
        let toolkits = try workspaceKit()
        let provider = MCPToolkitPolicyProvider(store: toolkits, slug: "workspace-kit")
        #expect(provider.list().isEmpty)
        let direct = try #require(provider.resolve(try address("tools.github.org.main.repos.list"), defaultAction: .approve))
        #expect(direct.action == .approve)
        #expect(direct.provenance == .fallback)
        let prepared = try #require(provider.prepare())
        #expect(prepared.dynamicScope?.isEmpty == false)
    }

    @Test func staticPinsDoNotPierceTheScopedPlane() throws {
        // Ruling: when a provider is active, the static tier is skipped and
        // the verdict depends only on the toolkit — pins neither grant nor
        // deny scoped tools.
        let admitted = try address("tools.github.org.main.repos.list")
        let outside = try address("tools.slack.org.main.chat.post")
        let toolkits = try workspaceKit()
        let scoped = MCPPolicyStore(
            staticFqids: [
                // A block pin on a toolkit-admitted tool is ignored.
                StaticFqidPin(address: admitted, action: .block),
                // An approve pin outside the access set is ignored: the
                // boundary still blocks.
                StaticFqidPin(address: outside, action: .approve),
            ],
            pluginDefault: .approve,
            provider: MCPToolkitPolicyProvider(store: toolkits, slug: "workspace-kit")
        )
        let admittedVerdict = scoped.resolve(admitted)
        #expect(admittedVerdict.action == .approve)
        #expect(admittedVerdict.provenance != .staticPin(literal: admitted.literal))
        let outsideVerdict = scoped.resolve(outside)
        #expect(outsideVerdict.action == .block)
        #expect(outsideVerdict.provenance != .staticPin(literal: outside.literal))
    }

    @Test func staticPinsWinOnTheProviderlessPlane() throws {
        // Same pins, no provider: the static tier wins first, both directions.
        let approved = try address("tools.github.org.main.repos.list")
        let blocked = try address("tools.slack.org.main.chat.post")
        let store = MCPPolicyStore(
            staticFqids: [
                StaticFqidPin(address: approved, action: .approve),
                StaticFqidPin(address: blocked, action: .block),
            ],
            pluginDefault: .block
        )
        #expect(store.resolve(approved).action == .approve)
        #expect(store.resolve(approved).provenance == .staticPin(literal: approved.literal))
        #expect(store.resolve(blocked).action == .block)
        #expect(store.resolve(blocked).provenance == .staticPin(literal: blocked.literal))
    }

    @Test func listFallbackFirstMatchesThenBlocksAtBoundary() throws {
        // Oracle: resolveProviderPolicyFromRules (executor.ts:5440-5457).
        let allowed = try address("tools.fixture.org.ctl.allowed")
        let hidden = try address("tools.fixture.org.ctl.hidden")
        let provider = ListOnlyProvider(rules: [
            MCPToolPolicyProviderRule(
                id: "allow", pattern: try segments("tools.fixture.org.ctl.allowed"),
                action: .approve, position: FractionalIndex(value: 1), owner: .user
            ),
            MCPToolPolicyProviderRule(
                id: "deny-other", pattern: try segments("tools.other.*"),
                action: .block, position: FractionalIndex(value: 0), owner: .org
            ),
        ])
        let store = MCPPolicyStore(pluginDefault: .approve, provider: provider)
        let hit = store.resolve(allowed)
        #expect(hit.action == .approve)
        #expect(hit.provenance == .pattern(id: "allow", owner: .user))
        let miss = store.resolve(hidden)
        #expect(miss.action == .block)
        #expect(miss.provenance == .fallback)
    }

    @Test func directResolveBeatsListedRules() throws {
        let direct = EffectivePolicy(action: .requireApproval, provenance: .fallback)
        let provider = ResolveOnlyProvider(
            rules: [
                MCPToolPolicyProviderRule(
                    id: "r", pattern: try segments("tools.*"),
                    action: .approve, position: FractionalIndex(value: 0), owner: .user
                )
            ],
            verdict: direct
        )
        let store = MCPPolicyStore(pluginDefault: .approve, provider: provider)
        #expect(store.resolve(try address("tools.a.b.c.d")) == direct)
    }

    @Test func preparedSnapshotBeatsDirectResolve() throws {
        let preparedVerdict = EffectivePolicy(action: .block, provenance: .fallback)
        let provider = FullProvider(
            verdict: EffectivePolicy(action: .approve, provenance: .fallback),
            prepared: MCPPreparedToolPolicy(resolve: { _, _ in preparedVerdict }, dynamicScope: [])
        )
        let store = MCPPolicyStore(pluginDefault: .approve, provider: provider)
        #expect(store.resolve(try address("tools.a.b.c.d")) == preparedVerdict)
    }

    @Test func preparedCapturesSnapshotOncePerBatch() throws {
        // prepared() snapshots once; every resolve in the batch reuses it.
        let counter = CallCounter()
        let provider = CountingProvider(counter: counter, rules: [])
        let store = MCPPolicyStore(pluginDefault: .approve, provider: provider)
        let batch = store.prepared()
        #expect(counter.value == 1)
        _ = batch.resolve(try address("tools.a.b.c.d"))
        _ = batch.resolve(try address("tools.e.f.g.h"))
        #expect(counter.value == 1)
    }

    @Test func directResolveSnapshotsPerCall() throws {
        // Without prepared(), resolve() snapshots on every call (the N+1 the
        // batch path avoids); behavior stays identical.
        let counter = CallCounter()
        let provider = CountingProvider(counter: counter, rules: [])
        let store = MCPPolicyStore(pluginDefault: .approve, provider: provider)
        #expect(store.resolve(try address("tools.a.b.c.d")).action == .block)
        #expect(store.resolve(try address("tools.e.f.g.h")).action == .block)
        #expect(counter.value == 2)
    }

    @Test func preparedWithoutProviderMatchesRows() throws {
        let (store, created) = try policyStore().create(owner: .user, pattern: "tools.a.*", action: .block).get()
        let batch = store.prepared()
        let verdict = batch.resolve(try address("tools.a.b.c.d"))
        #expect(verdict.action == .block)
        #expect(verdict.provenance == .pattern(id: created.id, owner: .user))
        #expect(batch.resolve(try address("tools.z.z.z.z")).isFallback)
    }

    @Test func preparedWithoutPrepareFallsBackToRows() throws {
        // A list-only provider has no prepare: prepared() still resolves via list.
        let provider = ListOnlyProvider(rules: [
            MCPToolPolicyProviderRule(
                id: "r", pattern: try segments("tools.a.*"),
                action: .requireApproval, position: FractionalIndex(value: 0), owner: .org
            )
        ])
        let batch = MCPPolicyStore(pluginDefault: .approve, provider: provider).prepared()
        #expect(batch.resolve(try address("tools.a.b.c.d")).action == .requireApproval)
        #expect(batch.resolve(try address("tools.z.z.z.z")).action == .block)
    }

    @Test func preparedPolicyExposesDynamicScope() throws {
        // Providerless: nil (unrestricted read).
        #expect(policyStore().prepared().dynamicScope == nil)
        // A provider with no prepare snapshot: nil as well.
        let listOnly = MCPPolicyStore(pluginDefault: .approve, provider: ListOnlyProvider(rules: []))
        #expect(listOnly.prepared().dynamicScope == nil)
        // A toolkit provider: the slug's prepared prefixes.
        let toolkits = try workspaceKit()
        let scoped = MCPPolicyStore(
            pluginDefault: .approve,
            provider: MCPToolkitPolicyProvider(store: toolkits, slug: "workspace-kit")
        )
        #expect(
            scoped.prepared().dynamicScope
                == toolkits.preparePolicyResolverForSlug("workspace-kit").dynamicScope
        )
        #expect(scoped.prepared().dynamicScope?.isEmpty == false)
    }

    @Test func blockedPredicateMirrorsAllows() throws {
        let inside = try address("tools.github.org.main.deploy")
        let outside = try address("tools.slack.org.main.post")
        // Nil scopes block nothing; empty scopes block everything.
        #expect(MCPDynamicToolScope.blockedPredicate(scopes: nil)(inside) == false)
        #expect(MCPDynamicToolScope.blockedPredicate(scopes: [])(inside))
        // Otherwise the predicate is the negation of allows().
        let scopes: [MCPDynamicToolScope]? = [
            MCPDynamicToolScope(integration: "github", owner: nil, connection: nil)
        ]
        #expect(MCPDynamicToolScope.blockedPredicate(scopes: scopes)(inside) == false)
        #expect(MCPDynamicToolScope.blockedPredicate(scopes: scopes)(outside))
    }

    @Test func providerSnapshotFreezesStoreEdits() throws {
        // Providers hold values: later store edits need a fresh provider.
        let (store, toolkit) = try createdToolkit()
        let scoped = MCPPolicyStore(
            pluginDefault: .approve,
            provider: MCPToolkitPolicyProvider(store: store, slug: "deploy-kit")
        )
        let target = try address("tools.a.b.c.d")
        #expect(scoped.resolve(target).action == .block)
        let grown = try store.createConnection(toolkit.id, pattern: "tools.a.*").get().0
        // The old provider still sees the empty snapshot.
        #expect(scoped.resolve(target).action == .block)
        let fresh = MCPPolicyStore(
            pluginDefault: .approve,
            provider: MCPToolkitPolicyProvider(store: grown, slug: "deploy-kit")
        )
        #expect(fresh.resolve(target).action == .approve)
    }

    @Test func scopedReadsNarrowToPreparedPrefixes() throws {
        // Oracle: "restricts the list to the scoped connection" /
        // "a wildcard position widens the scope" / "an empty scope reads no rows".
        let store = try workspaceKit()
        let scopes = store.preparePolicyResolverForSlug("workspace-kit").dynamicScope
        #expect(MCPDynamicToolScope.allows(try address("tools.github.org.main.deploy"), scopes: scopes))
        #expect(
            MCPDynamicToolScope.allows(try address("tools.github.org.other.deploy"), scopes: scopes) == false
        )
        let wide: [MCPDynamicToolScope]? = [MCPDynamicToolScope(integration: nil, owner: "org", connection: nil)]
        #expect(MCPDynamicToolScope.allows(try address("tools.github.org.main.deploy"), scopes: wide))
        #expect(MCPDynamicToolScope.allows(try address("tools.slack.org.main.post"), scopes: wide))
        #expect(MCPDynamicToolScope.allows(try address("tools.x.user.y.z"), scopes: wide) == false)
    }

    // MARK: - Scoping enforcement

    @Test func toolkitRulesDoNotLeakAcrossSlugs() throws {
        // Only the resolved slug's rules apply: Kit A's approve-all never
        // authorizes tools resolved under Kit B's slug.
        let (store, toolkit) = try createdToolkit(name: "Kit A")
        let (store2, _) = try store.createConnection(toolkit.id, pattern: "tools.*").get()
        let (store3, _) = try store2.createPolicy(toolkit.id, pattern: "tools.*", action: .approve).get()
        let (store4, _) = try store3.create(owner: .org, name: "Kit B").get()
        #expect(
            store4.resolvePolicyForSlug("kit-a", toolID: "tools.x.org.y.z", defaultAction: .block).action
                == .approve
        )
        let verdict = store4.resolvePolicyForSlug("kit-b", toolID: "tools.x.org.y.z", defaultAction: .approve)
        #expect(verdict.action == .block)
        #expect(verdict.match == nil)
        #expect(store4.policyRulesForSlug("kit-b").isEmpty)
        // A provider bound to B inside a store with approve-all rows still
        // blocks: the store's own rows are ignored and B contributes nothing.
        let (rows, _) = try policyStore().create(owner: .org, pattern: "tools.*", action: .approve).get()
        let scoped = MCPPolicyStore(
            policies: rows.list(), pluginDefault: .approve,
            provider: MCPToolkitPolicyProvider(store: store4, slug: "kit-b")
        )
        #expect(scoped.resolve(try address("tools.x.org.y.z")).action == .block)
    }

    @Test func policyMutationsAreToolkitScoped() throws {
        let (store, first) = try createdToolkit(name: "First Kit")
        let (store2, second) = try store.create(owner: .org, name: "Second Kit").get()
        let (store3, policy) = try store2.createPolicy(first.id, pattern: "tools.a.*", action: .block).get()
        let (store4, connection) = try store3.createConnection(first.id, pattern: "tools.a.*").get()
        // The sibling toolkit's ids address nothing here.
        #expect(throws: MCPToolkitError.policyNotFound) {
            try store4.updatePolicy(second.id, policy.id, action: .approve).get()
        }
        #expect(throws: MCPToolkitError.policyNotFound) {
            try store4.removePolicy(second.id, policy.id).get()
        }
        #expect(throws: MCPToolkitError.connectionNotFound) {
            try store4.removeConnection(second.id, connection.id).get()
        }
        // And the owning toolkit still holds its rows.
        #expect(try store4.listPolicies(first.id).get().count == 1)
        #expect(try store4.listConnections(first.id).get().count == 1)
    }

    @Test func invalidPatternBeatsMissingToolkit() throws {
        // Executor validates the pattern before the toolkit lookup.
        let store = MCPToolkitStore()
        #expect(throws: MCPToolkitError.invalidPattern) {
            try store.createPolicy("no-such-kit", pattern: "tools..bad", action: .block).get()
        }
        #expect(throws: MCPToolkitError.invalidPattern) {
            try store.updatePolicy("no-such-kit", "no-such-policy", pattern: "tools..bad").get()
        }
        #expect(throws: MCPToolkitError.invalidPattern) {
            try store.createConnection("no-such-kit", pattern: "tools..bad").get()
        }
    }

    @Test func slugCollisionIgnoresCase() throws {
        let (store, _) = try createdToolkit()
        #expect(throws: MCPToolkitError.slugInUse) {
            try store.create(owner: .user, name: "Other", slug: "DEPLOY-KIT").get()
        }
        let (store2, other) = try store.create(owner: .user, name: "Other").get()
        #expect(throws: MCPToolkitError.slugInUse) {
            try store2.update(other.id, slug: "  Deploy-Kit ").get()
        }
    }

    // MARK: - File bridges

    @Test func toolkitFileBridgeRoundTrips() throws {
        let file = MCPFileToolkit(
            id: "tk1", owner: .org, slug: "deploy-kit", name: "Deploy Kit",
            policies: [
                MCPFileToolkitPolicy(
                    id: "p1", pattern: try segments("tools.a.*"), action: .block,
                    position: FractionalIndex(value: 1)
                )
            ],
            connections: [
                MCPFileToolkitConnection(
                    id: "c1", pattern: try segments("tools.a.*"), position: FractionalIndex(value: 0)
                )
            ]
        )
        let toolkit = try #require(MCPToolkit(file: file))
        #expect(toolkit.slug.rawValue == "deploy-kit")
        #expect(toolkit.policies.map(\.id) == ["p1"])
        #expect(toolkit.connections.map(\.id) == ["c1"])
        let store = try #require(MCPToolkitStore(fileToolkits: [file]))
        #expect(store.list().count == 1)
        #expect(MCPToolkitStore(fileToolkits: [])?.list().isEmpty == true)
    }

    @Test func toolkitFileBridgeRejectsBadSlug() throws {
        let bad = MCPFileToolkit(
            id: "tk1", owner: .org, slug: "-bad-", name: "Bad",
            policies: [], connections: []
        )
        #expect(MCPToolkit(file: bad) == nil)
        let good = MCPFileToolkit(
            id: "tk2", owner: .org, slug: "good", name: "Good",
            policies: [], connections: []
        )
        #expect(MCPToolkitStore(fileToolkits: [good, bad]) == nil)
    }

    @Test func toolkitFileBridgeRejectsInvalidModels() throws {
        // The bridge judges hand-built records through the loader's value
        // rules, exactly like `decode` judges bytes.
        let pattern = try segments("tools.a.*")
        let position = FractionalIndex(value: 0)
        let badID = MCPFileToolkit(
            id: "not an id", owner: .org, slug: "kit", name: "Kit",
            policies: [], connections: []
        )
        #expect(MCPToolkit(file: badID) == nil)
        let badName = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "", policies: [], connections: []
        )
        #expect(MCPToolkit(file: badName) == nil)
        let upperSlug = MCPFileToolkit(
            id: "tk", owner: .org, slug: "UPPER", name: "Kit", policies: [], connections: []
        )
        #expect(MCPToolkit(file: upperSlug) == nil)
        let tooLong = MCPFileToolkit(
            id: String(repeating: "a", count: 129), owner: .org, slug: "kit", name: "Kit",
            policies: [], connections: []
        )
        #expect(MCPToolkit(file: tooLong) == nil)
        let tooLongNested = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: [
                MCPFileToolkitPolicy(
                    id: String(repeating: "p", count: 129), pattern: pattern, action: .block,
                    position: position
                )
            ],
            connections: []
        )
        #expect(MCPToolkit(file: tooLongNested) == nil)
        let badNested = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: [
                MCPFileToolkitPolicy(id: "mcp:x", pattern: pattern, action: .block, position: position)
            ],
            connections: []
        )
        #expect(MCPToolkit(file: badNested) == nil)
        let dupNested = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: [MCPFileToolkitPolicy(id: "dup", pattern: pattern, action: .block, position: position)],
            connections: [MCPFileToolkitConnection(id: "dup", pattern: pattern, position: position)]
        )
        #expect(MCPToolkit(file: dupNested) == nil)
    }

    @Test func toolkitStoreBridgeRejectsDuplicateIDsAndSlugs() throws {
        let good = MCPFileToolkit(
            id: "tk1", owner: .org, slug: "kit-one", name: "One", policies: [], connections: []
        )
        let dupID = MCPFileToolkit(
            id: "tk1", owner: .user, slug: "kit-two", name: "Two", policies: [], connections: []
        )
        #expect(MCPToolkitStore(fileToolkits: [good, dupID]) == nil)
        let dupSlug = MCPFileToolkit(
            id: "tk2", owner: .user, slug: "kit-one", name: "Two", policies: [], connections: []
        )
        #expect(MCPToolkitStore(fileToolkits: [good, dupSlug]) == nil)
        #expect(MCPToolkitStore(fileToolkits: [good])?.list().count == 1)
    }

    @Test func filePolicyBridgeRejectsInvalidModels() throws {
        let pattern = try segments("tools.a.*")
        let badCharset = MCPFilePolicy(
            id: "not an id", owner: .user, pattern: pattern, action: .block,
            position: FractionalIndex(value: 1)
        )
        #expect(ToolPolicy(filePolicy: badCharset) == nil)
        let empty = MCPFilePolicy(
            id: "", owner: .user, pattern: pattern, action: .block,
            position: FractionalIndex(value: 1)
        )
        #expect(ToolPolicy(filePolicy: empty) == nil)
        let tooLong = MCPFilePolicy(
            id: String(repeating: "a", count: 129), owner: .user, pattern: pattern,
            action: .block, position: FractionalIndex(value: 1)
        )
        #expect(ToolPolicy(filePolicy: tooLong) == nil)
        let infinite = MCPFilePolicy(
            id: "p", owner: .user, pattern: pattern, action: .block,
            position: FractionalIndex(value: .infinity)
        )
        #expect(ToolPolicy(filePolicy: infinite) == nil)
    }

    @Test func filePolicyBridgeBuildsSegmentRule() throws {
        let file = MCPFilePolicy(
            id: "p1", owner: .user, pattern: try segments("tools.a.*"), action: .block,
            position: FractionalIndex(value: 2)
        )
        let policy = try #require(ToolPolicy(filePolicy: file))
        #expect(policy.pattern == .segments(try segments("tools.a.*")))
        let store = MCPPolicyStore(policies: [policy], pluginDefault: .approve)
        #expect(store.resolve(try address("tools.a.b.c.d")).action == .block)
    }

    // MARK: - Stress

    @Test func stressHundredRuleFirstMatch() throws {
        var store = MCPToolkitStore()
        let toolkit: MCPToolkit
        (store, toolkit) = try store.create(owner: .org, name: "Big Kit").get()
        store = try store.createConnection(toolkit.id, pattern: "tools.*").get().0
        for index in 0..<100 {
            store = try store.createPolicy(
                toolkit.id, pattern: "tools.i\(index).org.main.*", action: .block
            ).get().0
        }
        let listed = try store.listPolicies(toolkit.id).get()
        #expect(listed.count == 100)
        #expect(
            store.resolvePolicyForSlug("big-kit", toolID: "tools.i42.org.main.tool", defaultAction: .approve).action
                == .block
        )
        #expect(
            store.resolvePolicyForSlug("big-kit", toolID: "tools.zzz.org.main.tool", defaultAction: .approve).action
                == .approve
        )
    }

    @Test func stressPolicyStoreMutationChurn() throws {
        var store = policyStore()
        var rows: [(id: String, owner: PolicyOwner)] = []
        for index in 0..<50 {
            let owner: PolicyOwner = index % 2 == 0 ? .org : .user
            let next: MCPPolicyStore
            let created: ToolPolicy
            (next, created) = try store.create(
                owner: owner, pattern: "tools.i\(index).*", action: .block
            ).get()
            store = next
            rows.append((created.id, owner))
        }
        #expect(store.list().count == 50)
        for row in rows.prefix(25) {
            store = try store.update(id: row.id, owner: row.owner, action: .approve).get().0
        }
        #expect(store.list().filter { $0.action == .approve }.count == 25)
        for row in rows.suffix(25) {
            store = store.remove(id: row.id, owner: row.owner)
        }
        #expect(store.list().count == 25)
        #expect(store.resolve(try address("tools.i0.x.y.z")).action == .approve)
        #expect(store.resolve(try address("tools.i49.x.y.z")).isFallback)
    }
}

// MARK: - Provider doubles

private struct ListOnlyProvider: MCPToolPolicyProvider, Sendable {
    let rules: [MCPToolPolicyProviderRule]

    func list() -> [MCPToolPolicyProviderRule] {
        rules
    }
}

private struct ResolveOnlyProvider: MCPToolPolicyProvider, Sendable {
    let rules: [MCPToolPolicyProviderRule]
    let verdict: EffectivePolicy

    func list() -> [MCPToolPolicyProviderRule] {
        rules
    }

    func resolve(_ address: MCPToolAddress, defaultAction: PolicyAction) -> EffectivePolicy? {
        verdict
    }
}

private struct FullProvider: MCPToolPolicyProvider, Sendable {
    let verdict: EffectivePolicy
    let prepared: MCPPreparedToolPolicy

    func list() -> [MCPToolPolicyProviderRule] {
        []
    }

    func resolve(_ address: MCPToolAddress, defaultAction: PolicyAction) -> EffectivePolicy? {
        verdict
    }

    func prepare() -> MCPPreparedToolPolicy? {
        prepared
    }
}

private final class CallCounter: Sendable {
    private let mutex = Mutex(0)

    func increment() {
        mutex.withLock { $0 += 1 }
    }

    var value: Int {
        mutex.withLock { $0 }
    }
}

private struct CountingProvider: MCPToolPolicyProvider, Sendable {
    let counter: CallCounter
    let rules: [MCPToolPolicyProviderRule]

    func list() -> [MCPToolPolicyProviderRule] {
        rules
    }

    func prepare() -> MCPPreparedToolPolicy? {
        counter.increment()
        return MCPPreparedToolPolicy(
            resolve: { _, _ in EffectivePolicy(action: .block, provenance: .fallback) },
            dynamicScope: []
        )
    }
}