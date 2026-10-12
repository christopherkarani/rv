import Foundation
import RVDomain
import Testing
@testable import RVIsolation

// MARK: - Test helpers (unsynchronized boxes are test-only)

/// Plain box for values an injected closure must capture. Test-only.
private final class TestBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Lock-guarded box for values touched from concurrent refresh tasks. Test-only.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// One-shot gate a refresh closure can block on. Test-only.
private final class RefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitForOpen() async {
        let already = { () -> Bool in
            lock.lock()
            defer { lock.unlock() }
            return opened
        }()
        if already {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending {
            waiter.resume()
        }
    }
}

@Suite("MCPRegistry")
struct MCPRegistryTests: Sendable {
    // MARK: - Fixtures

    private func address(_ literal: String) throws -> MCPToolAddress {
        try MCPToolAddress.parse(literal)
    }

    private func record(
        _ literal: String,
        description: String? = nil,
        inputSchemaJSON: String? = nil,
        outputSchemaJSON: String? = nil,
        annotations: MCPToolAnnotations? = nil,
        isStaticFqid: Bool = false,
        pluginDefault: PolicyAction = .approve
    ) throws -> MCPHandlerRecord {
        MCPHandlerRecord(
            address: try address(literal),
            isStaticFqid: isStaticFqid,
            pluginDefault: pluginDefault,
            description: description,
            inputSchemaJSON: inputSchemaJSON,
            outputSchemaJSON: outputSchemaJSON,
            annotations: annotations
        )
    }

    private var repoInputJSON: String {
        #"{"type":"object","properties":{"owner":{"type":"string"},"repo":{"type":"string"}},"required":["owner","repo"]}"#
    }

    private var repoDetailsOutputJSON: String {
        #"{"type":"object","properties":{"defaultBranch":{"type":"string"}},"required":["defaultBranch"]}"#
    }

    private var contactInputJSON: String {
        #"{"type":"object","properties":{"email":{"type":"string"}},"required":["email"]}"#
    }

    private var emptyInputJSON: String {
        #"{"type":"object","properties":{}}"#
    }

    /// Discovery fixture mirroring the Executor `tool-invoker.test.ts` search
    /// harness (github 3 tools, crm 2 + one cross-owner tool, google/
    /// google_gmail prefix siblings) plus ranking edge tools (tied pings,
    /// undescribed/empty-described/empty-annotated tools, six probe tools for
    /// the suggestion cap). 20 tools total.
    private func discoveryRegistry() throws -> MCPRegistry {
        var tools: [MCPHandlerRecord] = [
            try record(
                "tools.github.org.main.listRepositoryIssues",
                description: "List issues for a repository",
                inputSchemaJSON: repoInputJSON
            ),
            try record(
                "tools.github.org.main.getRepositoryDetails",
                description: "Get repository details including the default branch",
                inputSchemaJSON: repoInputJSON,
                outputSchemaJSON: repoDetailsOutputJSON
            ),
            try record(
                "tools.github.org.main.searchDocs",
                description: "Search GitHub API documentation",
                inputSchemaJSON: emptyInputJSON
            ),
            try record(
                "tools.crm.org.main.createContact",
                description: "Create a CRM contact record",
                inputSchemaJSON: contactInputJSON,
                annotations: MCPToolAnnotations(
                    requiresApproval: true,
                    approvalDescription: "Creates a contact record in the CRM",
                    mayElicit: false
                )
            ),
            try record(
                "tools.crm.org.main.listContacts",
                description: "List CRM contacts",
                inputSchemaJSON: emptyInputJSON
            ),
            try record(
                "tools.crm.user.side.listContacts",
                description: "List side contacts",
                inputSchemaJSON: emptyInputJSON
            ),
            try record("tools.google.org.main.ping", description: "Ping"),
            try record(
                "tools.google_gmail.org.main.listMessages", description: "List messages"
            ),
            try record(
                "tools.google_gmail.org.main.sendMessage", description: "Send a message"
            ),
            try record("tools.ops.org.main.ping", description: "Main ping"),
            try record("tools.ops.org.backup.ping", description: "Backup ping"),
            try record(
                "tools.misc.org.main.mystery", description: nil, inputSchemaJSON: emptyInputJSON
            ),
            try record("tools.misc.org.main.blank", description: ""),
            try record(
                "tools.misc.org.main.plain",
                description: "Plain tool",
                annotations: MCPToolAnnotations()
            ),
        ]
        for index in 0..<6 {
            tools.append(
                try record(
                    "tools.si.org.main.probe\(index)", description: "Probe tool \(index)"
                )
            )
        }
        return MCPRegistry(handlers: tools)
    }

    private func syncHarness(
        clock: TestBox<Double>,
        warnings: LockedBox<[String]> = LockedBox([]),
        config: MCPCatalogSyncConfig = MCPCatalogSyncConfig()
    ) -> MCPCatalogSync {
        MCPCatalogSync(
            config: config,
            now: { clock.value },
            onWarning: { message in warnings.withLock { $0.append(message) } }
        )
    }

    private func waitFor(
        _ label: String,
        timeoutSeconds: Double = 3,
        _ check: () -> Bool
    ) async throws {
        let deadline = Date().timeIntervalSince1970 + timeoutSeconds
        while Date().timeIntervalSince1970 < deadline {
            if check() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(check(), "timed out waiting for \(label)")
    }

    // MARK: - Search ranking

    /// Oracle: tool-invoker.test.ts "ranks matches using ids, namespaces,
    /// camelCase names, and descriptions".
    @Test func ranksMatchesUsingIdsNamespacesCamelCaseAndDescriptions() throws {
        let registry = try discoveryRegistry()

        let githubMatches = registry.search(query: "github issues", limit: 5)
        #expect(githubMatches.items.map { $0.path } == ["github.org.main.listRepositoryIssues"])
        #expect((githubMatches.items.first?.score ?? 0) > 0)
        #expect(githubMatches.hasMore == false)
        #expect(githubMatches.nextOffset == nil)

        let repoMatches = registry.search(query: "repo details", limit: 5)
        #expect(repoMatches.items.first?.path == "github.org.main.getRepositoryDetails")

        let crmMatches = registry.search(query: "crm create contact", limit: 5)
        #expect(crmMatches.items.first?.path == "crm.org.main.createContact")
        #expect((crmMatches.items.first?.score ?? 0) > (crmMatches.items.dropFirst().first?.score ?? 0))
    }

    /// Oracle: tool-invoker.test.ts "returns no matches for empty queries
    /// instead of listing arbitrary tools".
    @Test func emptyQueryWithoutNamespaceReturnsEmpty() throws {
        let registry = try discoveryRegistry()
        let matches = registry.search(query: "", limit: 5)
        #expect(matches.items == [])
        #expect(matches.total == 0)
        #expect(matches.hasMore == false)
        #expect(matches.nextOffset == nil)
    }

    @Test func blankQueryWithoutNamespaceReturnsEmpty() throws {
        let registry = try discoveryRegistry()
        let matches = registry.search(query: "   ", limit: 5)
        #expect(matches.items == [])
        #expect(matches.total == 0)
    }

    /// Oracle: tool-invoker.test.ts "enumerates a namespace's full catalog for
    /// an empty query with a namespace".
    @Test func enumeratesNamespaceCatalogForEmptyQueryWithNamespace() throws {
        let registry = try discoveryRegistry()
        let enumerated = registry.search(query: "", namespace: "github", limit: 100)
        #expect(enumerated.items.isEmpty == false)
        #expect(enumerated.total == enumerated.items.count)
        #expect(enumerated.items.map { $0.path } == enumerated.items.map { $0.path }.sorted())
        #expect(enumerated.items.allSatisfy { $0.integration == "github" })
        #expect(enumerated.items.allSatisfy { $0.score == 0 })

        let integrations = registry.listIntegrations(limit: 50)
        let github = integrations.items.first { $0.id == "github" }
        #expect(github?.toolCount == enumerated.total)

        let firstPage = registry.search(query: "", namespace: "github", limit: 1)
        #expect(firstPage.items == Array(enumerated.items.prefix(1)))
        #expect(firstPage.total == enumerated.total)
        #expect(firstPage.hasMore == (enumerated.total > 1))
    }

    /// Oracle: tool-invoker.test.ts "enumeration scopes by exact slug, not the
    /// prefix matching ranked search uses".
    @Test func enumerationScopesByExactSlug() throws {
        let registry = try discoveryRegistry()

        let parent = registry.search(query: "", namespace: "google", limit: 100)
        #expect(parent.items.map { $0.integration } == ["google"])
        #expect(parent.total == 1)

        let sibling = registry.search(query: "", namespace: "google_gmail", limit: 100)
        #expect(sibling.items.allSatisfy { $0.integration == "google_gmail" })
        #expect(sibling.total == 2)

        let fuzzy = registry.search(query: "message", namespace: "google", limit: 100)
        #expect(fuzzy.items.contains { $0.integration == "google_gmail" })
    }

    /// Oracle: tool-invoker.test.ts "paginates ranked matches via limit +
    /// offset with hasMore + nextOffset". Like the oracle, asserts the
    /// pagination invariants, not the exact match set.
    @Test func paginatesRankedMatches() throws {
        let registry = try discoveryRegistry()
        let all = registry.search(query: "list", limit: 100)
        #expect(all.items.count > 1)
        #expect(all.total == all.items.count)
        #expect(all.hasMore == false)
        #expect(all.nextOffset == nil)

        let firstPage = registry.search(query: "list", limit: 1)
        #expect(firstPage.items == Array(all.items.prefix(1)))
        #expect(firstPage.total == all.total)
        #expect(firstPage.hasMore == true)
        #expect(firstPage.nextOffset == 1)

        let secondPage = registry.search(
            query: "list", limit: 1, offset: firstPage.nextOffset ?? -1
        )
        #expect(secondPage.items == Array(all.items.dropFirst().prefix(1)))
        #expect(secondPage.total == all.total)
        #expect(secondPage.hasMore == (all.total > 2))
        #expect(secondPage.nextOffset == (secondPage.hasMore ? 2 : nil))

        let past = registry.search(query: "list", limit: 5, offset: all.total + 10)
        #expect(past.items == [])
        #expect(past.total == all.total)
        #expect(past.hasMore == false)
        #expect(past.nextOffset == nil)
    }

    /// Oracle: tool-invoker.test.ts "can narrow discovery to a namespace".
    @Test func narrowsDiscoveryToNamespace() throws {
        let registry = try discoveryRegistry()

        let githubOnly = registry.search(query: "list", namespace: "github", limit: 5)
        #expect(githubOnly.items.map { $0.path } == ["github.org.main.listRepositoryIssues"])

        let crmOnly = registry.search(query: "list", namespace: "crm", limit: 5)
        #expect(
            crmOnly.items.map { $0.path }
                == ["crm.org.main.listContacts", "crm.user.side.listContacts"]
        )
    }

    /// Negative offsets clamp to zero per Executor `paginate`; the "rejects
    /// negative offsets via the engine validator" oracle lives on the
    /// execution path, out of registry scope.
    @Test func negativeOffsetClampsToZero() throws {
        let registry = try discoveryRegistry()
        let clamped = registry.search(query: "list", limit: 2, offset: -5)
        let zero = registry.search(query: "list", limit: 2, offset: 0)
        #expect(clamped == zero)
    }

    /// Equal scores break by path ascending.
    @Test func scoreTieBreaksByPathAscending() throws {
        let registry = try discoveryRegistry()
        let matches = registry.search(query: "ping", limit: 10)
        #expect(
            matches.items.map { $0.path }
                == [
                    "google.org.main.ping",
                    "ops.org.backup.ping",
                    "ops.org.main.ping",
                ]
        )
        let backup = try #require(matches.items.dropFirst().first)
        let main = try #require(matches.items.dropFirst(2).first)
        #expect(backup.score == main.score)
    }

    @Test func exactFieldMatchOutranksSubstring() throws {
        let registry = try discoveryRegistry()
        let matches = registry.search(query: "crm", limit: 10)
        #expect(matches.items.count == 3)
        #expect(matches.items.allSatisfy { $0.integration == "crm" })
    }

    @Test func prefixMatchFindsIntegration() throws {
        let registry = try discoveryRegistry()
        let matches = registry.search(query: "git", limit: 10)
        #expect(matches.items.count == 3)
        #expect(matches.items.allSatisfy { $0.integration == "github" })
    }

    @Test func phraseMatchWithoutPrefixRanks() throws {
        let registry = try discoveryRegistry()
        let matches = registry.search(query: "issues for", limit: 5)
        #expect(matches.items.first?.path == "github.org.main.listRepositoryIssues")
    }

    @Test func tokenPrefixMatchesEitherDirection() throws {
        let registry = try discoveryRegistry()
        // Longer query token still prefix-matches the shorter field token.
        let matches = registry.search(query: "pingg", limit: 10)
        #expect(matches.items.count == 3)
        #expect(matches.items.allSatisfy { $0.name == "ping" })
    }

    @Test func rawSubstringFallbackMatches() throws {
        let registry = try discoveryRegistry()
        // "eposi" is a substring of "repository" with no token-prefix relation.
        let matches = registry.search(query: "eposi", limit: 10)
        #expect(
            Set(matches.items.map { $0.path })
                == [
                    "github.org.main.listRepositoryIssues",
                    "github.org.main.getRepositoryDetails",
                ]
        )
    }

    @Test func unmatchedQueryReturnsEmptyPage() throws {
        let registry = try discoveryRegistry()
        let matches = registry.search(query: "zzzqqq", limit: 5)
        #expect(matches.items == [])
        #expect(matches.total == 0)
        #expect(matches.hasMore == false)
        #expect(matches.nextOffset == nil)
    }

    @Test func nonAlphanumericQueryReturnsEmptyPage() throws {
        let registry = try discoveryRegistry()
        // Normalizes non-empty but tokenizes empty: ranked path, zero matches.
        let matches = registry.search(query: "é", limit: 5)
        #expect(matches.items == [])
        #expect(matches.total == 0)
    }

    @Test func lowCoverageQueryFiltersOut() throws {
        let registry = try discoveryRegistry()
        // One of three tokens matches: 1/3 < 0.6 minimum coverage.
        let matches = registry.search(query: "crm zebra wolf", limit: 5)
        #expect(matches.items == [])
    }

    @Test func partialCoverageAboveThresholdProceeds() throws {
        let registry = try discoveryRegistry()
        // Two of three tokens match: 2/3 >= 0.6 takes the partial bonus arm.
        let matches = registry.search(query: "crm create zebra", limit: 5)
        #expect(matches.items.map { $0.path } == ["crm.org.main.createContact"])
    }

    /// Executor parity: a repeated-token query (`"list list"`) dedupes the
    /// matched set while the query list keeps both tokens, so coverage sits
    /// at 0.5 — below the 1.0 minimum — and only the `!exactPhraseMatch`
    /// escape saves tools whose field contains the whole phrase.
    @Test func repeatedTokenQueryUsesPhraseEscape() throws {
        let registry = MCPRegistry(handlers: [
            try record("tools.svc.org.main.listList"),
            try record("tools.svc.org.main.listContacts"),
            try record("tools.svc.org.main.unrelated"),
        ])
        let matches = registry.search(query: "list list", limit: 10)
        #expect(matches.items.map { $0.path } == ["svc.org.main.listList"])
        #expect((matches.items.first?.score ?? 0) > 0)
    }

    /// Adversarial: a hostile description stuffed with the query — even paired
    /// with a hostile integration slug and tool name — must not outrank the
    /// exact name match.
    @Test func hostileDescriptionCannotOutrankExactNameMatch() throws {
        let registry = MCPRegistry(handlers: [
            try record(
                "tools.github.org.main.getRepositoryDetails",
                description: "Get repository details including the default branch"
            ),
            try record(
                "tools.evil.org.main.zzz",
                description: "get repository details get repository details"
            ),
            try record(
                "tools.get.org.main.get",
                description: "get repository details"
            ),
        ])
        for query in ["getRepositoryDetails", "get repository details"] {
            let matches = registry.search(query: query, limit: 10)
            #expect(
                matches.items.first?.path == "github.org.main.getRepositoryDetails",
                "query spelling: \(query)"
            )
        }
    }

    @Test func wholePathExactBonusApplies() throws {
        let registry = try discoveryRegistry()
        let matches = registry.search(query: "crm org main list contacts", limit: 5)
        #expect(matches.items.first?.path == "crm.org.main.listContacts")
    }

    @Test func camelCaseNameTokenizes() throws {
        let registry = try discoveryRegistry()
        let matches = registry.search(query: "issues", limit: 5)
        #expect(matches.items.first?.path == "github.org.main.listRepositoryIssues")
    }

    @Test func separatorSpellingsNormalizeEqually() throws {
        let registry = try discoveryRegistry()
        let expected = registry.search(query: "repo details", limit: 5)
        #expect(expected.items.first?.path == "github.org.main.getRepositoryDetails")
        for query in ["repo_details", "repo/details", "repo:details", "repo-details", "repo.details", "repo  details"] {
            let actual = registry.search(query: query, limit: 5)
            #expect(actual == expected, "query spelling: \(query)")
        }
    }

    @Test func searchExcludesBlockedTools() throws {
        let registry = try discoveryRegistry()
        let matches = registry.search(query: "list", limit: 10) { $0.integration == "crm" }
        #expect(
            Set(matches.items.map { $0.path })
                == [
                    "github.org.main.listRepositoryIssues",
                    "google_gmail.org.main.listMessages",
                ]
        )
    }

    @Test func zeroAndNegativeLimitsYieldEmptyItemsWithFullTotal() throws {
        let registry = try discoveryRegistry()
        for limit in [0, -3] {
            let page = registry.search(query: "list", limit: limit)
            #expect(page.items == [], "limit \(limit)")
            #expect(page.total == 4, "limit \(limit)")
            #expect(page.hasMore == true, "limit \(limit)")
            #expect(page.nextOffset == 0, "limit \(limit)")
        }
    }

    @Test func maxLimitReturnsAllWithoutOverflow() throws {
        let registry = try discoveryRegistry()
        let page = registry.search(query: "list", limit: Int.max)
        #expect(page.items.count == 4)
        #expect(page.total == 4)
        #expect(page.hasMore == false)

        // A naive `start + limit` ordering survives offset 0 (start adds
        // nothing) but traps on overflow past it; the clamp-before-add form
        // must hold for nonzero offsets too.
        let shifted = registry.search(query: "list", limit: Int.max, offset: 2)
        #expect(shifted.items.count == 2)
        #expect(shifted.total == 4)
        #expect(shifted.hasMore == false)
        #expect(shifted.nextOffset == nil)
    }

    @Test func blankNamespaceBehavesAsAbsent() throws {
        let registry = try discoveryRegistry()
        let global = registry.search(query: "list", limit: 10)
        #expect(registry.search(query: "list", namespace: "  ", limit: 10) == global)
        let empty = registry.search(query: "", namespace: "  ", limit: 10)
        #expect(empty.items == [])
        #expect(empty.total == 0)
    }

    @Test func nonTokenizingNamespaceMatchesEverything() throws {
        let registry = try discoveryRegistry()
        let global = registry.search(query: "list", limit: 10)
        #expect(registry.search(query: "list", namespace: "é", limit: 10) == global)
    }

    @Test func namespaceMatchesPathTokensWhenIntegrationIsTooShort() throws {
        let registry = try discoveryRegistry()
        let matches = registry.search(query: "list", namespace: "github org", limit: 5)
        #expect(matches.items.map { $0.path } == ["github.org.main.listRepositoryIssues"])
    }

    @Test func unknownNamespaceMatchesNothing() throws {
        let registry = try discoveryRegistry()
        let matches = registry.search(query: "list", namespace: "zzz", limit: 5)
        #expect(matches.items == [])
        #expect(matches.total == 0)
    }

    @Test func emptyRegistrySearchesEmpty() throws {
        let registry = MCPRegistry()
        #expect(registry.search(query: "list", limit: 5).total == 0)
        #expect(registry.search(query: "", namespace: "github", limit: 5).total == 0)
        #expect(registry.list().isEmpty)
        #expect(registry.listIntegrations().total == 0)
    }

    // MARK: - Describe + suggestions

    /// Oracle: tool-invoker.test.ts "describes tools with TypeScript previews"
    /// (shape analog: opaque JSON instead of TS) + "describes a tool's
    /// declared annotations, and omits the key when it has none".
    @Test func describesToolShapesAndAnnotations() throws {
        let registry = try discoveryRegistry()
        let described = registry.describe(path: "crm.org.main.createContact")
        #expect(described.path == "crm.org.main.createContact")
        #expect(described.name == "createContact")
        #expect(described.description == "Create a CRM contact record")
        #expect(described.inputSchemaJSON == contactInputJSON)
        #expect(described.outputSchemaJSON == nil)
        #expect(
            described.annotations
                == MCPToolAnnotations(
                    requiresApproval: true,
                    approvalDescription: "Creates a contact record in the CRM",
                    mayElicit: false
                )
        )
        #expect(described.error == nil)
    }

    @Test func describeOmitsAnnotationsWhenNone() throws {
        let registry = try discoveryRegistry()
        let plain = registry.describe(path: "crm.org.main.listContacts")
        #expect(plain.annotations == nil)
        #expect(plain.error == nil)

        // An all-absent struct omits exactly like a missing one
        // (toolAnnotationsView empty -> undefined, executor.ts:1238).
        let empty = registry.describe(path: "misc.org.main.plain")
        #expect(empty.annotations == nil)
        #expect(empty.error == nil)
    }

    @Test func describeAcceptsPrefixedLiteral() throws {
        let registry = try discoveryRegistry()
        let described = registry.describe(path: "tools.crm.org.main.listContacts")
        #expect(described.path == "tools.crm.org.main.listContacts")
        #expect(described.name == "listContacts")
        #expect(described.error == nil)
    }

    /// Oracle: tool-invoker.test.ts "describe on an unknown path returns
    /// tool_not_found with suggestions" (scoped arm).
    @Test func describeUnknownLeafSuggestsScoped() throws {
        let registry = try discoveryRegistry()
        let described = registry.describe(path: "github.org.main.getRepoDetails")
        #expect(described.path == "github.org.main.getRepoDetails")
        #expect(described.name == "github.org.main.getRepoDetails")
        #expect(described.inputSchemaJSON == nil)
        #expect(described.description == nil)
        #expect(described.error?.code == "tool_not_found")
        #expect(described.error?.message == "Tool not found: github.org.main.getRepoDetails")
        #expect(described.error?.suggestions?.contains("github.org.main.getRepositoryDetails") == true)
    }

    /// Oracle: same ("Unknown namespace — falls back to a global search").
    @Test func describeUnknownNamespaceFallsBackToGlobal() throws {
        let registry = try discoveryRegistry()
        let described = registry.describe(path: "nosuch.org.main.getRepositoryDetails")
        #expect(described.error?.code == "tool_not_found")
        #expect(described.error?.suggestions?.contains("github.org.main.getRepositoryDetails") == true)
    }

    @Test func describeUnknownWithoutSuggestionsOmitsKey() throws {
        let registry = try discoveryRegistry()
        let described = registry.describe(path: "zzz.org.main.nothinghere")
        #expect(described.error?.code == "tool_not_found")
        #expect(described.error?.suggestions == nil)
    }

    @Test func describeMalformedPathsReturnNotFound() throws {
        let registry = try discoveryRegistry()
        for path in ["not a path!!", "tools.", ""] {
            let described = registry.describe(path: path)
            #expect(described.error?.code == "tool_not_found", "path: \(path)")
            #expect(described.path == path, "path: \(path)")
        }
    }

    @Test func describeBareNameSearchesLeafGlobally() throws {
        let registry = try discoveryRegistry()
        let described = registry.describe(path: "ping")
        #expect(described.error?.code == "tool_not_found")
        #expect(
            Set(described.error?.suggestions ?? [])
                == [
                    "google.org.main.ping",
                    "ops.org.main.ping",
                    "ops.org.backup.ping",
                ]
        )
    }

    @Test func describeTrailingDotEnumeratesNamespace() throws {
        let registry = try discoveryRegistry()
        // Empty leaf + real namespace takes the enumeration arm, faithfully.
        let described = registry.describe(path: "tools.github.org.main.")
        #expect(described.error?.code == "tool_not_found")
        #expect(
            described.error?.suggestions
                == [
                    "github.org.main.getRepositoryDetails",
                    "github.org.main.listRepositoryIssues",
                    "github.org.main.searchDocs",
                ]
        )
    }

    @Test func describeBlockedToolReadsAsNotFound() throws {
        let registry = try discoveryRegistry()
        let described = registry.describe(path: "github.org.main.searchDocs") {
            $0.integration == "github"
        }
        #expect(described.error?.code == "tool_not_found")
        #expect(described.error?.suggestions?.allSatisfy { !$0.hasPrefix("github.") } ?? true)
    }

    @Test func suggestionLimitCapsAndDisables() throws {
        let registry = try discoveryRegistry()
        let two = registry.suggestions(for: "x.org.main.ping", limit: 2)
        #expect(two.count == 2)

        #expect(registry.suggestions(for: "x.org.main.ping", limit: 0) == [])
        #expect(registry.suggestions(for: "x.org.main.ping", limit: -4) == [])

        // Six probe tools match one leaf; the default cap holds at five.
        let capped = registry.suggestions(for: "zzz.org.main.probe")
        #expect(capped.count == 5)

        let wide = registry.suggestions(for: "zzz.org.main.probe", limit: 100)
        #expect(wide.count == 6)
    }

    /// Authorization boundary: when every tool is blocked, no discovery
    /// surface — ranked, enumeration, list, integrations, describe, or
    /// suggestions — reveals anything.
    @Test func allBlockedToolsHideFromDiscovery() throws {
        let registry = try discoveryRegistry()
        let blocked: (MCPToolAddress) -> Bool = { _ in true }
        let ranked = registry.search(query: "list", limit: 10, isBlocked: blocked)
        #expect(ranked.items == [])
        #expect(ranked.total == 0)
        let enumerated = registry.search(query: "", namespace: "github", limit: 10, isBlocked: blocked)
        #expect(enumerated.items == [])
        #expect(enumerated.total == 0)
        #expect(registry.list(isBlocked: blocked) == [])
        #expect(registry.listIntegrations(isBlocked: blocked).total == 0)
        let described = registry.describe(
            path: "github.org.main.listRepositoryIssues", isBlocked: blocked
        )
        #expect(described.error?.code == "tool_not_found")
        #expect(described.error?.suggestions == nil)
        #expect(registry.suggestions(for: "github.org.main.listRepo", isBlocked: blocked) == [])
    }

    // MARK: - List

    /// Oracle: tool-row-projection.test.ts "tools.list returns metadata
    /// without loading the schema columns".
    @Test func listProjectsMetadataWithoutSchemas() throws {
        let registry = try discoveryRegistry()
        let rows = registry.list()
        #expect(rows.count == 20)
        #expect(rows.map { $0.address.literal } == rows.map { $0.address.literal }.sorted())
        #expect(rows.allSatisfy { $0.inputSchemaJSON == nil && $0.outputSchemaJSON == nil })
        let created = try #require(
            rows.first { $0.address.tool == "createContact" && $0.address.owner == "org" }
        )
        #expect(created.annotations?.requiresApproval == true)
        #expect(created.description == "Create a CRM contact record")
    }

    /// Oracle: tools-list-merge.test.ts "integration filter without owner
    /// merges both owners' tools".
    @Test func listFiltersMergeOwners() throws {
        let registry = try discoveryRegistry()
        #expect(registry.list(filter: MCPToolListFilter(integration: "crm")).count == 3)
        #expect(registry.list(filter: MCPToolListFilter(owner: "org")).count == 19)
        #expect(
            registry.list(filter: MCPToolListFilter(owner: "user")).map { $0.address.literal }
                == ["tools.crm.user.side.listContacts"]
        )
        #expect(registry.list(filter: MCPToolListFilter(connection: "main")).count == 18)
        #expect(
            registry.list(
                filter: MCPToolListFilter(integration: "ops", connection: "backup")
            ).map { $0.address.literal } == ["tools.ops.org.backup.ping"]
        )
    }

    @Test func listFiltersExclude() throws {
        let registry = try discoveryRegistry()
        #expect(registry.list(filter: MCPToolListFilter(integration: "zzz")).isEmpty)
        #expect(registry.list(filter: MCPToolListFilter(owner: "zzz")).isEmpty)
        #expect(registry.list(filter: MCPToolListFilter(connection: "zzz")).isEmpty)
    }

    @Test func listQueryMatchesNameOrDescriptionCaseInsensitively() throws {
        let registry = try discoveryRegistry()
        // "CRM" hits name/description text only: the side tool has neither.
        let crm = registry.list(filter: MCPToolListFilter(query: "CRM"))
        #expect(crm.count == 2)
        #expect(crm.allSatisfy { $0.address.owner == "org" })

        let docs = registry.list(filter: MCPToolListFilter(query: "documentation"))
        #expect(docs.map { $0.address.literal } == ["tools.github.org.main.searchDocs"])

        // Undescribed tools still match by tool name.
        let mystery = registry.list(filter: MCPToolListFilter(query: "mystery"))
        #expect(mystery.map { $0.address.literal } == ["tools.misc.org.main.mystery"])

        #expect(registry.list(filter: MCPToolListFilter(query: "zzz-nope")).isEmpty)
    }

    @Test func listWithoutAnnotationsStripsThem() throws {
        let registry = try discoveryRegistry()
        let rows = registry.list(filter: MCPToolListFilter(includeAnnotations: false))
        #expect(rows.count == 20)
        #expect(rows.allSatisfy { $0.annotations == nil })
        #expect(rows.contains { $0.description != nil })
    }

    /// Oracle: policies.test.ts "a blocked tool is omitted from tools.list" /
    /// "includeBlocked surfaces blocked tools".
    @Test func listBlockedVisibility() throws {
        let registry = try discoveryRegistry()
        let blocked: (MCPToolAddress) -> Bool = { $0.integration == "crm" }
        #expect(registry.list(isBlocked: blocked).count == 17)
        let surfaced = registry.list(
            filter: MCPToolListFilter(includeBlocked: true), isBlocked: blocked
        )
        #expect(surfaced.count == 20)
    }

    // MARK: - Integrations

    /// Oracle: tool-invoker.test.ts "supports executor-scoped integration
    /// listing and tool search" (census half).
    @Test func listIntegrationsCountsAndSorts() throws {
        let registry = try discoveryRegistry()
        let page = registry.listIntegrations(limit: 50)
        #expect(page.total == 7)
        #expect(
            page.items.map { ($0.id, $0.toolCount) }.map { "\($0)=\($1)" }
                == [
                    "crm=3",
                    "github=3",
                    "google=1",
                    "google_gmail=2",
                    "misc=3",
                    "ops=2",
                    "si=6",
                ]
        )
        let github = try #require(page.items.first { $0.id == "github" })
        #expect(github.name == "github")
        let enumerated = registry.search(query: "", namespace: "github", limit: 100)
        #expect(github.toolCount == enumerated.total)
    }

    @Test func listIntegrationsQueryFilters() throws {
        let registry = try discoveryRegistry()
        #expect(registry.listIntegrations(query: "git").items.map { $0.id } == ["github"])
        #expect(registry.listIntegrations(query: "mail").items.map { $0.id } == ["google_gmail"])
        #expect(registry.listIntegrations(query: "  ").total == 7)
        #expect(registry.listIntegrations(query: "é").total == 7)
        #expect(registry.listIntegrations(query: "zzz").items.isEmpty)
    }

    /// Oracle: tool-invoker.test.ts "paginates integration listings via limit
    /// + offset".
    @Test func listIntegrationsPaginates() throws {
        let registry = try discoveryRegistry()
        let first = registry.listIntegrations(limit: 2)
        #expect(first.items.map { $0.id } == ["crm", "github"])
        #expect(first.total == 7)
        #expect(first.hasMore == true)
        #expect(first.nextOffset == 2)

        let last = registry.listIntegrations(limit: 2, offset: 6)
        #expect(last.items.map { $0.id } == ["si"])
        #expect(last.total == 7)
        #expect(last.hasMore == false)
        #expect(last.nextOffset == nil)
    }

    @Test func listIntegrationsExcludesBlocked() throws {
        let registry = try discoveryRegistry()
        let page = registry.listIntegrations { $0.integration == "crm" }
        #expect(page.total == 6)
        #expect(page.items.allSatisfy { $0.id != "crm" })
    }

    // MARK: - Record compatibility

    @Test func handlerRecordLegacyJSONDecodes() throws {
        let legacy = #"{"address":"tools.a.b.c.d","isStaticFqid":false,"pluginDefault":"approve"}"#
        let record = try JSONDecoder().decode(MCPHandlerRecord.self, from: Data(legacy.utf8))
        #expect(record.address == MCPHandlerRecord(
            address: try address("tools.a.b.c.d"),
            isStaticFqid: false,
            pluginDefault: .approve
        ).address)
        #expect(record.description == nil)
        #expect(record.inputSchemaJSON == nil)
        #expect(record.outputSchemaJSON == nil)
        #expect(record.annotations == nil)
    }

    @Test func duplicateAddressLastRecordWinsWholesale() throws {
        let target = try address("tools.github.org.main.read")
        let registry = MCPRegistry(handlers: [
            MCPHandlerRecord(
                address: target, isStaticFqid: false, pluginDefault: .approve,
                description: "first"
            ),
            MCPHandlerRecord(
                address: target, isStaticFqid: true, pluginDefault: .block,
                description: "last"
            ),
        ])
        #expect(registry.count == 1)
        let record = try #require(registry.handler(for: target))
        #expect(record.description == "last")
        #expect(record.isStaticFqid)
        #expect(record.pluginDefault == .block)
    }

    @Test func handlerRecordRoundTripsDiscoveryFields() throws {
        let record = try record(
            "tools.a.b.c.d",
            description: "D",
            inputSchemaJSON: #"{"type":"object"}"#,
            outputSchemaJSON: #"{"type":"string"}"#,
            annotations: MCPToolAnnotations(requiresApproval: true),
            isStaticFqid: true,
            pluginDefault: .requireApproval
        )
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(MCPHandlerRecord.self, from: data) == record)
    }

    @Test func discoveryShapesRoundTripCodable() throws {
        let match = MCPToolMatch(
            path: "a.b.c.d", name: "d", description: "D", integration: "a", score: 7
        )
        #expect(
            try JSONDecoder().decode(MCPToolMatch.self, from: JSONEncoder().encode(match)) == match
        )
        let page = MCPPage(items: [match], total: 1, hasMore: false, nextOffset: nil)
        #expect(
            try JSONDecoder().decode(MCPPage<MCPToolMatch>.self, from: JSONEncoder().encode(page))
                == page
        )
        let described = MCPDescribedTool(
            path: "p",
            name: "n",
            annotations: MCPToolAnnotations(mayElicit: true),
            error: MCPDescribeError(code: "tool_not_found", message: "m", suggestions: ["s"])
        )
        #expect(
            try JSONDecoder().decode(MCPDescribedTool.self, from: JSONEncoder().encode(described))
                == described
        )
        let filter = MCPToolListFilter(integration: "i", query: "q", includeBlocked: true)
        #expect(
            try JSONDecoder().decode(MCPToolListFilter.self, from: JSONEncoder().encode(filter))
                == filter
        )
        let item = MCPIntegrationItem(id: "i", name: "n", toolCount: 3)
        #expect(
            try JSONDecoder().decode(MCPIntegrationItem.self, from: JSONEncoder().encode(item))
                == item
        )
        let key = MCPConnectionKey(integration: "i", owner: "o", connection: "c")
        #expect(
            try JSONDecoder().decode(MCPConnectionKey.self, from: JSONEncoder().encode(key)) == key
        )
        #expect(key.literal == "i.o.c")
        let stamp = MCPCatalogStamp(syncedAt: 1, remoteCatalog: true)
        #expect(
            try JSONDecoder().decode(MCPCatalogStamp.self, from: JSONEncoder().encode(stamp))
                == stamp
        )
        let config = MCPCatalogSyncConfig(
            syncTTLSeconds: nil, graceSeconds: 1, maxConcurrentRefreshes: 2
        )
        #expect(
            try JSONDecoder().decode(MCPCatalogSyncConfig.self, from: JSONEncoder().encode(config))
                == config
        )
    }

    // MARK: - Catalog sync

    private func syncKey(_ integration: String, _ owner: String, _ connection: String) -> MCPConnectionKey {
        MCPConnectionKey(integration: integration, owner: owner, connection: connection)
    }

    private func syncTools(_ literals: [String]) throws -> [MCPHandlerRecord] {
        try literals.map { try record($0, description: "tool \($0)") }
    }

    /// Oracle: catalog-sync.test.ts "a fresh catalog inside the TTL is served
    /// from the persisted rows".
    @Test func freshCatalogServedFromPersistedRows() async throws {
        let clock = TestBox(1000.0)
        let calls = LockedBox(0)
        let sync = syncHarness(clock: clock)
        let key = syncKey("github", "org", "main")
        await sync.seed(
            tools: try syncTools(["tools.github.org.main.read"]),
            stamps: [key: MCPCatalogStamp(syncedAt: 1000, remoteCatalog: true)]
        )
        let snapshot = await sync.read { _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        #expect(snapshot.count == 1)
        #expect(calls.withLock { $0 } == 0)
    }

    /// Oracle: catalog-sync.test.ts "expired catalogs re-list in the
    /// background once older than the freshness TTL" + connections.test.ts "a
    /// time-expired catalog answers from persisted rows and rebuilds in the
    /// background" + catalog-sync.test.ts "a read outlasting the grace serves
    /// the stored catalog, then converges".
    @Test func expiredCatalogRebuildsInBackgroundThenConverges() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(
            clock: clock, config: MCPCatalogSyncConfig(graceSeconds: 0.05)
        )
        let staleKey = syncKey("mcp", "org", "srv")
        let freshKey = syncKey("local", "org", "main")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old", "tools.local.org.main.keep"]),
            stamps: [
                staleKey: MCPCatalogStamp(syncedAt: 0, remoteCatalog: true),
                freshKey: MCPCatalogStamp(syncedAt: 1000, remoteCatalog: false),
            ]
        )
        let calls = LockedBox(0)
        let seen = LockedBox<[MCPConnectionKey]>([])
        let fresh = try syncTools(["tools.mcp.org.srv.new"])
        let first = await sync.read { key -> [MCPHandlerRecord]? in
            calls.withLock { $0 += 1 }
            seen.withLock { $0.append(key) }
            return fresh
        }
        try await waitFor("deferred launch") { calls.withLock { $0 } == 1 }
        #expect(seen.withLock { $0 } == [staleKey])
        // Deferred by definition: the read serves persisted rows at once.
        #expect(first.handler(for: try address("tools.mcp.org.srv.old")) != nil)
        #expect(first.handler(for: try address("tools.mcp.org.srv.new")) == nil)
        #expect(first.handler(for: try address("tools.local.org.main.keep")) != nil)

        await sync.settle()
        let second = await sync.snapshot()
        #expect(second.handler(for: try address("tools.mcp.org.srv.old")) == nil)
        #expect(second.handler(for: try address("tools.mcp.org.srv.new")) != nil)
        #expect(second.handler(for: try address("tools.local.org.main.keep")) != nil)

        // Fresh now: the next read triggers nothing.
        _ = await sync.read { _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        #expect(calls.withLock { $0 } == 1)
    }

    /// Oracle: connections.test.ts "a stale-marked catalog still gates the
    /// read within the grace budget".
    @Test func staleMarkedCatalogGatesRead() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        let key = syncKey("mcp", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old"]),
            stamps: [key: MCPCatalogStamp(syncedAt: nil, remoteCatalog: true)]
        )
        let snapshot = await sync.read { _ in try? syncTools(["tools.mcp.org.srv.new"]) }
        #expect(snapshot.handler(for: try address("tools.mcp.org.srv.new")) != nil)
        #expect(snapshot.handler(for: try address("tools.mcp.org.srv.old")) == nil)
    }

    @Test func staleMarkedSlowRefreshServesStaleThenConverges() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(
            clock: clock, config: MCPCatalogSyncConfig(graceSeconds: 0.05)
        )
        let key = syncKey("mcp", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old"]),
            stamps: [key: MCPCatalogStamp(syncedAt: nil, remoteCatalog: false)]
        )
        let gate = RefreshGate()
        let read = await sync.read { _ -> [MCPHandlerRecord]? in
            await gate.waitForOpen()
            return try? syncTools(["tools.mcp.org.srv.new"])
        }
        #expect(read.handler(for: try address("tools.mcp.org.srv.old")) != nil)

        let settled = LockedBox(false)
        let drain = Task {
            await sync.settle()
            settled.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(settled.withLock { $0 } == false)
        gate.open()
        await drain.value
        let converged = await sync.snapshot()
        #expect(converged.handler(for: try address("tools.mcp.org.srv.new")) != nil)
    }

    /// Oracle: strict mode — nil grace blocks until every rebuild finishes
    /// (executor.ts `toolsSyncGraceMs` null arm).
    @Test func convergeModeBlocksUntilDone() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock, config: MCPCatalogSyncConfig(graceSeconds: nil))
        let key = syncKey("mcp", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old"]),
            stamps: [key: MCPCatalogStamp(syncedAt: nil, remoteCatalog: false)]
        )
        let gate = RefreshGate()
        let done = LockedBox(false)
        let reader = Task {
            let snapshot = await sync.read { _ -> [MCPHandlerRecord]? in
                await gate.waitForOpen()
                return try? syncTools(["tools.mcp.org.srv.new"])
            }
            done.withLock { $0 = true }
            return snapshot
        }
        // Well past the default grace: still waiting.
        try await Task.sleep(for: .milliseconds(50))
        #expect(done.withLock { $0 } == false)
        gate.open()
        let snapshot = await reader.value
        #expect(snapshot.handler(for: try address("tools.mcp.org.srv.new")) != nil)
    }

    @Test func convergeModeWaitsForExpiredCatalogsToo() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock, config: MCPCatalogSyncConfig(graceSeconds: nil))
        let key = syncKey("mcp", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old"]),
            stamps: [key: MCPCatalogStamp(syncedAt: 0, remoteCatalog: true)]
        )
        let gate = RefreshGate()
        let done = LockedBox(false)
        let reader = Task {
            let snapshot = await sync.read { _ -> [MCPHandlerRecord]? in
                await gate.waitForOpen()
                return try? syncTools(["tools.mcp.org.srv.new"])
            }
            done.withLock { $0 = true }
            return snapshot
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(done.withLock { $0 } == false)
        gate.open()
        let snapshot = await reader.value
        #expect(snapshot.handler(for: try address("tools.mcp.org.srv.new")) != nil)
    }

    /// Oracle: nil TTL disables time-based re-sync, while stale-mark still
    /// applies (executor.ts `toolsSyncTtlMs` null arm).
    @Test func nilTTLDisablesExpiryButNotStaleMark() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock, config: MCPCatalogSyncConfig(syncTTLSeconds: nil))
        let key = syncKey("mcp", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old"]),
            stamps: [key: MCPCatalogStamp(syncedAt: 0, remoteCatalog: true)]
        )
        let calls = LockedBox(0)
        _ = await sync.read { _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        #expect(calls.withLock { $0 } == 0)

        await sync.markStale(key)
        _ = await sync.read { _ in
            calls.withLock { $0 += 1 }
            return try? syncTools(["tools.mcp.org.srv.new"])
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func ttlIgnoredWithoutAnyRemoteCatalog() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        let key = syncKey("local", "org", "main")
        await sync.seed(
            tools: try syncTools(["tools.local.org.main.keep"]),
            stamps: [key: MCPCatalogStamp(syncedAt: 0, remoteCatalog: false)]
        )
        let calls = LockedBox(0)
        let snapshot = await sync.read { _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(snapshot.count == 1)
    }

    /// Clock skew: when the clock jumps backward past the stamp, a remote
    /// catalog reads fresh (never expired) instead of re-listing.
    @Test func backwardClockSkewNeverExpires() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        let key = syncKey("mcp", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.tool"]),
            stamps: [key: MCPCatalogStamp(syncedAt: 1000, remoteCatalog: true)]
        )
        clock.value = 500.0
        let calls = LockedBox(0)
        let snapshot = await sync.read { _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(snapshot.count == 1)
    }

    /// Oracle: the config-revised trigger (executor.ts syncStaleConnectionTools
    /// "config-revised" arm) is urgent: the read waits for it.
    @Test func configRevisionTriggersUrgentRefresh() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        let key = syncKey("open", "org", "api")
        await sync.seed(
            tools: try syncTools(["tools.open.org.api.old"]),
            stamps: [key: MCPCatalogStamp(syncedAt: 1000, remoteCatalog: false)]
        )
        await sync.noteConfigRevision(integration: "open", revision: 2000)
        let snapshot = await sync.read { _ in try? syncTools(["tools.open.org.api.new"]) }
        #expect(snapshot.handler(for: try address("tools.open.org.api.new")) != nil)
    }

    @Test func oldConfigRevisionDoesNotTrigger() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        let key = syncKey("open", "org", "api")
        await sync.seed(
            tools: try syncTools(["tools.open.org.api.keep"]),
            stamps: [key: MCPCatalogStamp(syncedAt: 1000, remoteCatalog: false)]
        )
        await sync.noteConfigRevision(integration: "open", revision: 500)
        let calls = LockedBox(0)
        _ = await sync.read { _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        #expect(calls.withLock { $0 } == 0)
    }

    /// Oracle: connections.test.ts "a failed stale rebuild warns and neither
    /// fails nor blocks the read".
    @Test func failedRefreshWarnsKeepsStaleAndRetries() async throws {
        let clock = TestBox(1000.0)
        let warnings = LockedBox<[String]>([])
        let sync = syncHarness(clock: clock, warnings: warnings)
        let key = syncKey("mcp", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old"]),
            stamps: [key: MCPCatalogStamp(syncedAt: nil, remoteCatalog: false)]
        )
        let calls = LockedBox(0)
        let first = await sync.read { _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        #expect(first.handler(for: try address("tools.mcp.org.srv.old")) != nil)
        #expect(warnings.withLock { $0 }.count == 1)
        #expect(warnings.withLock { $0 }.first?.contains("mcp.org.srv") == true)

        // The stamp never advanced, so the next read retries.
        _ = await sync.read { _ in
            calls.withLock { $0 += 1 }
            return try? syncTools(["tools.mcp.org.srv.new"])
        }
        #expect(calls.withLock { $0 } == 2)
        let converged = await sync.snapshot()
        #expect(converged.handler(for: try address("tools.mcp.org.srv.new")) != nil)
    }

    @Test func defaultClockAndWarningSinkSmoke() async throws {
        let sync = MCPCatalogSync()
        let key = syncKey("mcp", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old"]),
            stamps: [key: MCPCatalogStamp(syncedAt: nil, remoteCatalog: false)]
        )
        // Stale-marked regardless of the wall clock; the silent sink drops
        // the failure warning and stale rows serve.
        let snapshot = await sync.read { _ in nil }
        #expect(snapshot.handler(for: try address("tools.mcp.org.srv.old")) != nil)
    }

    /// Oracle: connections.test.ts "single-flights concurrent refreshes of
    /// the same stale connection".
    @Test func concurrentReadsSingleFlightOneRefresh() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        let key = syncKey("mcp", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old"]),
            stamps: [key: MCPCatalogStamp(syncedAt: nil, remoteCatalog: false)]
        )
        let gate = RefreshGate()
        let calls = LockedBox(0)
        let fresh = try syncTools(["tools.mcp.org.srv.new"])
        let refresh: @Sendable (MCPConnectionKey) async -> [MCPHandlerRecord]? = { _ in
            calls.withLock { $0 += 1 }
            await gate.waitForOpen()
            return fresh
        }
        async let first = sync.read(refresh: refresh)
        async let second = sync.read(refresh: refresh)
        try await waitFor("first refresh launch") { calls.withLock { $0 } == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(calls.withLock { $0 } == 1)
        gate.open()
        let snapshots = await [first, second]
        let target = try address("tools.mcp.org.srv.new")
        #expect(snapshots.allSatisfy { $0.handler(for: target) != nil })
        #expect(calls.withLock { $0 } == 1)
    }

    /// Oracle: catalog-sync.test.ts "rebuilds stale connections concurrently
    /// up to the bound, then queues the rest".
    @Test func refreshesBoundConcurrencyAndQueue() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(
            clock: clock,
            config: MCPCatalogSyncConfig(graceSeconds: nil, maxConcurrentRefreshes: 1)
        )
        let keyA = syncKey("a", "org", "main")
        let keyB = syncKey("b", "org", "main")
        await sync.seed(
            tools: try syncTools(["tools.a.org.main.old", "tools.b.org.main.old"]),
            stamps: [
                keyA: MCPCatalogStamp(syncedAt: nil, remoteCatalog: false),
                keyB: MCPCatalogStamp(syncedAt: nil, remoteCatalog: false),
            ]
        )
        let events = LockedBox<[String]>([])
        let gate = RefreshGate()
        let reader = Task {
            await sync.read { key -> [MCPHandlerRecord]? in
                events.withLock { $0.append("start \(key.literal)") }
                await gate.waitForOpen()
                events.withLock { $0.append("end \(key.literal)") }
                return try? syncTools(["tools.\(key.integration).org.main.new"])
            }
        }
        try await waitFor("first start") { events.withLock { $0 }.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        // Still queued behind the single slot.
        #expect(events.withLock { $0 }.count == 1)
        gate.open()
        let snapshot = await reader.value
        #expect(snapshot.count == 2)
        // Serialized: the second start happens after the first end, whichever
        // key won the race to the single slot.
        let log = events.withLock { $0 }
        #expect(log.filter { $0.hasPrefix("start") }.count == 2)
        #expect(log.filter { $0.hasPrefix("end") }.count == 2)
        let firstEnd = try #require(log.firstIndex { $0.hasPrefix("end") })
        let secondStart = try #require(log.lastIndex { $0.hasPrefix("start") })
        #expect(firstEnd < secondStart)
    }

    /// Oracle: connections.test.ts "overlaps stale discovery but never
    /// overlaps catalog persistence" (behavioral half: overlapping rebuilds
    /// merge exactly, with no lost update).
    @Test func overlappingRefreshesMergeExactly() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock, config: MCPCatalogSyncConfig(graceSeconds: nil))
        let keyA = syncKey("a", "org", "main")
        let keyB = syncKey("b", "org", "main")
        await sync.seed(
            tools: try syncTools(["tools.a.org.main.old", "tools.b.org.main.old"]),
            stamps: [
                keyA: MCPCatalogStamp(syncedAt: nil, remoteCatalog: false),
                keyB: MCPCatalogStamp(syncedAt: nil, remoteCatalog: false),
            ]
        )
        let snapshot = await sync.read { key -> [MCPHandlerRecord]? in
            try? syncTools(["tools.\(key.integration).org.main.new"])
        }
        #expect(snapshot.count == 2)
        #expect(snapshot.handler(for: try address("tools.a.org.main.new")) != nil)
        #expect(snapshot.handler(for: try address("tools.b.org.main.new")) != nil)
    }

    /// Oracle: connections.test.ts "explicit refresh accepts an authoritative
    /// empty catalog".
    @Test func explicitRefreshAcceptsAuthoritativeEmpty() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        let key = syncKey("mcp", "org", "srv")
        let other = syncKey("local", "org", "main")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old", "tools.local.org.main.keep"]),
            stamps: [
                key: MCPCatalogStamp(syncedAt: 1000, remoteCatalog: false),
                other: MCPCatalogStamp(syncedAt: 1000, remoteCatalog: false),
            ]
        )
        let cleared = await sync.refreshNow([key]) { _ in [] }
        #expect(cleared.handler(for: try address("tools.mcp.org.srv.old")) == nil)
        #expect(cleared.handler(for: try address("tools.local.org.main.keep")) != nil)

        // Re-stamped: the next read triggers nothing.
        let calls = LockedBox(0)
        _ = await sync.read { _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func refreshNowRegistersUnknownKeys() async throws {
        let clock = TestBox(1000.0)
        let warnings = LockedBox<[String]>([])
        let sync = syncHarness(clock: clock, warnings: warnings)
        let known = syncKey("mcp", "org", "srv")
        let unknown = syncKey("new", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old"]),
            stamps: [known: MCPCatalogStamp(syncedAt: 1000, remoteCatalog: false)]
        )
        let snapshot = await sync.refreshNow([unknown]) { _ in
            try? syncTools(["tools.new.org.srv.tool"])
        }
        #expect(snapshot.handler(for: try address("tools.new.org.srv.tool")) != nil)

        let failing = syncKey("fail", "org", "srv")
        _ = await sync.refreshNow([failing]) { _ in nil }
        #expect(warnings.withLock { $0 }.count == 1)
    }

    @Test func refreshNowDedupesKeys() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        let key = syncKey("mcp", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old"]),
            stamps: [key: MCPCatalogStamp(syncedAt: 1000, remoteCatalog: false)]
        )
        let calls = LockedBox(0)
        _ = await sync.refreshNow([key, key]) { _ in
            calls.withLock { $0 += 1 }
            return try? syncTools(["tools.mcp.org.srv.new"])
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func refreshNowEmptyKeysReturnsSnapshot() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old"]),
            stamps: [syncKey("mcp", "org", "srv"): MCPCatalogStamp(syncedAt: 1000)]
        )
        let calls = LockedBox(0)
        let snapshot = await sync.refreshNow([]) { _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        #expect(snapshot.count == 1)
        #expect(calls.withLock { $0 } == 0)
    }

    /// Oracle: tool-invoker.test.ts "shutdown is a no-op when nothing is in
    /// flight" (settle half).
    @Test func settleWithNothingInFlightIsNoop() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        await sync.settle()
        #expect((await sync.snapshot()).count == 0)
    }

    @Test func urgentAndDeferredSplitAcrossKeys() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(
            clock: clock, config: MCPCatalogSyncConfig(graceSeconds: 0.05)
        )
        let urgentKey = syncKey("a", "org", "main")
        let deferredKey = syncKey("b", "org", "main")
        await sync.seed(
            tools: try syncTools(["tools.a.org.main.old", "tools.b.org.main.old"]),
            stamps: [
                urgentKey: MCPCatalogStamp(syncedAt: nil, remoteCatalog: false),
                deferredKey: MCPCatalogStamp(syncedAt: 0, remoteCatalog: true),
            ]
        )
        let gate = RefreshGate()
        let first = await sync.read { key -> [MCPHandlerRecord]? in
            if key == deferredKey {
                await gate.waitForOpen()
            }
            return try? syncTools(["tools.\(key.integration).org.main.new"])
        }
        // Urgent waited; deferred still pending.
        #expect(first.handler(for: try address("tools.a.org.main.new")) != nil)
        #expect(first.handler(for: try address("tools.b.org.main.old")) != nil)
        gate.open()
        await sync.settle()
        let converged = await sync.snapshot()
        #expect(converged.handler(for: try address("tools.b.org.main.new")) != nil)
    }

    @Test func markStaleRegistersUnknownKeys() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        let unknown = syncKey("new", "org", "srv")
        await sync.seed(tools: [], stamps: [:])
        await sync.markStale(unknown)
        let calls = LockedBox<[MCPConnectionKey]>([])
        _ = await sync.read { key in
            calls.withLock { $0.append(key) }
            return []
        }
        #expect(calls.withLock { $0 } == [unknown])
    }

    @Test func markStalePreservesRemoteFlag() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        let key = syncKey("mcp", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.tool"]),
            stamps: [key: MCPCatalogStamp(syncedAt: 1000, remoteCatalog: true)]
        )
        await sync.markStale(key)
        let calls = LockedBox(0)
        _ = await sync.read { _ in
            calls.withLock { $0 += 1 }
            return try? syncTools(["tools.mcp.org.srv.tool"])
        }
        #expect(calls.withLock { $0 } == 1)

        // Still remote: aging past the TTL re-triggers (deferred, so settle
        // before asserting the background launch landed).
        clock.value = 1000 + MCPCatalogSyncConfig.defaultSyncTTLSeconds + 1
        _ = await sync.read { _ in
            calls.withLock { $0 += 1 }
            return try? syncTools(["tools.mcp.org.srv.tool"])
        }
        await sync.settle()
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func seedFreshConvenienceStampsFresh() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        await sync.seed(tools: try syncTools(["tools.a.org.main.tool"]))
        let calls = LockedBox(0)
        let snapshot = await sync.read { _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(snapshot.count == 1)

        await sync.seed(tools: [])
        #expect((await sync.snapshot()).count == 0)
    }

    @Test func seedDedupesLastWinsAndSorts() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock)
        await sync.seed(
            tools: [
                try record("tools.b.org.main.tool", description: "first"),
                try record("tools.a.org.main.tool", description: "only"),
                try record("tools.b.org.main.tool", description: "last"),
            ],
            stamps: [:]
        )
        let snapshot = await sync.snapshot()
        #expect(snapshot.count == 2)
        let kept = try #require(
            snapshot.handler(for: try address("tools.b.org.main.tool"))
        )
        #expect(kept.description == "last")
    }

    @Test func syncConfigClampsAndDefaults() throws {
        let defaults = MCPCatalogSyncConfig()
        #expect(defaults.syncTTLSeconds == 900)
        #expect(defaults.graceSeconds == 2)
        #expect(defaults.maxConcurrentRefreshes == 10)

        let clamped = MCPCatalogSyncConfig(
            syncTTLSeconds: -5, graceSeconds: -1, maxConcurrentRefreshes: 0
        )
        #expect(clamped.syncTTLSeconds == 0)
        #expect(clamped.graceSeconds == 0)
        #expect(clamped.maxConcurrentRefreshes == 1)

        let nils = MCPCatalogSyncConfig(syncTTLSeconds: nil, graceSeconds: nil)
        #expect(nils.syncTTLSeconds == nil)
        #expect(nils.graceSeconds == nil)
    }

    @Test func syncConfigDecodeEnforcesClamps() throws {
        let data = Data(
            #"{"syncTTLSeconds":-5,"graceSeconds":-1,"maxConcurrentRefreshes":0}"#.utf8
        )
        let decoded = try JSONDecoder().decode(MCPCatalogSyncConfig.self, from: data)
        #expect(decoded.syncTTLSeconds == 0)
        #expect(decoded.graceSeconds == 0)
        #expect(decoded.maxConcurrentRefreshes == 1)
    }

    @Test func zeroGraceServesStaleImmediately() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(clock: clock, config: MCPCatalogSyncConfig(graceSeconds: 0))
        let key = syncKey("mcp", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old"]),
            stamps: [key: MCPCatalogStamp(syncedAt: nil, remoteCatalog: false)]
        )
        let gate = RefreshGate()
        let read = await sync.read { _ -> [MCPHandlerRecord]? in
            await gate.waitForOpen()
            return try? syncTools(["tools.mcp.org.srv.new"])
        }
        #expect(read.handler(for: try address("tools.mcp.org.srv.old")) != nil)
        gate.open()
        await sync.settle()
        #expect(
            (await sync.snapshot()).handler(for: try address("tools.mcp.org.srv.new")) != nil
        )
    }

    @Test func cancelledReadStillServesStale() async throws {
        let clock = TestBox(1000.0)
        let sync = syncHarness(
            clock: clock, config: MCPCatalogSyncConfig(graceSeconds: 0.3)
        )
        let key = syncKey("mcp", "org", "srv")
        await sync.seed(
            tools: try syncTools(["tools.mcp.org.srv.old"]),
            stamps: [key: MCPCatalogStamp(syncedAt: nil, remoteCatalog: false)]
        )
        let gate = RefreshGate()
        let reader = Task {
            await sync.read { _ -> [MCPHandlerRecord]? in
                await gate.waitForOpen()
                return try? syncTools(["tools.mcp.org.srv.new"])
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        reader.cancel()
        // Cancellation abandons the wait, never the catalog: stale serves.
        // (The sleep's throw is swallowed, so the wait collapses instead of
        // hanging to the deadline.)
        let snapshot = await reader.value
        #expect(snapshot.handler(for: try address("tools.mcp.org.srv.old")) != nil)
        gate.open()
        await sync.settle()
    }

    // MARK: - Stress

    @Test func stressLargeCatalogSearchListDescribe() throws {
        var tools: [MCPHandlerRecord] = []
        for integration in 0..<20 {
            for tool in 0..<100 {
                tools.append(
                    try record(
                        "tools.svc\(integration).org.main.tool\(tool)",
                        description: "Service \(integration) tool \(tool)"
                    )
                )
            }
        }
        let registry = MCPRegistry(handlers: tools)
        #expect(registry.count == 2000)

        let page = registry.search(query: "tool", limit: 50)
        #expect(page.total == 2000)
        #expect(page.items.count == 50)
        #expect(page.hasMore == true)
        #expect(page.nextOffset == 50)

        let filtered = registry.list(filter: MCPToolListFilter(integration: "svc7"))
        #expect(filtered.count == 100)

        let described = registry.describe(path: "svc3.org.main.tool42")
        #expect(described.name == "tool42")
        #expect(described.error == nil)

        let missing = registry.describe(path: "svc3.org.main.nope")
        #expect(missing.error?.code == "tool_not_found")
        #expect((missing.error?.suggestions?.count ?? 0) <= 5)

        #expect(registry.listIntegrations().total == 20)
    }
}
