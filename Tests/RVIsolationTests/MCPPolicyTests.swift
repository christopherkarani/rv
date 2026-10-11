import Foundation
import RVDomain
import Testing
@testable import RVIsolation

@Suite("MCPPolicy")
struct MCPPolicyTests {
    private func address(_ literal: String) throws -> MCPToolAddress {
        try MCPToolAddress.parse(literal)
    }

    private func policy(
        _ id: String,
        _ owner: PolicyOwner,
        _ pattern: ToolPattern,
        _ action: PolicyAction,
        _ position: Double
    ) -> ToolPolicy {
        ToolPolicy(
            id: id,
            owner: owner,
            pattern: pattern,
            action: action,
            position: FractionalIndex(value: position)
        )
    }

    @Test(arguments: [PolicyAction.approve, .requireApproval, .block])
    func emptyStoreFallsBackToInjectedDefault(fallback: PolicyAction) throws {
        let store = MCPPolicyStore(pluginDefault: fallback)
        let resolved = store.resolve(try address("tools.github.acme.main.read"))
        #expect(resolved.action == fallback)
        #expect(resolved.provenance == .fallback)
        #expect(resolved.isFallback)
    }

    @Test func singleExactMatchWinsWithProvenance() throws {
        let target = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            policies: [policy("p1", .user, .exact(target), .requireApproval, 1)],
            pluginDefault: .approve
        )
        let resolved = store.resolve(target)
        #expect(resolved.action == .requireApproval)
        #expect(resolved.provenance == .pattern(id: "p1", owner: .user))
        #expect(resolved.isFallback == false)
    }

    @Test func firstMatchPerOwnerUsesPositionNotRestrictiveness() throws {
        let target = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            policies: [
                policy("approve-first", .user, .any, .approve, 1),
                policy("block-second", .user, .any, .block, 2),
            ],
            pluginDefault: .block
        )
        let resolved = store.resolve(target)
        #expect(resolved.action == .approve)
        #expect(resolved.provenance == .pattern(id: "approve-first", owner: .user))
    }

    @Test func positionTieBreaksById() throws {
        let target = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            policies: [
                policy("zebra", .org, .any, .approve, 1),
                policy("apple", .org, .any, .block, 1),
            ],
            pluginDefault: .approve
        )
        let resolved = store.resolve(target)
        #expect(resolved.action == .block)
        #expect(resolved.provenance == .pattern(id: "apple", owner: .org))
    }

    @Test func exactTieKeepsInitOrder() throws {
        let target = try address("tools.github.acme.main.read")
        let forward = MCPPolicyStore(
            policies: [
                policy("same", .user, .any, .approve, 1),
                policy("same", .user, .any, .block, 1),
            ],
            pluginDefault: .block
        )
        #expect(forward.resolve(target).action == .approve)
        let backward = MCPPolicyStore(
            policies: [
                policy("same", .user, .any, .block, 1),
                policy("same", .user, .any, .approve, 1),
            ],
            pluginDefault: .block
        )
        #expect(backward.resolve(target).action == .block)
    }

    @Test func orgBlockBeatsUserApprove() throws {
        let target = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            policies: [
                policy("org-deny", .org, .any, .block, 9),
                policy("user-allow", .user, .any, .approve, 1),
            ],
            pluginDefault: .approve
        )
        let resolved = store.resolve(target)
        #expect(resolved.action == .block)
        #expect(resolved.provenance == .pattern(id: "org-deny", owner: .org))
    }

    @Test func userBlockBeatsOrgApprove() throws {
        let target = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            policies: [
                policy("org-allow", .org, .any, .approve, 1),
                policy("user-deny", .user, .any, .block, 1),
            ],
            pluginDefault: .approve
        )
        let resolved = store.resolve(target)
        #expect(resolved.action == .block)
        #expect(resolved.provenance == .pattern(id: "user-deny", owner: .user))
    }

    @Test func requireApprovalBeatsApproveAcrossOwners() throws {
        let target = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            policies: [
                policy("org-allow", .org, .any, .approve, 1),
                policy("user-gate", .user, .any, .requireApproval, 1),
            ],
            pluginDefault: .approve
        )
        let resolved = store.resolve(target)
        #expect(resolved.action == .requireApproval)
        #expect(resolved.provenance == .pattern(id: "user-gate", owner: .user))
    }

    @Test func actionTieResolvesToOrg() throws {
        let target = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            policies: [
                policy("user-gate", .user, .any, .requireApproval, 1),
                policy("org-gate", .org, .any, .requireApproval, 5),
            ],
            pluginDefault: .approve
        )
        let resolved = store.resolve(target)
        #expect(resolved.action == .requireApproval)
        #expect(resolved.provenance == .pattern(id: "org-gate", owner: .org))
    }

    @Test func unmatchedAddressFallsBack() throws {
        let store = MCPPolicyStore(
            policies: [
                policy(
                    "github-only", .org,
                    .trailingPrefix("tools.github."), .block, 1
                ),
            ],
            pluginDefault: .requireApproval
        )
        let resolved = store.resolve(try address("tools.gitlab.acme.main.read"))
        #expect(resolved.action == .requireApproval)
        #expect(resolved.isFallback)
    }

    @Test func staticPinBypassesOrgBlock() throws {
        let target = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            policies: [policy("org-deny", .org, .any, .block, 1)],
            staticFqids: [StaticFqidPin(address: target, action: .approve)],
            pluginDefault: .block
        )
        let resolved = store.resolve(target)
        #expect(resolved.action == .approve)
        #expect(resolved.provenance == .staticPin(literal: target.literal))
        #expect(resolved.isFallback == false)
    }

    @Test func staticPinBlockBypassesApprovePatterns() throws {
        let target = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            policies: [
                policy("org-allow", .org, .any, .approve, 1),
                policy("user-allow", .user, .any, .approve, 1),
            ],
            staticFqids: [StaticFqidPin(address: target, action: .block)],
            pluginDefault: .approve
        )
        let resolved = store.resolve(target)
        #expect(resolved.action == .block)
        #expect(resolved.provenance == .staticPin(literal: target.literal))
    }

    @Test func staticPinIsExactOnly() throws {
        let pinned = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            staticFqids: [StaticFqidPin(address: pinned, action: .approve)],
            pluginDefault: .block
        )
        #expect(store.resolve(pinned).action == .approve)
        #expect(store.resolve(try address("tools.github.acme.main.write")).action == .block)
        #expect(store.resolve(try address("tools.gitlab.acme.main.read")).action == .block)
    }

    @Test func duplicateStaticPinsLastWins() throws {
        let target = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            staticFqids: [
                StaticFqidPin(address: target, action: .approve),
                StaticFqidPin(address: target, action: .block),
            ],
            pluginDefault: .approve
        )
        #expect(store.resolve(target).action == .block)
    }

    @Test func anyPatternMatchesThroughStore() throws {
        let store = MCPPolicyStore(
            policies: [policy("catch-all", .user, .any, .requireApproval, 1)],
            pluginDefault: .approve
        )
        #expect(store.resolve(try address("tools.a.b.c.d")).action == .requireApproval)
        #expect(store.resolve(try address("tools.github.acme.main.my.tool.v2")).action == .requireApproval)
    }

    @Test func trailingPrefixMatchesThroughStore() throws {
        let loose = MCPPolicyStore(
            policies: [
                policy("loose", .user, .trailingPrefix("tools.github.acme.main.read"), .approve, 1),
            ],
            pluginDefault: .block
        )
        #expect(loose.resolve(try address("tools.github.acme.main.read")).action == .approve)
        #expect(loose.resolve(try address("tools.github.acme.main.readme")).action == .block)
        #expect(loose.resolve(try address("tools.github.acme.main.read.v2")).action == .approve)
        #expect(loose.resolve(try address("tools.github.acme.main.write")).action == .block)
        let pinned = MCPPolicyStore(
            policies: [
                policy("pinned", .user, .trailingPrefix("tools.github.acme.main.read."), .approve, 1),
            ],
            pluginDefault: .block
        )
        #expect(pinned.resolve(try address("tools.github.acme.main.readme")).action == .block)
        #expect(pinned.resolve(try address("tools.github.acme.main.read.v2")).action == .approve)
    }

    @Test func orgPresentButNonmatchingStillYieldsUserWinner() throws {
        let store = MCPPolicyStore(
            policies: [
                policy("org-other", .org, .exact(try address("tools.a.b.c.d")), .block, 1),
                policy("user-hit", .user, .trailingPrefix("tools.github."), .approve, 1),
            ],
            pluginDefault: .block
        )
        let resolved = store.resolve(try address("tools.github.acme.main.read"))
        #expect(resolved.action == .approve)
        #expect(resolved.provenance == .pattern(id: "user-hit", owner: .user))
    }

    @Test func sameOwnerBlockTiebreakPicksFirstRanked() throws {
        let store = MCPPolicyStore(
            policies: [
                policy("org-second", .org, .any, .block, 2),
                policy("org-first", .org, .any, .block, 1),
            ],
            pluginDefault: .approve
        )
        let resolved = store.resolve(try address("tools.github.acme.main.read"))
        #expect(resolved.action == .block)
        #expect(resolved.provenance == .pattern(id: "org-first", owner: .org))
    }

    @Test func staticPinLeavesOtherAddressesToPatterns() throws {
        let store = MCPPolicyStore(
            policies: [
                policy("user-any", .user, .any, .approve, 1),
            ],
            staticFqids: [
                StaticFqidPin(address: try address("tools.a.b.c.d"), action: .block),
            ],
            pluginDefault: .requireApproval
        )
        let pinned = store.resolve(try address("tools.a.b.c.d"))
        #expect(pinned.action == .block)
        #expect(pinned.provenance == .staticPin(literal: "tools.a.b.c.d"))
        let routed = store.resolve(try address("tools.github.acme.main.read"))
        #expect(routed.action == .approve)
        #expect(routed.provenance == .pattern(id: "user-any", owner: .user))
    }

    @Test func singleMidMatchesThroughStore() throws {
        let store = MCPPolicyStore(
            policies: [
                policy("mid", .user, .singleMid(prefix: "tools.", suffix: ".read"), .approve, 1),
            ],
            pluginDefault: .block
        )
        #expect(store.resolve(try address("tools.github.acme.main.read")).action == .approve)
        #expect(store.resolve(try address("tools.github.acme.main.write")).action == .block)
        let emptyMiddle = MCPPolicyStore(
            policies: [
                policy(
                    "mid", .user,
                    .singleMid(prefix: "tools.a.b.c.d", suffix: ""), .approve, 1
                ),
            ],
            pluginDefault: .block
        )
        #expect(emptyMiddle.resolve(try address("tools.a.b.c.d")).action == .block)
    }

    @Test func dotTolerantToolResolves() throws {
        let store = MCPPolicyStore(
            policies: [
                policy("gh", .org, .trailingPrefix("tools.github."), .requireApproval, 1),
            ],
            pluginDefault: .block
        )
        let resolved = store.resolve(try address("tools.github.acme.main.my.tool.v2"))
        #expect(resolved.action == .requireApproval)
        #expect(resolved.provenance == .pattern(id: "gh", owner: .org))
    }

    @Test func unicodeAddressResolves() throws {
        let target = try address("tools.héllo.世界.🔌.outil_v2")
        let store = MCPPolicyStore(
            policies: [policy("uni", .user, .exact(target), .approve, 1)],
            pluginDefault: .block
        )
        #expect(store.resolve(target).action == .approve)
        #expect(store.resolve(try address("tools.héllo.世界.🔌.autre")).action == .block)
    }

    @Test func fractionalBetweenValuesOrder() throws {
        let target = try address("tools.github.acme.main.read")
        let low = FractionalIndex(value: 1)
        let high = FractionalIndex(value: 2)
        let mid = FractionalIndex.between(low, high)
        let store = MCPPolicyStore(
            policies: [
                ToolPolicy(id: "high", owner: .user, pattern: .any, action: .block, position: high),
                ToolPolicy(id: "mid", owner: .user, pattern: .any, action: .requireApproval, position: mid),
                ToolPolicy(id: "low", owner: .user, pattern: .any, action: .approve, position: low),
            ],
            pluginDefault: .block
        )
        #expect(store.resolve(target).provenance == .pattern(id: "low", owner: .user))
        let withoutLow = MCPPolicyStore(
            policies: [
                ToolPolicy(id: "high", owner: .user, pattern: .any, action: .block, position: high),
                ToolPolicy(id: "mid", owner: .user, pattern: .any, action: .requireApproval, position: mid),
            ],
            pluginDefault: .block
        )
        #expect(withoutLow.resolve(target).provenance == .pattern(id: "mid", owner: .user))
    }

    @Test func negativeAndInfinitePositionsOrder() throws {
        let target = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            policies: [
                policy("pos-inf", .user, .any, .block, .infinity),
                policy("finite", .user, .any, .requireApproval, 0),
                policy("neg-inf", .user, .any, .approve, -.infinity),
            ],
            pluginDefault: .block
        )
        #expect(store.resolve(target).provenance == .pattern(id: "neg-inf", owner: .user))
        let topOnly = MCPPolicyStore(
            policies: [policy("pos-inf", .org, .any, .block, .infinity)],
            pluginDefault: .approve
        )
        #expect(topOnly.resolve(target).provenance == .pattern(id: "pos-inf", owner: .org))
    }

    @Test func largePolicySetResolvesFirstMatch() throws {
        let target = try address("tools.github.acme.main.read")
        var policies: [ToolPolicy] = []
        policies.append(policy("org-backstop", .org, .any, .block, 9999))
        for rank in (1...2000).reversed() {
            policies.append(policy("user-\(rank)", .user, .any, .approve, Double(rank)))
        }
        let store = MCPPolicyStore(policies: policies, pluginDefault: .approve)
        let resolved = store.resolve(target)
        #expect(resolved.action == .block)
        #expect(resolved.provenance == .pattern(id: "org-backstop", owner: .org))
        let userOnly = MCPPolicyStore(
            policies: policies.filter { $0.owner == .user },
            pluginDefault: .block
        )
        #expect(userOnly.resolve(target).provenance == .pattern(id: "user-1", owner: .user))
    }

    @Test func singleOwnerStoresResolve() throws {
        let target = try address("tools.github.acme.main.read")
        let orgOnly = MCPPolicyStore(
            policies: [policy("o", .org, .any, .requireApproval, 1)],
            pluginDefault: .approve
        )
        let orgResolved = orgOnly.resolve(target)
        #expect(orgResolved.action == .requireApproval)
        #expect(orgResolved.provenance == .pattern(id: "o", owner: .org))
        let userOnly = MCPPolicyStore(
            policies: [policy("u", .user, .any, .block, 1)],
            pluginDefault: .approve
        )
        let userResolved = userOnly.resolve(target)
        #expect(userResolved.action == .block)
        #expect(userResolved.provenance == .pattern(id: "u", owner: .user))
    }

    @Test func emptyStringIdSortsFirst() throws {
        let target = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            policies: [
                policy("zzz", .user, .any, .block, 1),
                policy("", .user, .any, .approve, 1),
            ],
            pluginDefault: .block
        )
        #expect(store.resolve(target).provenance == .pattern(id: "", owner: .user))
    }

    @Test func stringIdOrderingFollowsStringCompare() throws {
        let target = try address("tools.github.acme.main.read")
        let caseStore = MCPPolicyStore(
            policies: [
                policy("b", .user, .any, .block, 1),
                policy("B", .user, .any, .approve, 1),
            ],
            pluginDefault: .block
        )
        #expect(caseStore.resolve(target).provenance == .pattern(id: "B", owner: .user))
        let numericStore = MCPPolicyStore(
            policies: [
                policy("9", .user, .any, .block, 1),
                policy("10", .user, .any, .approve, 1),
            ],
            pluginDefault: .block
        )
        #expect(numericStore.resolve(target).provenance == .pattern(id: "10", owner: .user))
    }

    @Test func fallbackProvenanceIsNilAndIsFallback() throws {
        let store = MCPPolicyStore(pluginDefault: .requireApproval)
        let resolved = store.resolve(try address("tools.a.b.c.d"))
        #expect(resolved == EffectivePolicy(action: .requireApproval, provenance: .fallback))
        #expect(resolved.isFallback)
    }

    @Test func winsAreNotFallback() throws {
        let target = try address("tools.github.acme.main.read")
        let patternStore = MCPPolicyStore(
            policies: [policy("p", .user, .exact(target), .approve, 1)],
            pluginDefault: .approve
        )
        #expect(patternStore.resolve(target).isFallback == false)
        let pinStore = MCPPolicyStore(
            staticFqids: [StaticFqidPin(address: target, action: .block)],
            pluginDefault: .block
        )
        #expect(pinStore.resolve(target).isFallback == false)
    }

    @Test func patternExactDoesNotMatchSiblingTool() throws {
        let store = MCPPolicyStore(
            policies: [
                policy(
                    "read-only", .user,
                    .exact(try address("tools.github.acme.main.read")), .approve, 1
                ),
            ],
            pluginDefault: .block
        )
        #expect(store.resolve(try address("tools.github.acme.main.read")).action == .approve)
        #expect(store.resolve(try address("tools.github.acme.main.write")).action == .block)
        #expect(store.resolve(try address("tools.github.acme.main.readwrite")).action == .block)
    }

    @Test func staticPinWithDottedToolIsExact() throws {
        let pinned = try address("tools.github.acme.main.my.tool.v2")
        let store = MCPPolicyStore(
            staticFqids: [StaticFqidPin(address: pinned, action: .approve)],
            pluginDefault: .block
        )
        #expect(store.resolve(pinned).action == .approve)
        #expect(store.resolve(try address("tools.github.acme.main.my.tool.v3")).action == .block)
        #expect(store.resolve(try address("tools.github.acme.main.my.tool")).action == .block)
    }

    @Test func concurrentResolvesAgree() async throws {
        let target = try address("tools.github.acme.main.read")
        let store = MCPPolicyStore(
            policies: [
                policy("org-deny", .org, .any, .block, 1),
                policy("user-allow", .user, .any, .approve, 1),
            ],
            pluginDefault: .approve
        )
        let expected = store.resolve(target)
        await withTaskGroup(of: EffectivePolicy.self) { group in
            for _ in 0..<64 {
                group.addTask { store.resolve(target) }
            }
            for await resolved in group {
                #expect(resolved == expected)
            }
        }
    }

    @Test func effectivePolicyCodableRoundTrips() throws {
        let win = EffectivePolicy(action: .requireApproval, provenance: .pattern(id: "p1", owner: .org))
        let winData = try JSONEncoder().encode(win)
        #expect(try JSONDecoder().decode(EffectivePolicy.self, from: winData) == win)
        let pin = EffectivePolicy(action: .approve, provenance: .staticPin(literal: "tools.a.b.c.d"))
        let pinData = try JSONEncoder().encode(pin)
        #expect(try JSONDecoder().decode(EffectivePolicy.self, from: pinData) == pin)
        let fallback = EffectivePolicy(action: .block, provenance: .fallback)
        let fallbackData = try JSONEncoder().encode(fallback)
        #expect(try JSONDecoder().decode(EffectivePolicy.self, from: fallbackData) == fallback)
        // Wire shape preserved: absent provenance keys stay omitted (not null).
        let fallbackText = try #require(String(data: fallbackData, encoding: .utf8))
        #expect(fallbackText.contains("matchedPolicyId") == false)
        #expect(fallbackText.contains("owner") == false)
        let pinText = try #require(String(data: pinData, encoding: .utf8))
        #expect(pinText.contains("matchedPolicyId"))
        #expect(pinText.contains("owner") == false)
    }

    @Test func effectivePolicyDecodeRejectsOwnerWithoutId() throws {
        // The impossible combo is inexpressible in the enum, but the wire
        // can still carry it: decoding fails closed instead of guessing.
        let line = #"{"action":"approve","owner":"org"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EffectivePolicy.self, from: Data(line.utf8))
        }
    }

    @Test func staticPinCodableRoundTrips() throws {
        let pin = StaticFqidPin(address: try address("tools.a.b.c.d.e"), action: .approve)
        let data = try JSONEncoder().encode(pin)
        #expect(try JSONDecoder().decode(StaticFqidPin.self, from: data) == pin)
    }

    @Test func registryLookupHitReturnsRecord() throws {
        let target = try address("tools.github.acme.main.read")
        let record = MCPHandlerRecord(address: target, isStaticFqid: true, pluginDefault: .requireApproval)
        let registry = MCPRegistry(handlers: [record])
        #expect(registry.handler(for: target) == record)
        #expect(registry.count == 1)
    }

    @Test func registryLookupMissReturnsNil() throws {
        let registry = MCPRegistry(handlers: [
            MCPHandlerRecord(
                address: try address("tools.github.acme.main.read"),
                isStaticFqid: false,
                pluginDefault: .approve
            ),
        ])
        #expect(registry.handler(for: try address("tools.github.acme.main.write")) == nil)
        #expect(registry.handler(for: try address("tools.gitlab.acme.main.read")) == nil)
    }

    @Test func emptyRegistryHasZeroCount() throws {
        let registry = MCPRegistry()
        #expect(registry.count == 0)
        #expect(registry.handler(for: try address("tools.a.b.c.d")) == nil)
    }

    @Test func registryDuplicateAddressLastWins() throws {
        let target = try address("tools.github.acme.main.read")
        let registry = MCPRegistry(handlers: [
            MCPHandlerRecord(address: target, isStaticFqid: false, pluginDefault: .approve),
            MCPHandlerRecord(address: target, isStaticFqid: true, pluginDefault: .block),
        ])
        #expect(registry.count == 1)
        let record = try #require(registry.handler(for: target))
        #expect(record.isStaticFqid)
        #expect(record.pluginDefault == .block)
    }

    @Test func registryPreservesFlagAndDefaultPerRecord() throws {
        let first = try address("tools.github.acme.main.read")
        let second = try address("tools.github.acme.main.write")
        let registry = MCPRegistry(handlers: [
            MCPHandlerRecord(address: first, isStaticFqid: true, pluginDefault: .approve),
            MCPHandlerRecord(address: second, isStaticFqid: false, pluginDefault: .block),
        ])
        #expect(registry.count == 2)
        #expect(registry.handler(for: first)?.isStaticFqid == true)
        #expect(registry.handler(for: first)?.pluginDefault == .approve)
        #expect(registry.handler(for: second)?.isStaticFqid == false)
        #expect(registry.handler(for: second)?.pluginDefault == .block)
    }

    @Test func registryDottedToolLookupMatchesAcrossConstructions() throws {
        let parsed = try address("tools.github.acme.main.my.tool.v2")
        let built = try MCPToolAddress(
            integration: "github", owner: "acme", connection: "main", tool: "my.tool.v2"
        )
        #expect(parsed == built)
        let registry = MCPRegistry(handlers: [
            MCPHandlerRecord(address: parsed, isStaticFqid: false, pluginDefault: .approve),
        ])
        #expect(registry.handler(for: built)?.address == parsed)
    }

    @Test func registryUnicodeLookup() throws {
        let target = try address("tools.héllo.世界.🔌.outil")
        let registry = MCPRegistry(handlers: [
            MCPHandlerRecord(address: target, isStaticFqid: false, pluginDefault: .requireApproval),
        ])
        #expect(registry.handler(for: target)?.pluginDefault == .requireApproval)
        #expect(registry.handler(for: try address("tools.héllo.世界.🔌.autre")) == nil)
    }

    @Test func registryStressManyHandlers() throws {
        var handlers: [MCPHandlerRecord] = []
        for index in 0..<1000 {
            handlers.append(
                MCPHandlerRecord(
                    address: try address("tools.svc.acme.c\(index).tool"),
                    isStaticFqid: index % 2 == 0,
                    pluginDefault: .approve
                )
            )
        }
        let registry = MCPRegistry(handlers: handlers)
        #expect(registry.count == 1000)
        for index in [0, 1, 499, 500, 999] {
            let record = try #require(
                registry.handler(for: try address("tools.svc.acme.c\(index).tool"))
            )
            #expect(record.isStaticFqid == (index % 2 == 0))
        }
        #expect(registry.handler(for: try address("tools.svc.acme.c1000.tool")) == nil)
    }

    @Test func registryDistinctSiblingsDoNotCollide() throws {
        let read = try address("tools.github.acme.main.read")
        let readme = try address("tools.github.acme.main.readme")
        let registry = MCPRegistry(handlers: [
            MCPHandlerRecord(address: read, isStaticFqid: false, pluginDefault: .approve),
        ])
        #expect(registry.handler(for: read) != nil)
        #expect(registry.handler(for: readme) == nil)
    }

    @Test func handlerRecordCodableRoundTrips() throws {
        let record = MCPHandlerRecord(
            address: try address("tools.a.b.c.d.e"),
            isStaticFqid: true,
            pluginDefault: .requireApproval
        )
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(MCPHandlerRecord.self, from: data) == record)
    }
}
