import Foundation
import RVDomain

/// Default-policy hints a plugin attaches to a tool. Advisory only: no wave-1
/// consumer reads them (neither `ScopedInvoker` nor discovery consults
/// `requiresApproval`), so a wave-2 consumer must wire `requiresApproval`
/// into the invoke policy gate instead of trusting these as enforced.
///
/// Field-for-field mirror of Executor `ToolAnnotations`
/// (`packages/core/sdk/src/tool.ts:11-15`) as projected by `ToolAnnotationsView`
/// (`packages/core/sdk/src/types.ts:22-25`): only these three keys ever surface,
/// so a record cannot leak a plugin's private bookkeeping the way a raw row could.
public struct MCPToolAnnotations: Sendable, Equatable, Hashable, Codable {
    /// The plugin wants an approval prompt before this tool runs.
    public let requiresApproval: Bool?
    /// Human-readable reason shown on the approval prompt.
    public let approvalDescription: String?
    /// The tool may raise an elicitation mid-run.
    public let mayElicit: Bool?

    /// Assembles one annotation set. Every field defaults to absent.
    public init(
        requiresApproval: Bool? = nil,
        approvalDescription: String? = nil,
        mayElicit: Bool? = nil
    ) {
        self.requiresApproval = requiresApproval
        self.approvalDescription = approvalDescription
        self.mayElicit = mayElicit
    }

    /// True when every field is absent. Empty sets are omitted from describe
    /// output, mirroring `toolAnnotationsView` returning undefined for an empty
    /// view (`packages/core/sdk/src/executor.ts:1238`).
    public var isEmpty: Bool {
        requiresApproval == nil && approvalDescription == nil && mayElicit == nil
    }
}

/// Minimal routing record for one tool address.
///
/// Execution is owned by T8 (ScopedInvoker): this record carries routing only —
/// address, static-tier flag, and plugin default — and never an invoke closure,
/// transport handle, or credential. No execution signature is defined here by design.
///
/// X1-P adds discovery metadata alongside routing: a human description, opaque
/// input/output schema JSON (opaque exactly like Executor `ToolDef` schemas,
/// which are "opaque JSON to core"), and the plugin's approval annotations.
/// All four default to nil, so every pre-X1 construction site keeps compiling
/// and legacy JSON without the new keys still decodes.
public struct MCPHandlerRecord: Sendable, Equatable, Hashable, Codable {
    /// Validated address this record serves.
    public let address: MCPToolAddress
    /// True when the address is pinned in the static-fqid tier and bypasses pattern matching.
    public let isStaticFqid: Bool
    /// Per-handler fallback suggested by the owning plugin. Composition with the
    /// store-level plugin default is owned by T8 (ScopedInvoker); the registry only stores it.
    public let pluginDefault: PolicyAction
    /// Human description used for search ranking and describe output.
    public let description: String?
    /// Opaque input schema JSON, served verbatim by describe. Never interpreted here.
    public let inputSchemaJSON: String?
    /// Opaque output schema JSON, served verbatim by describe. Never interpreted here.
    public let outputSchemaJSON: String?
    /// The plugin's approval annotations, if it declared any.
    public let annotations: MCPToolAnnotations?

    /// Assembles one routing record. Discovery fields default to absent.
    public init(
        address: MCPToolAddress,
        isStaticFqid: Bool,
        pluginDefault: PolicyAction,
        description: String? = nil,
        inputSchemaJSON: String? = nil,
        outputSchemaJSON: String? = nil,
        annotations: MCPToolAnnotations? = nil
    ) {
        self.address = address
        self.isStaticFqid = isStaticFqid
        self.pluginDefault = pluginDefault
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
        self.outputSchemaJSON = outputSchemaJSON
        self.annotations = annotations
    }
}

/// Immutable address-to-handler map. Routing only; never executes.
///
/// T8 seam: `ScopedInvoker` looks the handler up here, then enforces its own
/// policy-validate-approve-credential-invoke ordering over its own transports.
/// Nothing in this file validates arguments, elicits approval, resolves credentials,
/// or invokes tools. All registrations are fixed at init; there is no mutation API.
public struct MCPRegistry: Sendable {
    private let handlers: [MCPToolAddress: MCPHandlerRecord]

    /// Builds an immutable registry. Later records win on duplicate addresses.
    public init(handlers: [MCPHandlerRecord] = []) {
        self.handlers = Dictionary(
            handlers.map { ($0.address, $0) },
            uniquingKeysWith: { _, last in last }
        )
    }

    /// Returns the record for one validated address, or nil when unregistered.
    public func handler(for address: MCPToolAddress) -> MCPHandlerRecord? {
        handlers[address]
    }

    /// Number of distinct registered addresses.
    public var count: Int {
        handlers.count
    }
}

// MARK: - Discovery shapes

/// One ranked search hit. Mirrors Executor `ToolDiscoveryResult`
/// (`packages/core/execution/src/tool-invoker.ts:411-417`).
public struct MCPToolMatch: Sendable, Equatable, Hashable, Codable {
    /// Sandbox-callable path: the address literal without the `tools.` prefix.
    public let path: String
    /// Leaf tool segment.
    public let name: String
    /// The record's description, when it carries one.
    public let description: String?
    /// Integration slug.
    public let integration: String
    /// Ranking score; higher sorts first. Enumeration hits score 0.
    public let score: Int

    /// Assembles one search hit.
    public init(path: String, name: String, description: String?, integration: String, score: Int) {
        self.path = path
        self.name = name
        self.description = description
        self.integration = integration
        self.score = score
    }
}

/// One page of a discovery listing. Mirrors Executor `PagedResult`
/// (`packages/core/execution/src/tool-invoker.ts:458-475`): `items` is the
/// slice, `total` counts after filtering but before pagination, `hasMore`
/// flags `(offset + items.count) < total`, and `nextOffset` carries the next
/// page offset (nil when there is none), pre-computed so paginating callers
/// cannot go off by one.
public struct MCPPage<T: Sendable>: Sendable {
    /// This page's slice.
    public let items: [T]
    /// Count after filtering, before pagination.
    public let total: Int
    /// True when more pages remain.
    public let hasMore: Bool
    /// Offset for the next page, or nil when this page is the last.
    public let nextOffset: Int?

    /// Assembles one page.
    public init(items: [T], total: Int, hasMore: Bool, nextOffset: Int?) {
        self.items = items
        self.total = total
        self.hasMore = hasMore
        self.nextOffset = nextOffset
    }
}

extension MCPPage: Equatable where T: Equatable {}
extension MCPPage: Hashable where T: Hashable {}
extension MCPPage: Codable where T: Codable {}

// MARK: - Discovery: search

extension MCPRegistry {
    /// Ranks registered tools against a free-text query. Ports Executor
    /// `searchTools` (`packages/core/execution/src/tool-invoker.ts:674-750`).
    ///
    /// - Empty query with no namespace returns an empty page: no ranking signal
    ///   and no scope must never dump the catalog.
    /// - Empty query WITH a namespace enumerates that integration's whole
    ///   catalog, path-sorted with score 0, scoped by EXACT slug so `total`
    ///   reconciles against `listIntegrations`' `toolCount`.
    /// - Ranked search filters by fuzzy namespace prefix, scores every
    ///   surviving tool, and sorts score-descending, path-ascending.
    ///
    /// Scoped surfaces post-filter through `isBlocked`: ranking is fuzzy
    /// (token-prefix over normalized text) while toolkit scopes match exact
    /// segments, so search can surface tools the scope then blocks. The
    /// `isBlocked` parameter is required precisely so a scoped caller cannot
    /// forget that filter; there is no exact-match search mode.
    ///
    /// `limit` defaults to 12 (the Executor default); negative limits behave as
    /// zero and negative offsets clamp to zero (Executor `paginate`, same file
    /// :465-476 — the engine-validator rejection of negative offsets lives on
    /// the execution path, out of scope here). `isBlocked` hides
    /// policy-rejected tools from ranking, since Executor search reads through
    /// `tools.list` with `includeBlocked` defaulting to false. It is a
    /// required parameter with no default, so wiring the policy verdict is a
    /// compiler error to forget; genuinely unscoped surfaces pass
    /// `{ _ in false }` explicitly.
    public func search(
        query: String,
        namespace: String? = nil,
        limit: Int = 12,
        offset: Int = 0,
        isBlocked: (MCPToolAddress) -> Bool
    ) -> MCPPage<MCPToolMatch> {
        let visible = handlers.values.filter { isBlocked($0.address) == false }
        if mcpNormalizeSearchText(query).isEmpty {
            if let scope = namespace, mcpNormalizeSearchText(scope).isEmpty == false {
                return mcpEnumerate(records: visible, scope: scope, limit: limit, offset: offset)
            }
            return MCPPage(items: [], total: 0, hasMore: false, nextOffset: nil)
        }
        let ranked = visible
            .map(mcpSearchable)
            .filter { mcpMatchesNamespace(tool: $0, namespace: namespace) }
            .compactMap { mcpScoreTool($0, query: query) }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.path < $1.path
            }
        return mcpPaginate(ranked, limit: limit, offset: offset)
    }

    /// Lists registered tools under a filter. Ports Executor `tools.list`
    /// filtering (`matchesToolFilter`, `packages/core/sdk/src/executor.ts:5514`)
    /// plus the tool-row projection (`tool-row-projection.test.ts`: list
    /// returns metadata without loading the schema columns): results always
    /// omit `inputSchemaJSON`/`outputSchemaJSON`, and omit `annotations` when
    /// the filter's `includeAnnotations` is false. Results sort by literal for
    /// determinism. Blocked tools are omitted unless `includeBlocked` is set
    /// (`policies.test.ts`: "a blocked tool is omitted from tools.list" /
    /// "includeBlocked surfaces blocked tools"). `isBlocked` is required
    /// with no default, so wiring the policy verdict is a compiler error to
    /// forget; genuinely unscoped surfaces pass `{ _ in false }` explicitly.
    public func list(
        filter: MCPToolListFilter = MCPToolListFilter(),
        isBlocked: (MCPToolAddress) -> Bool
    ) -> [MCPHandlerRecord] {
        handlers.values
            .filter { mcpMatchesFilter($0, filter: filter) }
            .filter { filter.includeBlocked || isBlocked($0.address) == false }
            .map { mcpProjectListRecord($0, includeAnnotations: filter.includeAnnotations) }
            .sorted { $0.address.literal < $1.address.literal }
    }

    /// Lists integrations derived from registered tools, with live per-
    /// integration tool counts. Ports Executor `listExecutorIntegrations`
    /// (`packages/core/execution/src/tool-invoker.ts:759-838`): token-AND query
    /// filtering over the normalized identity text, single-pass counting, sort
    /// by id, and the shared paginate shape (default limit 50).
    /// Counts exclude blocked tools, as the Executor counts read through
    /// `tools.list` with `includeBlocked` defaulting to false. `isBlocked`
    /// is required with no default, so wiring the policy verdict is a
    /// compiler error to forget; genuinely unscoped surfaces pass
    /// `{ _ in false }` explicitly.
    public func listIntegrations(
        query: String? = nil,
        limit: Int = 50,
        offset: Int = 0,
        isBlocked: (MCPToolAddress) -> Bool
    ) -> MCPPage<MCPIntegrationItem> {
        var counts: [String: Int] = [:]
        for record in handlers.values where isBlocked(record.address) == false {
            counts[record.address.integration, default: 0] += 1
        }
        var items = counts.map { MCPIntegrationItem(id: $0.key, name: $0.key, toolCount: $0.value) }
        if let query, mcpNormalizeSearchText(query).isEmpty == false {
            let tokens = mcpTokenizeSearchText(query)
            items = items.filter { item in
                tokens.allSatisfy { mcpNormalizeSearchText(item.id).contains($0) }
            }
        }
        items.sort { $0.id < $1.id }
        return mcpPaginate(items, limit: limit, offset: offset)
    }

    /// Describes one tool's opaque shapes and annotations. Ports Executor
    /// `describeTool` (`packages/core/execution/src/tool-invoker.ts:840-920`)
    /// minus the TypeScript rendering and builtin discovery-tool docs (no
    /// sandbox surface exists here): accepts a sandbox path or a full
    /// `tools.`-prefixed literal, serves stored schemas verbatim plus the
    /// annotations view, and answers unknown or blocked paths with a
    /// `tool_not_found` error carrying up to five ranked suggestions — never a
    /// bare stub. Blocked tools read as not-found because Executor
    /// `tools.schema` returns null for them and describe mirrors that null.
    /// `isBlocked` is required with no default, so wiring the policy verdict
    /// is a compiler error to forget; genuinely unscoped surfaces pass
    /// `{ _ in false }` explicitly.
    public func describe(
        path: String,
        isBlocked: (MCPToolAddress) -> Bool
    ) -> MCPDescribedTool {
        // The queried path is attacker bytes of arbitrary length: bound the
        // echo before it reaches served responses and logs.
        let echoed = mcpSanitizeDescribeEcho(path)
        if let address = mcpResolveDescribeAddress(path),
            let record = handlers[address],
            isBlocked(address) == false
        {
            return MCPDescribedTool(
                path: echoed,
                name: record.address.tool,
                description: record.description,
                inputSchemaJSON: record.inputSchemaJSON,
                outputSchemaJSON: record.outputSchemaJSON,
                annotations: mcpVisibleAnnotations(record.annotations)
            )
        }
        let found = suggestions(for: path, isBlocked: isBlocked)
        return MCPDescribedTool(
            path: echoed,
            name: echoed,
            error: MCPDescribeError(
                code: "tool_not_found",
                message: "Tool not found: \(echoed)",
                suggestions: found.isEmpty ? nil : found
            )
        )
    }

    /// Ranks up to `limit` (default 5, the Executor
    /// `TOOL_DESCRIBE_SUGGESTION_LIMIT`, tool-invoker.ts:24) candidate paths
    /// for an unknown tool path: a namespace-scoped leaf search first, falling
    /// back to a global leaf search when the scoped one is empty.
    /// `isBlocked` is required with no default, so wiring the policy verdict
    /// is a compiler error to forget; genuinely unscoped surfaces pass
    /// `{ _ in false }` explicitly.
    public func suggestions(
        for path: String,
        isBlocked: (MCPToolAddress) -> Bool,
        limit: Int = 5
    ) -> [String] {
        let capped = max(limit, 0)
        if capped == 0 {
            return []
        }
        let leaf = mcpLeafName(path)
        let scoped = search(
            query: leaf, namespace: mcpExtractNamespace(path), limit: capped, isBlocked: isBlocked
        )
        if scoped.items.isEmpty == false {
            return scoped.items.map { $0.path }
        }
        return search(query: leaf, limit: capped, isBlocked: isBlocked).items.map { $0.path }
    }
}

// MARK: - Discovery: private search machinery

/// Separator run collapsed to one space by normalization: `_ . / : -`
/// (Executor `normalizeSearchText`, tool-invoker.ts:507-512).
private let mcpSearchSeparatorValues: Set<UInt32> = [0x5F, 0x2E, 0x2F, 0x3A, 0x2D]

/// Field weights (Executor `SEARCH_FIELD_WEIGHTS`, tool-invoker.ts:500-505).
private let mcpSearchWeightPath = 12
private let mcpSearchWeightIntegration = 8
private let mcpSearchWeightName = 10
private let mcpSearchWeightDescription = 5

private func mcpIsAsciiLowerOrDigitValue(_ value: UInt32) -> Bool {
    (value >= 0x61 && value <= 0x7A) || (value >= 0x30 && value <= 0x39)
}

private func mcpIsAsciiUpperValue(_ value: UInt32) -> Bool {
    value >= 0x41 && value <= 0x5A
}

/// Splits camelCase boundaries: `[a-z0-9][A-Z]` gains a space (first half of
/// Executor `normalizeSearchText`). Scalar-based so multi-scalar graphemes
/// classify exactly like the ASCII-only regex (never a boundary).
private func mcpSplitCamelCase(_ value: String) -> String {
    var out = ""
    var previous: UInt32? = nil
    for scalar in value.unicodeScalars {
        if let prior = previous,
            mcpIsAsciiLowerOrDigitValue(prior),
            mcpIsAsciiUpperValue(scalar.value)
        {
            out.append(" ")
        }
        out.unicodeScalars.append(scalar)
        previous = scalar.value
    }
    return out
}

/// Lowercases, splits camelCase, collapses separator runs to single spaces,
/// and trims. Ports Executor `normalizeSearchText` verbatim.
private func mcpNormalizeSearchText(_ value: String) -> String {
    var out = ""
    var inSeparatorRun = false
    for scalar in mcpSplitCamelCase(value).unicodeScalars {
        if mcpSearchSeparatorValues.contains(scalar.value) {
            if inSeparatorRun == false {
                out.append(" ")
            }
            inSeparatorRun = true
        } else {
            out.unicodeScalars.append(scalar)
            inSeparatorRun = false
        }
    }
    return out.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Splits normalized text on non-`[a-z0-9]` runs, dropping empties. Ports
/// Executor `tokenizeSearchText` (tool-invoker.ts:514-519), scalar-based so
/// non-ASCII scalars are separators exactly like the regex.
private func mcpTokenizeSearchText(_ value: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    for scalar in mcpNormalizeSearchText(value).unicodeScalars {
        if mcpIsAsciiLowerOrDigitValue(scalar.value) {
            current.unicodeScalars.append(scalar)
        } else if current.isEmpty == false {
            tokens.append(current)
            current = ""
        }
    }
    if current.isEmpty == false {
        tokens.append(current)
    }
    return tokens
}

/// What search ranks over: the sandbox-callable path plus identity fields.
private struct MCPSearchableTool {
    let path: String
    let integration: String
    let name: String
    let description: String?
}

private func mcpSearchable(_ record: MCPHandlerRecord) -> MCPSearchableTool {
    MCPSearchableTool(
        path: mcpSandboxPath(record.address),
        integration: record.address.integration,
        name: record.address.tool,
        description: record.description
    )
}

/// Strips the proxy-root `tools.` prefix so the literal becomes the
/// sandbox-callable path. Ports Executor `addressToPath` (tool-invoker.ts:74).
private func mcpSandboxPath(_ address: MCPToolAddress) -> String {
    String(address.literal.dropFirst("tools.".count))
}

/// One prepared field: normalized raw text plus its tokens.
private struct MCPSearchField {
    let raw: String
    let tokens: [String]
}

private func mcpPrepareField(_ value: String?) -> MCPSearchField {
    MCPSearchField(
        raw: mcpNormalizeSearchText(value ?? ""),
        tokens: mcpTokenizeSearchText(value ?? "")
    )
}

private struct MCPSearchFieldScore {
    let score: Int
    let matchedTokens: Set<String>
    let exactPhraseMatch: Bool
}

/// Scores one field. Ports Executor `scorePreparedField`
/// (tool-invoker.ts:525-583): whole-field exact/prefix/phrase bonuses
/// (weight x14/x9/x6), then per-token exact (x4), either-way prefix (x2), and
/// raw-substring (x1) matches.
///
/// The caller guarantees a non-empty normalized query (empty queries take the
/// enumeration/empty arms before scoring), so the `query.length > 0` guards
/// are folded away: identical behavior on every reachable input.
private func mcpScoreField(
    query: String,
    queryTokens: [String],
    field: MCPSearchField,
    weight: Int
) -> MCPSearchFieldScore {
    if field.raw.isEmpty {
        return MCPSearchFieldScore(score: 0, matchedTokens: [], exactPhraseMatch: false)
    }
    var score = 0
    var matched: Set<String> = []
    let exactPhraseMatch = field.raw.contains(query)
    if field.raw == query {
        score += weight * 14
    } else if field.raw.hasPrefix(query) {
        score += weight * 9
    } else if exactPhraseMatch {
        score += weight * 6
    }
    for token in queryTokens {
        if field.tokens.contains(token) {
            score += weight * 4
            matched.insert(token)
        } else if field.tokens.contains(where: { $0.hasPrefix(token) || token.hasPrefix($0) }) {
            score += weight * 2
            matched.insert(token)
        } else if field.raw.contains(token) {
            score += weight
            matched.insert(token)
        }
    }
    return MCPSearchFieldScore(
        score: score, matchedTokens: matched, exactPhraseMatch: exactPhraseMatch
    )
}

/// True when the tool sits under the namespace: token-prefix match over the
/// integration tokens or the path tokens. Ports Executor `matchesNamespace`
/// (tool-invoker.ts:585-602), including blank/non-tokenizing namespaces
/// matching everything.
private func mcpMatchesNamespace(tool: MCPSearchableTool, namespace: String?) -> Bool {
    guard let namespace, mcpNormalizeSearchText(namespace).isEmpty == false else {
        return true
    }
    let namespaceTokens = mcpTokenizeSearchText(namespace)
    if namespaceTokens.isEmpty {
        return true
    }
    return mcpIsTokenPrefixMatch(mcpTokenizeSearchText(tool.integration), namespaceTokens)
        || mcpIsTokenPrefixMatch(mcpTokenizeSearchText(tool.path), namespaceTokens)
}

private func mcpIsTokenPrefixMatch(_ tokens: [String], _ namespaceTokens: [String]) -> Bool {
    for (index, token) in namespaceTokens.enumerated() {
        if index >= tokens.count || tokens[index] != token {
            return false
        }
    }
    return true
}

/// Scores one tool against a raw query, or nil when it must not rank. Ports
/// Executor `scoreToolMatch` (tool-invoker.ts:604-672): union coverage over
/// the four weighted fields, minimum coverage 1.0 for 1-2 token queries else
/// 0.6 (waived when a field contains the whole phrase), full-coverage +25
/// else rounded coverage x10, head-token +8, and whole path/name exact +20.
///
/// One simplification, behavior-identical on reachable inputs: the empty
/// guard checks tokens only, since an empty normalized query always
/// tokenizes empty, so the `||` arm adds nothing. (Tokens non-empty implies
/// the normalized query is non-empty, so the field scorer's `query.length >
/// 0` guards hold on every call.)
///
/// The coverage gate keeps Executor's `&& !exactPhraseMatch` escape: with a
/// repeated-token query (`"list list"`) the matched set dedupes while the
/// query list does not, so coverage can sit below the minimum even when a
/// field contains the whole phrase — exactly the case the escape saves.
private func mcpScoreTool(_ tool: MCPSearchableTool, query: String) -> MCPToolMatch? {
    let normalizedQuery = mcpNormalizeSearchText(query)
    let queryTokens = mcpTokenizeSearchText(query)
    guard queryTokens.isEmpty == false else {
        return nil
    }
    let fields = [
        mcpScoreField(
            query: normalizedQuery,
            queryTokens: queryTokens,
            field: mcpPrepareField(tool.path),
            weight: mcpSearchWeightPath
        ),
        mcpScoreField(
            query: normalizedQuery,
            queryTokens: queryTokens,
            field: mcpPrepareField(tool.integration),
            weight: mcpSearchWeightIntegration
        ),
        mcpScoreField(
            query: normalizedQuery,
            queryTokens: queryTokens,
            field: mcpPrepareField(tool.name),
            weight: mcpSearchWeightName
        ),
        mcpScoreField(
            query: normalizedQuery,
            queryTokens: queryTokens,
            field: mcpPrepareField(tool.description),
            weight: mcpSearchWeightDescription
        ),
    ]
    var matched: Set<String> = []
    var score = 0
    var exactPhraseMatch = false
    for fieldScore in fields {
        score += fieldScore.score
        exactPhraseMatch = exactPhraseMatch || fieldScore.exactPhraseMatch
        matched.formUnion(fieldScore.matchedTokens)
    }
    if matched.isEmpty {
        return nil
    }
    let minimumCoverage = queryTokens.count <= 2 ? 1.0 : 0.6
    let coverage = Double(matched.count) / Double(queryTokens.count)
    if coverage < minimumCoverage, exactPhraseMatch == false {
        return nil
    }
    if coverage == 1 {
        score += 25
    } else {
        // Integer half-up rounding of coverage x10, matching Math.round
        // exactly (including .5 cases, where banker's rounding diverges).
        score += (20 * matched.count + queryTokens.count) / (2 * queryTokens.count)
    }
    let pathTokens = mcpTokenizeSearchText(tool.path)
    let nameTokens = mcpTokenizeSearchText(tool.name)
    if pathTokens.first == queryTokens.first || nameTokens.first == queryTokens.first {
        score += 8
    }
    if mcpNormalizeSearchText(tool.path) == normalizedQuery
        || mcpNormalizeSearchText(tool.name) == normalizedQuery
    {
        score += 20
    }
    return MCPToolMatch(
        path: tool.path,
        name: tool.name,
        description: tool.description,
        integration: tool.integration,
        score: score
    )
}

/// Enumerates one integration's whole catalog for an empty query: EXACT slug
/// match (never the fuzzy prefix ranked search uses), path-sorted, score 0.
private func mcpEnumerate(
    records: [MCPHandlerRecord],
    scope: String,
    limit: Int,
    offset: Int
) -> MCPPage<MCPToolMatch> {
    let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
    let items = records
        .filter { $0.address.integration == trimmed }
        .map { record -> MCPToolMatch in
            let searchable = mcpSearchable(record)
            return MCPToolMatch(
                path: searchable.path,
                name: searchable.name,
                description: searchable.description,
                integration: searchable.integration,
                score: 0
            )
        }
        .sorted { $0.path < $1.path }
    return mcpPaginate(items, limit: limit, offset: offset)
}

/// Shared paginate shape. Ports Executor `paginate` (tool-invoker.ts:465-476):
/// negative offsets clamp to zero, over-long offsets yield an empty page that
/// still reports the full total, and `nextOffset` is pre-computed. Limits
/// clamp at zero and the slice arithmetic is overflow-safe for `Int.max`.
private func mcpPaginate<T>(_ all: [T], limit: Int, offset: Int) -> MCPPage<T> {
    let total = all.count
    let start = min(max(offset, 0), total)
    let count = min(max(limit, 0), total - start)
    let items = Array(all[start..<(start + count)])
    let consumed = start + items.count
    let hasMore = consumed < total
    return MCPPage(items: items, total: total, hasMore: hasMore, nextOffset: hasMore ? consumed : nil)
}

/// Exact integration/owner/connection matches plus a case-insensitive
/// substring query against tool name or description. Ports Executor
/// `matchesToolFilter` (executor.ts:5514-5525); the nil description reads as
/// "" since Executor rows always carry a string.
private func mcpMatchesFilter(_ record: MCPHandlerRecord, filter: MCPToolListFilter) -> Bool {
    if let integration = filter.integration, record.address.integration != integration {
        return false
    }
    if let owner = filter.owner, record.address.owner != owner {
        return false
    }
    if let connection = filter.connection, record.address.connection != connection {
        return false
    }
    if let query = filter.query {
        let haystack = "\(record.address.tool) \(record.description ?? "")".lowercased()
        if haystack.contains(query.lowercased()) == false {
            return false
        }
    }
    return true
}

/// Projects one record onto the list surface: schemas never load (the
/// tool-row projection), annotations only when requested.
private func mcpProjectListRecord(
    _ record: MCPHandlerRecord,
    includeAnnotations: Bool
) -> MCPHandlerRecord {
    MCPHandlerRecord(
        address: record.address,
        isStaticFqid: record.isStaticFqid,
        pluginDefault: record.pluginDefault,
        description: record.description,
        inputSchemaJSON: nil,
        outputSchemaJSON: nil,
        annotations: includeAnnotations ? record.annotations : nil
    )
}

/// Maps a describe path to an address literal. Ports Executor `pathToAddress`
/// (tool-invoker.ts:64-72): a `tools.`-prefixed path parses as-is, otherwise
/// the prefix is applied when the result parses. RV has no bare-fqid tier, so
/// an unparseable path yields nil (not-found with suggestions) instead of a
/// static lookup.
private func mcpResolveDescribeAddress(_ path: String) -> MCPToolAddress? {
    if path.hasPrefix("tools.") {
        return mcpParseAddress(path)
    }
    return mcpParseAddress("tools." + path)
}

private func mcpParseAddress(_ literal: String) -> MCPToolAddress? {
    do {
        return try MCPToolAddress.parse(literal)
    } catch {
        return nil
    }
}

/// First path segment after stripping the `tools.` prefix, or the whole
/// stripped path when there is no dot. Ports Executor `extractNamespace`
/// (tool-invoker.ts:295-299).
private func mcpExtractNamespace(_ path: String) -> String {
    let stripped = path.hasPrefix("tools.") ? String(path.dropFirst("tools.".count)) : path
    if let dot = stripped.firstIndex(of: ".") {
        return String(stripped[..<dot])
    }
    return stripped
}

/// Leaf segment after the last dot, or the whole path when there is none.
private func mcpLeafName(_ path: String) -> String {
    if let dot = path.lastIndex(of: ".") {
        return String(path[path.index(after: dot)...])
    }
    return path
}

/// Drops nil and empty annotation sets from describe output.
private func mcpVisibleAnnotations(_ annotations: MCPToolAnnotations?) -> MCPToolAnnotations? {
    guard let annotations, annotations.isEmpty == false else {
        return nil
    }
    return annotations
}

/// Longest attacker-path echo served by describe (path, name, message).
private let mcpDescribeEchoCharacters = 256

/// Bounds the queried path before `describe` echoes it: control scalars
/// (newlines, ANSI escapes, and the rest of Cc, which would inject log
/// lines and terminal sequences into serving-layer sinks) are stripped,
/// then the echo is cut to `mcpDescribeEchoCharacters` characters.
/// Legitimate paths are short and control-free, so they pass through
/// unchanged.
private func mcpSanitizeDescribeEcho(_ path: String) -> String {
    let clean = path.unicodeScalars.filter { $0.properties.generalCategory != .control }
    return String(clean.map(Character.init).prefix(mcpDescribeEchoCharacters))
}

// MARK: - Catalog sync

/// Identifies one connection's tool catalog: the unit of freshness tracking.
/// Executor tracks the same triple on its connection rows (`integration`,
/// `owner`, `name`).
public struct MCPConnectionKey: Sendable, Equatable, Hashable, Codable {
    /// Integration slug.
    public let integration: String
    /// Owner segment.
    public let owner: String
    /// Connection segment.
    public let connection: String

    /// Assembles one connection key.
    public init(integration: String, owner: String, connection: String) {
        self.integration = integration
        self.owner = owner
        self.connection = connection
    }

    /// Dotted identity for ordering and diagnostics. Never a credential.
    public var literal: String {
        "\(integration).\(owner).\(connection)"
    }
}

private func mcpConnectionKey(for address: MCPToolAddress) -> MCPConnectionKey {
    MCPConnectionKey(
        integration: address.integration, owner: address.owner, connection: address.connection
    )
}

/// Freshness stamp for one connection's persisted tool catalog.
public struct MCPCatalogStamp: Sendable, Equatable, Hashable, Codable {
    /// When the catalog was last rebuilt, in `now()` seconds. Nil means
    /// stale-marked (Executor `tools_synced_at` NULL): a mid-invocation signal
    /// already declared this catalog wrong.
    public let syncedAt: Double?
    /// True when the plugin lists a live remote catalog (an MCP server whose
    /// tool set can change with no visible signal): only remote catalogs age
    /// out under the TTL.

    public let remoteCatalog: Bool

    /// Assembles one stamp. Defaults to stale-marked and non-remote.
    public init(syncedAt: Double? = nil, remoteCatalog: Bool = false) {
        self.syncedAt = syncedAt
        self.remoteCatalog = remoteCatalog
    }
}

/// Tuning for `MCPCatalogSync`. Ports the three Executor knobs
/// (`ExecutorConfig.toolsSyncTtlMs/toolsSyncGraceMs`,
/// `packages/core/sdk/src/executor.ts:783-800`, plus
/// `STALE_TOOLS_SYNC_CONCURRENCY`, same file :874): TTL default 900s (15min),
/// grace default 2s, concurrency default 10. Nil TTL disables time-based
/// re-sync (stale-mark and config-revision triggers still apply); nil grace
/// means converge (reads block until every rebuild finishes). Negative time
/// budgets clamp to zero and concurrency clamps to at least one.
public struct MCPCatalogSyncConfig: Sendable, Equatable, Hashable, Codable {
    /// Freshness window for remote catalogs, in seconds. Nil disables expiry.
    public let syncTTLSeconds: Double?
    /// How long a read waits for urgent rebuilds before serving persisted
    /// rows. Nil converges (waits for every rebuild).
    public let graceSeconds: Double?
    /// How many stale catalogs rebuild at once; the rest queue.
    public let maxConcurrentRefreshes: Int

    /// Default freshness window: 15 minutes.
    public static let defaultSyncTTLSeconds = 900.0
    /// Default urgent-wait budget: 2 seconds.
    public static let defaultGraceSeconds = 2.0
    /// Default rebuild width: 10.
    public static let defaultMaxConcurrentRefreshes = 10

    /// Assembles one sync config with Executor defaults.
    public init(
        syncTTLSeconds: Double? = defaultSyncTTLSeconds,
        graceSeconds: Double? = defaultGraceSeconds,
        maxConcurrentRefreshes: Int = defaultMaxConcurrentRefreshes
    ) {
        self.syncTTLSeconds = syncTTLSeconds.map { max($0, 0) }
        self.graceSeconds = graceSeconds.map { max($0, 0) }
        self.maxConcurrentRefreshes = max(maxConcurrentRefreshes, 1)
    }

    /// Decodes one config through the same clamps, so a decoded zero width
    /// or negative budget cannot wedge the refresh-slot gate. (Encoding stays
    /// synthesized; only stored properties encode.)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            syncTTLSeconds: try container.decodeIfPresent(Double.self, forKey: .syncTTLSeconds),
            graceSeconds: try container.decodeIfPresent(Double.self, forKey: .graceSeconds),
            maxConcurrentRefreshes: try container.decode(Int.self, forKey: .maxConcurrentRefreshes)
        )
    }
}

/// Owns one mutable tool catalog plus its freshness stamps, and serves
/// registry snapshots through the Executor stale-sync discipline
/// (`syncStaleConnectionTools`/`startStaleSync`/`readTools`,
/// `packages/core/sdk/src/executor.ts:5546-5822`).
///
/// Refresh triggers per connection (any one fires):
/// - stale-marked: `syncedAt` is nil;
/// - config-revised: the integration's last tool-affecting config revision
///   postdates the sync stamp (other subjects converge on their own read);
/// - expired: remote catalog older than the TTL cutoff. The cutoff only
///   exists when some registered connection is remote, so age alone never
///   widens the stale set on fully local catalogs.
///
/// Urgency split (bounded mode): stale-marked and config-revised catalogs are
/// known-wrong, so the read waits for them within the grace budget; merely
/// expired catalogs rebuild in the background while the read serves persisted
/// rows at once. Converge mode (nil grace) treats every trigger as urgent.
///
/// Guarantees: one in-flight refresh per connection no matter how many reads
/// join it (single-flight); at most `maxConcurrentRefreshes` rebuilds overlap
/// (the rest queue FIFO); every catalog merge runs actor-isolated, so
/// persistence never overlaps even when discovery does; a failed rebuild
/// warns through `onWarning` and keeps the stale-but-working rows, retrying
/// on the next read. Refresh results are authoritative, including the empty
/// catalog; only nil signals failure.
///
/// Time splits two ways by construction: staleness reads the injected `now`
/// clock (seconds; tests pin it), while the grace wait is wall-time polling
/// (a fake clock cannot advance while awaiting a real rebuild).
public actor MCPCatalogSync {
    /// Rebuilds one connection's catalog. Returns the authoritative rows
    /// (possibly empty) or nil when the rebuild failed and stale rows stand.
    public typealias RefreshCatalog = @Sendable (MCPConnectionKey) async -> [MCPHandlerRecord]?

    private let config: MCPCatalogSyncConfig
    private let now: @Sendable () -> Double
    private let onWarning: @Sendable (String) -> Void
    private var catalog: [MCPHandlerRecord]
    private var stamps: [MCPConnectionKey: MCPCatalogStamp]
    private var configRevisions: [String: Double]
    private var inFlight: [MCPConnectionKey: Task<[MCPHandlerRecord]?, Never>]
    private var runningRefreshes = 0
    private var refreshWaiters: [CheckedContinuation<Void, Never>]

    /// Builds a syncing catalog. `now` defaults to wall time and `onWarning`
    /// to a silent sink; tests inject both.
    public init(
        config: MCPCatalogSyncConfig = MCPCatalogSyncConfig(),
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
        onWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.config = config
        self.now = now
        self.onWarning = onWarning
        catalog = []
        stamps = [:]
        configRevisions = [:]
        inFlight = [:]
        refreshWaiters = []
    }

    /// Seeds the catalog and its stamps wholesale.
    public func seed(tools: [MCPHandlerRecord], stamps: [MCPConnectionKey: MCPCatalogStamp]) {
        catalog = mcpDedupeTools(tools)
        self.stamps = stamps
    }

    /// Seeds the catalog with every connection stamped fresh and non-remote.
    public func seed(tools: [MCPHandlerRecord]) {
        let fresh = now()
        var freshStamps: [MCPConnectionKey: MCPCatalogStamp] = [:]
        for tool in tools {
            freshStamps[mcpConnectionKey(for: tool.address)] = MCPCatalogStamp(
                syncedAt: fresh, remoteCatalog: false
            )
        }
        seed(tools: tools, stamps: freshStamps)
    }

    /// Stale-marks one connection (clears its sync stamp, like Executor
    /// `connections.markToolsStale` after a `tools/list_changed` signal),
    /// preserving its remote flag. Unknown keys register as stale non-remote.
    public func markStale(_ key: MCPConnectionKey) {
        let remote = stamps[key]?.remoteCatalog ?? false
        stamps[key] = MCPCatalogStamp(syncedAt: nil, remoteCatalog: remote)
    }

    /// Records a tool-affecting config revision for one integration, in
    /// `now()` seconds. Connections synced before it converge on their next
    /// read, under their own refresh.
    public func noteConfigRevision(integration: String, revision: Double) {
        configRevisions[integration] = revision
    }

    /// Serves the current catalog as an immutable registry snapshot.
    public func snapshot() -> MCPRegistry {
        MCPRegistry(handlers: catalog)
    }

    /// Reads the catalog through the stale sync: plans urgent vs deferred
    /// rebuilds, launches both, waits for the urgent set within the grace
    /// budget (or to convergence when grace is nil), and returns the snapshot.
    /// Deferred and over-grace rebuilds keep running detached and land on a
    /// later read.
    public func read(refresh: @escaping RefreshCatalog) async -> MCPRegistry {
        let plan = mcpPlanRefresh()
        let urgentHandles = launchRefreshes(for: plan.urgent, refresh: refresh)
        launchRefreshes(for: plan.deferred, refresh: refresh)
        if urgentHandles.isEmpty == false {
            await mcpAwaitUrgent(handles: urgentHandles, keys: plan.urgent)
        }
        return snapshot()
    }

    /// Forces a refresh of the given keys regardless of triggers and awaits
    /// every rebuild. An empty result is authoritative (clears the key's rows);
    /// nil warns and keeps stale rows. Unknown keys register on success.
    public func refreshNow(
        _ keys: [MCPConnectionKey],
        refresh: @escaping RefreshCatalog
    ) async -> MCPRegistry {
        var seen: Set<MCPConnectionKey> = []
        var ordered: [MCPConnectionKey] = []
        for key in keys {
            if seen.contains(key) == false {
                seen.insert(key)
                ordered.append(key)
            }
        }
        let handles = launchRefreshes(for: ordered, refresh: refresh)
        for handle in handles {
            _ = await handle.value
        }
        return snapshot()
    }

    /// Awaits every in-flight rebuild. A no-op when nothing is in flight.
    public func settle() async {
        while inFlight.isEmpty == false {
            for handle in Array(inFlight.values) {
                _ = await handle.value
            }
        }
    }

    private struct MCPRefreshPlan {
        let urgent: [MCPConnectionKey]
        let deferred: [MCPConnectionKey]
    }

    /// Splits registered connections into urgent and deferred rebuild sets.
    private func mcpPlanRefresh() -> MCPRefreshPlan {
        let timestamp = now()
        let converge = config.graceSeconds == nil
        var cutoff: Double? = nil
        if let ttl = config.syncTTLSeconds,
            stamps.values.contains(where: { $0.remoteCatalog })
        {
            cutoff = timestamp - ttl
        }
        var urgent: [MCPConnectionKey] = []
        var deferred: [MCPConnectionKey] = []
        let ordered = stamps.sorted { $0.key.literal < $1.key.literal }
        for (key, stamp) in ordered {
            let staleMarked = stamp.syncedAt == nil
            let configRevised: Bool
            if let revised = configRevisions[key.integration], let synced = stamp.syncedAt {
                configRevised = synced < revised
            } else {
                configRevised = false
            }
            let expired: Bool
            if let cutoff, stamp.remoteCatalog, let synced = stamp.syncedAt {
                expired = synced < cutoff
            } else {
                expired = false
            }
            if staleMarked || configRevised || expired {
                if staleMarked || configRevised || converge {
                    urgent.append(key)
                } else {
                    deferred.append(key)
                }
            }
        }
        return MCPRefreshPlan(urgent: urgent, deferred: deferred)
    }

    /// Launches (or joins) one refresh per key. In-flight keys are joined, so
    /// concurrent reads share one rebuild instead of stacking new ones.
    /// Refreshes run detached: abandoning the wait never cancels the rebuild.
    @discardableResult
    private func launchRefreshes(
        for keys: [MCPConnectionKey],
        refresh: @escaping RefreshCatalog
    ) -> [Task<[MCPHandlerRecord]?, Never>] {
        var handles: [Task<[MCPHandlerRecord]?, Never>] = []
        for key in keys {
            if let existing = inFlight[key] {
                handles.append(existing)
            } else {
                let handle = Task.detached { [refresh] in
                    await self.mcpAcquireRefreshSlot()
                    let rows = await refresh(key)
                    await self.mcpFinishRefresh(key: key, rows: rows)
                    return rows
                }
                inFlight[key] = handle
                handles.append(handle)
            }
        }
        return handles
    }

    /// Waits for the urgent set: to convergence when grace is nil, else by
    /// wall-time polling until the keys drain or the budget is spent. Polling
    /// (never awaiting the handles past the deadline) is what keeps a read
    /// gated on a dead server bounded: abandoning the wait leaves the
    /// detached rebuilds running to converge a later read.
    private func mcpAwaitUrgent(
        handles: [Task<[MCPHandlerRecord]?, Never>],
        keys: [MCPConnectionKey]
    ) async {
        guard let grace = config.graceSeconds else {
            for handle in handles {
                _ = await handle.value
            }
            return
        }
        var remaining = grace
        while remaining > 0, keys.contains(where: { inFlight[$0] != nil }) {
            try? await Task.sleep(for: .milliseconds(5))
            remaining -= 0.005
        }
    }

    /// FIFO refresh-slot gate: at most `maxConcurrentRefreshes` rebuilds hold
    /// a slot; the rest suspend until a finish hands one over.
    private func mcpAcquireRefreshSlot() async {
        if runningRefreshes < config.maxConcurrentRefreshes {
            runningRefreshes += 1
        } else {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                refreshWaiters.append(continuation)
            }
        }
    }

    private func mcpReleaseRefreshSlot() {
        if refreshWaiters.isEmpty {
            runningRefreshes -= 1
        } else {
            let waiter = refreshWaiters.removeFirst()
            waiter.resume()
        }
    }

    /// Merges one finished rebuild: clears the in-flight entry, hands the
    /// slot over, and — on success — replaces the key's rows, re-sorts, and
    /// re-stamps. Failures warn and keep stale rows, retrying next read.
    private func mcpFinishRefresh(key: MCPConnectionKey, rows: [MCPHandlerRecord]?) async {
        inFlight[key] = nil
        mcpReleaseRefreshSlot()
        guard let rows else {
            onWarning(
                "MCP catalog refresh failed for \(key.literal); serving persisted rows"
            )
            return
        }
        let surviving = catalog.filter { mcpConnectionKey(for: $0.address) != key }
        catalog = mcpDedupeTools(surviving + rows)
        stamps[key] = MCPCatalogStamp(
            syncedAt: now(), remoteCatalog: stamps[key]?.remoteCatalog ?? false
        )
    }
}

/// Dedupes tools by address (later wins, like `MCPRegistry.init`) and sorts
/// by literal so every snapshot order is deterministic.
private func mcpDedupeTools(_ tools: [MCPHandlerRecord]) -> [MCPHandlerRecord] {
    var byAddress: [MCPToolAddress: MCPHandlerRecord] = [:]
    for tool in tools {
        byAddress[tool.address] = tool
    }
    return byAddress.values.sorted { $0.address.literal < $1.address.literal }
}

/// Narrows a tool listing to a subset; omit for the whole catalog. Mirrors
/// Executor `ToolListFilter` (`packages/core/sdk/src/tool.ts:46-60`): exact
/// integration/owner/connection matches, a case-insensitive substring `query`
/// against name or description, and the two projection flags.
public struct MCPToolListFilter: Sendable, Equatable, Hashable, Codable {
    /// Keep only this integration slug.
    public let integration: String?
    /// Keep only this owner segment.
    public let owner: String?
    /// Keep only this connection segment.
    public let connection: String?
    /// Case-insensitive substring match against tool name or description.
    public let query: String?
    /// Project plugin annotations onto results. Defaults to true.
    public let includeAnnotations: Bool
    /// Include tools the `isBlocked` predicate rejects. Defaults to false, so
    /// agent-facing surfaces silently omit blocked tools.
    public let includeBlocked: Bool

    /// Assembles one list filter. Everything defaults to unfiltered/projected.
    public init(
        integration: String? = nil,
        owner: String? = nil,
        connection: String? = nil,
        query: String? = nil,
        includeAnnotations: Bool = true,
        includeBlocked: Bool = false
    ) {
        self.integration = integration
        self.owner = owner
        self.connection = connection
        self.query = query
        self.includeAnnotations = includeAnnotations
        self.includeBlocked = includeBlocked
    }
}

/// One integration row derived from the catalog. Mirrors the identity half of
/// Executor `ExecutorIntegrationListItem`
/// (`packages/core/execution/src/tool-invoker.ts:419-427`): RV has no separate
/// integration-catalog store in scope, so rows derive from registered tools —
/// `id`/`name` are the slug and `toolCount` is the live census, which must
/// reconcile against namespace enumeration's `total`. Description/kind and the
/// remove/refresh affordances have no source here and are omitted.
public struct MCPIntegrationItem: Sendable, Equatable, Hashable, Codable {
    /// Integration slug.
    public let id: String
    /// Display name; the slug, since no catalog display name exists here.
    public let name: String
    /// Tools registered under this integration (after blocked filtering).
    public let toolCount: Int

    /// Assembles one integration row.
    public init(id: String, name: String, toolCount: Int) {
        self.id = id
        self.name = name
        self.toolCount = toolCount
    }
}

/// A described tool: identity plus opaque shapes plus annotations. Mirrors the
/// non-TypeScript half of Executor `DescribedTool`
/// (`packages/core/execution/src/tool-invoker.ts:88-111`): RV serves the stored
/// schema JSON verbatim instead of rendering TypeScript previews, and carries
/// no observed-shape memory (that lives on the execution path, out of scope).
/// Unknown paths echo `path`/`name` and set `error`, never a silent stub.
public struct MCPDescribedTool: Sendable, Equatable, Hashable, Codable {
    /// The queried path, echoed verbatim.
    public let path: String
    /// Leaf tool segment when found; the queried path when not found.
    public let name: String
    /// The record's description, when found and described.
    public let description: String?
    /// Opaque input schema JSON, when found and stored.
    public let inputSchemaJSON: String?
    /// Opaque output schema JSON, when found and stored.
    public let outputSchemaJSON: String?
    /// Declared annotations, omitted when the tool carries none.
    public let annotations: MCPToolAnnotations?
    /// Set when the path resolves to no tool; mirrors invoke's not-found shape.
    public let error: MCPDescribeError?

    /// Assembles one described tool.
    public init(
        path: String,
        name: String,
        description: String? = nil,
        inputSchemaJSON: String? = nil,
        outputSchemaJSON: String? = nil,
        annotations: MCPToolAnnotations? = nil,
        error: MCPDescribeError? = nil
    ) {
        self.path = path
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
        self.outputSchemaJSON = outputSchemaJSON
        self.annotations = annotations
        self.error = error
    }

    /// Bridges a describe miss onto the invoke not-found shape, so serving
    /// planes share one conversion instead of hand-mapping. Nil when the
    /// tool resolved; otherwise `tool_not_found` with the echoed path and
    /// the ranked suggestions, normalizing absent suggestions to empty
    /// (describe omits the key when empty; the invoke shape always carries
    /// the array).
    public var toolError: MCPToolError? {
        guard error != nil else { return nil }
        return MCPToolError.toolNotFound(path: path, suggestions: error?.suggestions ?? [])
    }
}

/// Not-found payload for describe. Mirrors the `error` arm of Executor
/// `DescribedTool`: code `tool_not_found`, message `Tool not found: <path>`,
/// and up to five ranked suggestions, omitted when empty.
public struct MCPDescribeError: Sendable, Equatable, Hashable, Codable {
    /// Always `tool_not_found`.
    public let code: String
    /// `Tool not found: <path>`.
    public let message: String
    /// Up to five ranked candidate paths, omitted when there are none.
    public let suggestions: [String]?

    /// Assembles one not-found payload.
    public init(code: String, message: String, suggestions: [String]? = nil) {
        self.code = code
        self.message = message
        self.suggestions = suggestions
    }
}
