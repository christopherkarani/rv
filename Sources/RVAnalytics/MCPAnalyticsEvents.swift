import Foundation

// MARK: - Catalog (port of Executor `packages/core/analytics/src/events.ts`)

// PROPERTY RULES (same line the Executor catalog draws; oracle: events.ts
// header comment + `analytics.test.ts` › `integration_added { plugin_key }`):
//   - Metadata about product usage only — never secrets, tokens, credentials,
//     code, tool arguments, or tool results.
//   - Never user free text: no connection names, no tool addresses, no
//     toolkit slugs (user-entered labels — booleans/counts instead).
//   - Plugin keys (`openapi`, `mcp`, …) ARE allowed: a fixed,
//     product-defined vocabulary. Integration slugs are NOT.
//   - Identity is the anonymous per-install id only; no emails, no hostnames,
//     no person or org names.

/// Which door an execution came through. Bound structurally by the host (each
/// serving plane wraps its invoke path once), never inferred from a header or
/// flag. Oracle: events.ts › `ExecutionPlane`.
public enum MCPExecutionPlane: String, Sendable, Equatable, Codable {
    /// An agent invoking over the MCP surface.
    case mcp
    /// The HTTP executions API (CLI `call`/`resume`, the web console).
    case api
}

/// Which door an artifact operation came through. Bound at each door's
/// composition point, mirroring `MCPExecutionPlane`.
/// Oracle: events.ts › `ArtifactVia`.
public enum MCPArtifactVia: String, Sendable, Equatable, Codable {
    /// An agent calling the MCP artifact tools.
    case agent
    /// A human in the console UI.
    case ui
}

/// Which product hosts the daemon emitting the event. Always explicit at the
/// composition root — deliberately no env fallback. Oracle: analytics.ts ›
/// `AnalyticsSurface`.
public enum MCPAnalyticsSurface: String, Sendable, Equatable {
    case cli
    case desktop
    case selfhost
}

/// Release channel, matching the installation user-agent vocabulary.
/// Oracle: analytics.ts › `AnalyticsConfig.channel`.
public enum MCPAnalyticsChannel: String, Sendable, Equatable {
    case stable
    case beta
    case dev
}

/// A product-defined plugin key (`openapi`, `mcp`, `graphql`, …). The fixed
/// vocabulary the property rules allow; anything outside it — integration
/// slugs, free text, hostile bytes — fails to construct so the event is
/// dropped instead of sent. Oracle: events.ts › PROPERTY RULES.
public struct MCPPluginKey: Sendable, Equatable, Hashable {
    /// Largest key accepted, in UTF-8 bytes.
    public static let maximumBytes = 64

    /// The validated key text. Immutable: validation runs once at
    /// construction, so a key can never be edited into a slug or payload.
    public let rawValue: String

    /// Validates one candidate. Accepts lowercase ASCII letters, digits, and
    /// hyphens within the byte cap; rejects empty, overlong, and
    /// non-vocabulary text. The charset subsumes the legibility rule —
    /// controls, invisible format, and line/paragraph separators all fall
    /// outside `[a-z0-9-]`, so no second check can add rejections. Never
    /// throws: invalid means no event.
    public init?(_ rawValue: String) {
        guard rawValue.isEmpty == false,
              rawValue.utf8.count <= Self.maximumBytes,
              rawValue.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
        else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// Server-side product-analytics event catalog. Every case carries only
/// catalog-typed properties, so the property rules hold by construction.
/// Oracle: events.ts › `AnalyticsEvents`.
public enum MCPAnalyticsEvent: Sendable, Equatable {
    /// A code execution reached a terminal outcome. Recorded once per
    /// execution at completion — a paused execution is recorded when its
    /// resume completes, not when it pauses. `toolkit` marks executions
    /// served by a toolkit-scoped endpoint (the slug is deliberately absent).
    case executionCompleted(ok: Bool, plane: MCPExecutionPlane, toolkit: Bool)
    /// An integration row was created (upsert re-registers are not counted).
    case integrationAdded(pluginKey: MCPPluginKey)
    /// An integration was removed by the user.
    case integrationRemoved(pluginKey: MCPPluginKey)
    /// A generative-UI artifact was saved as a new row.
    case artifactCreated(via: MCPArtifactVia)
    /// An artifact was opened for its content. Internal reads (binding
    /// resolution inside an execution) deliberately do not count.
    case artifactViewed(via: MCPArtifactVia)
    /// An existing artifact was overwritten in place, or renamed.
    case artifactUpdated(via: MCPArtifactVia)
    /// An artifact was deleted.
    case artifactDeleted(via: MCPArtifactVia)

    /// Wire event name. Oracle: events.ts › `AnalyticsEvents` keys.
    public var name: String {
        switch self {
        case .executionCompleted:
            return "execution_completed"
        case .integrationAdded:
            return "integration_added"
        case .integrationRemoved:
            return "integration_removed"
        case .artifactCreated:
            return "artifact_created"
        case .artifactViewed:
            return "artifact_viewed"
        case .artifactUpdated:
            return "artifact_updated"
        case .artifactDeleted:
            return "artifact_deleted"
        }
    }

    /// Catalog-typed properties. Booleans, fixed-vocabulary enums, and
    /// validated plugin keys only — never free text. Oracle: events.ts ›
    /// `AnalyticsEvents` property shapes.
    public var properties: [String: AnalyticsPropertyValue] {
        switch self {
        case .executionCompleted(let ok, let plane, let toolkit):
            return [
                "ok": .bool(ok),
                "plane": .string(plane.rawValue),
                "toolkit": .bool(toolkit),
            ]
        case .integrationAdded(let key):
            return ["plugin_key": .string(key.rawValue)]
        case .integrationRemoved(let key):
            return ["plugin_key": .string(key.rawValue)]
        case .artifactCreated(let via):
            return ["via": .string(via.rawValue)]
        case .artifactViewed(let via):
            return ["via": .string(via.rawValue)]
        case .artifactUpdated(let via):
            return ["via": .string(via.rawValue)]
        case .artifactDeleted(let via):
            return ["via": .string(via.rawValue)]
        }
    }
}

// MARK: - Property rules gate

/// Runtime side of the property rules: the closed key vocabulary every
/// analytics property bag must stay inside, plus the value shape each key
/// may carry. The typed catalog cannot leave it; composition roots apply
/// this gate to fail closed on hand-built bags. Keys alone would admit a
/// secret smuggled as an allowed key's value — every value is checked too.
/// Oracle: events.ts › PROPERTY RULES.
public enum MCPAnalyticsPropertyRules: Sendable {
    /// Every key the catalog and the shared batch properties may carry.
    public static let allowedKeys: Set<String> = [
        "ok",
        "plane",
        "toolkit",
        "plugin_key",
        "via",
        "surface",
        "channel",
        "app_version",
        "$process_person_profile",
    ]

    /// Largest `app_version` value accepted, in UTF-8 bytes.
    public static let maximumVersionBytes = 64

    /// True when every entry of a raw property bag belongs to the catalog: a
    /// known key carrying a catalog-shaped value. Booleans stay booleans,
    /// closed vocabularies stay members, plugin keys re-validate, versions
    /// stay short printable ASCII, and the person-profile flag stays false —
    /// anything else fails closed. Fail-closed companion to the typed catalog.
    ///
    /// Shape, not provenance: a short printable secret still passes as an
    /// `app_version`, and a slug-shaped label still passes as a `plugin_key`.
    /// Provenance is the typed catalog's job — emission sites pass the real
    /// product version and the real plugin kind, never caller free text.
    public static func isCatalogPropertyBag(_ properties: [String: AnalyticsPropertyValue]) -> Bool {
        for (key, value) in properties {
            switch key {
            case "ok", "toolkit":
                guard case .bool = value else {
                    return false
                }
            case "$process_person_profile":
                // Anonymous events only: never materialize a person profile.
                guard case .bool(false) = value else {
                    return false
                }
            case "plane":
                guard case .string(let text) = value, MCPExecutionPlane(rawValue: text) != nil else {
                    return false
                }
            case "via":
                guard case .string(let text) = value, MCPArtifactVia(rawValue: text) != nil else {
                    return false
                }
            case "surface":
                guard case .string(let text) = value, MCPAnalyticsSurface(rawValue: text) != nil else {
                    return false
                }
            case "channel":
                guard case .string(let text) = value, MCPAnalyticsChannel(rawValue: text) != nil else {
                    return false
                }
            case "plugin_key":
                guard case .string(let text) = value, MCPPluginKey(text) != nil else {
                    return false
                }
            case "app_version":
                guard case .string(let text) = value, isVersionText(text) else {
                    return false
                }
            default:
                return false
            }
        }
        return true
    }

    /// Product versions are short printable ASCII (`1.2.3`, `0.0.0-dev`): no
    /// controls, no invisibles, nothing that breaks line-oriented logs — and
    /// nothing roomy enough to carry a dumped payload.
    private static func isVersionText(_ text: String) -> Bool {
        guard text.isEmpty == false, text.utf8.count <= maximumVersionBytes else {
            return false
        }
        return text.unicodeScalars.allSatisfy {
            $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F
        }
    }
}

// MARK: - URL redaction (port of `telemetry-url-redaction.ts`)

// A URL reduced to its exportable parts, and what was removed. Oracle:
// `telemetry-url-redaction.ts` › `RedactedUrl`.
public struct MCPRedactedURL: Sendable, Equatable {
    /// The URL with userinfo, the entire query string, and the fragment
    /// removed. Scheme, host, and path survive.
    public var url: String
    /// Removed parameter names (never values), plus the `userinfo` /
    /// `fragment` markers and `*` for a nameless query segment. Sorted.
    public var stripped: [String]

    public init(url: String, stripped: [String]) {
        self.url = url
        self.stripped = stripped
    }
}

/// URL redaction for exported telemetry. Every query parameter value is
/// dropped (names are operator-chosen free text, so no safe-name allowlist
/// can exist), every fragment is dropped, and userinfo is dropped. Only
/// scheme, host, and path survive. Oracle: `telemetry-url-redaction.ts`.
public enum MCPAnalyticsURLRedaction: Sendable {
    /// Redacts one whole-URL value. A clean URL returns unchanged (no
    /// normalization side effects); an unparseable value degrades textually
    /// — never passed through. Oracle: `redactUrlForTelemetry`.
    public static func redact(_ value: String) -> MCPRedactedURL {
        if let components = URLComponents(string: value),
           let scheme = components.scheme,
           let host = components.host
        {
            return redactParsed(value: value, components: components, scheme: scheme, host: host)
        }
        return redactUnparseable(value)
    }

    /// Free text with every embedded URL redacted. Oracle:
    /// `redactUrlsInText`.
    public static func redactURLsInText(_ text: String) -> String {
        let pattern = /[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\s"'`<>()\[\]{}]+/
        var output = ""
        var cursor = text.startIndex
        for match in text.matches(of: pattern) {
            output += text[cursor..<match.range.lowerBound]
            output += redact(String(text[match.range])).url
            cursor = match.range.upperBound
        }
        output += text[cursor...]
        return output
    }

    private static func redactParsed(
        value: String,
        components: URLComponents,
        scheme: String,
        host: String
    ) -> MCPRedactedURL {
        var stripped: [String] = []
        if components.user != nil {
            stripped.append("userinfo")
        }
        // Names come from the ENCODED query: the decoded form would split
        // encoded `&`/`=` inside values into phantom names, surfacing value
        // bytes through the stripped-keys diagnostic. Oracle:
        // `redactUrlForTelemetry` reads `url.search` (raw), not a decoding.
        if let query = components.percentEncodedQuery, query.isEmpty == false {
            stripped += queryParameterNames(query)
        }
        if let fragment = components.fragment, fragment.isEmpty == false {
            stripped.append("fragment")
        }
        guard stripped.isEmpty == false else {
            return MCPRedactedURL(url: value, stripped: [])
        }
        var suffix = ""
        if let port = components.port {
            suffix += ":\(port)"
        }
        suffix += components.percentEncodedPath
        // Normalize brackets so the rebuild carries them exactly once on any
        // platform: Darwin's parser retains them in `host`, others may not.
        let bareHost = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        let rebuilt: String
        if bareHost.contains(":") {
            rebuilt = "\(scheme)://[\(bareHost)]\(suffix)"
        } else {
            rebuilt = "\(scheme)://\(host)\(suffix)"
        }
        return MCPRedactedURL(url: rebuilt, stripped: stripped.sorted())
    }

    private static func redactUnparseable(_ value: String) -> MCPRedactedURL {
        var stripped: [String] = []
        var head = value
        if let cut = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            let tail = value[cut...]
            if tail.contains("#") {
                stripped.append("fragment")
            }
            if tail.hasPrefix("?") {
                let queryText = tail.dropFirst().prefix(while: { $0 != "#" })
                stripped += queryParameterNames(String(queryText))
            }
            head = String(value[..<cut])
        }
        // The `#` cut runs before the `@` scan so an `@` inside a fragment
        // is never misread as userinfo. Oracle: `redactUrlForTelemetry`
        // › "does not treat an @ inside the fragment as userinfo".
        if let atSign = head.lastIndex(of: "@") {
            stripped.append("userinfo")
            head = String(head[head.index(after: atSign)...])
        }
        guard head != value else {
            return MCPRedactedURL(url: value, stripped: [])
        }
        return MCPRedactedURL(url: head, stripped: stripped.sorted())
    }

    /// The parameter NAMES of a query string. A segment without `=` has no
    /// name — it may be a bare credential, so it reports as `*` rather than
    /// echoing. Oracle: `queryParameterNames`.
    private static func queryParameterNames(_ query: String) -> [String] {
        var names = Set<String>()
        for segment in query.split(separator: "&", omittingEmptySubsequences: false) {
            if segment.isEmpty {
                continue
            }
            if let equals = segment.firstIndex(of: "=") {
                names.insert(String(segment[..<equals]))
            } else {
                names.insert("*")
            }
        }
        return names.sorted()
    }
}

// MARK: - Opt-out (port of `analytics.ts` › `isAnalyticsDisabled`)

// Opt-out is the established cross-cutting convention: `DO_NOT_TRACK` or the
// feature-specific `EXECUTOR_DISABLE_ANALYTICS`. Oracle: `analytics.test.ts`
// › "honors DO_NOT_TRACK and EXECUTOR_DISABLE_ANALYTICS".
public enum MCPAnalyticsDisabled: Sendable {
    /// True when either opt-out variable carries a truthy value (`1`,
    /// `true`, or `yes`, case-insensitive, surrounding whitespace ignored).
    public static func isDisabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isTruthy(environment["DO_NOT_TRACK"]) || isTruthy(environment["EXECUTOR_DISABLE_ANALYTICS"])
    }

    /// `String.prototype.trim` parity: WhiteSpace + LineTerminator. Deliberately
    /// NOT `.whitespacesAndNewlines`: that set trims U+0085 (which JS keeps)
    /// and keeps U+FEFF (which JS trims) — the latter would ignore a
    /// BOM-prefixed opt-out the Executor honors. Oracle: `analytics.ts` ›
    /// `truthy` (`value.trim().toLowerCase()`).
    private static let trimCharacters = CharacterSet(charactersIn:
        "\u{9}\u{A}\u{B}\u{C}\u{D}\u{20}\u{A0}\u{1680}"
            + "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}"
            + "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
    )

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        switch value.trimmingCharacters(in: trimCharacters).lowercased() {
        case "1", "true", "yes":
            return true
        default:
            return false
        }
    }
}

// MARK: - Buffering (port of `analytics.ts` › `Analytics` service)

// One event inside a flushed batch: catalog name and properties plus the
// record-time stamp. Oracle: `analytics.ts` › `BufferedEvent`.
public struct MCPAnalyticsBatchEvent: Sendable, Equatable {
    public var event: String
    public var properties: [String: AnalyticsPropertyValue]
    public var timestamp: String

    public init(event: String, properties: [String: AnalyticsPropertyValue], timestamp: String) {
        self.event = event
        self.properties = properties
        self.timestamp = timestamp
    }
}

/// One delivery unit: the anonymous install id plus up to
/// `MCPAnalyticsBuffer.flushBatchSize` events. Batching mirrors
/// `analytics.ts` › `sendBatch`; the PostHog wire encoding itself belongs
/// to the existing sink behind the sender seam.
public struct MCPAnalyticsBatch: Sendable, Equatable {
    public var distinctID: String
    public var events: [MCPAnalyticsBatchEvent]

    public init(distinctID: String, events: [MCPAnalyticsBatchEvent]) {
        self.distinctID = distinctID
        self.events = events
    }
}

/// In-memory event buffer with best-effort batched delivery. Events buffer
/// in memory and flush in batches; a failed flush re-queues the batch and
/// never surfaces to the caller — analytics can never fail or slow a
/// user-facing operation. Oracle: `analytics.ts` › `layer`.
public actor MCPAnalyticsBuffer {
    /// Most events held in memory; older events drop first so a dead network
    /// cannot grow memory forever. Oracle: `analytics.ts` ›
    /// `MAX_BUFFERED_EVENTS`.
    public static let maximumBufferedEvents = 500
    /// Most events per delivery. Oracle: `analytics.ts` ›
    /// `FLUSH_BATCH_SIZE`.
    public static let flushBatchSize = 50
    /// Seconds between automatic flushes once `startCadence` runs. Oracle:
    /// `analytics.ts` › `flushInterval` default.
    public static let flushCadenceSeconds: TimeInterval = 30

    private struct PendingEvent: Sendable {
        var event: MCPAnalyticsEvent
        var timestamp: String
    }

    private var pending: [PendingEvent] = []
    private var cadenceTask: Task<Void, Never>?
    private let distinctID: String
    private let surface: MCPAnalyticsSurface
    private let channel: MCPAnalyticsChannel
    private let version: String
    private let disabled: Bool
    private let sender: @Sendable (MCPAnalyticsBatch) async -> Bool
    private let clock: @Sendable () -> Date
    private let isoFormatter = ISO8601DateFormatter()

    /// Assembles a buffer. `sender` delivers one batch and reports success;
    /// `false` re-queues the batch for the next flush. `disabled` builds the
    /// no-op shape: record and flush do nothing and never dial out. Oracle:
    /// `analytics.test.ts` › "disabled config produces a no-op service".
    public init(
        distinctID: String,
        surface: MCPAnalyticsSurface,
        channel: MCPAnalyticsChannel,
        version: String,
        disabled: Bool = false,
        sender: @escaping @Sendable (MCPAnalyticsBatch) async -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.distinctID = distinctID
        self.surface = surface
        self.channel = channel
        self.version = version
        self.disabled = disabled
        self.sender = sender
        self.clock = now
    }

    /// Assembles a buffer delivering through the existing analytics sink:
    /// each buffered event is captured as one `AnalyticsPayload`, so the
    /// PostHog wire encoding and credentials stay the sink's business. The
    /// batch succeeds only when every capture is accepted; otherwise the
    /// whole batch re-queues for the next flush — best-effort, so a
    /// delivered prefix may repeat after a partial failure, the same
    /// at-least-once shape a retried HTTP batch has.
    public init(
        distinctID: String,
        surface: MCPAnalyticsSurface,
        channel: MCPAnalyticsChannel,
        version: String,
        disabled: Bool = false,
        sink: any AnalyticsSink,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            distinctID: distinctID,
            surface: surface,
            channel: channel,
            version: version,
            disabled: disabled,
            sender: { batch in
                var accepted = true
                for event in batch.events {
                    let outcome = await sink.capture(
                        AnalyticsPayload(
                            event: event.event,
                            distinctID: batch.distinctID,
                            properties: event.properties
                        )
                    )
                    if outcome != .accepted {
                        accepted = false
                    }
                }
                return accepted
            },
            now: now
        )
    }

    /// Events currently awaiting delivery.
    public var pendingCount: Int {
        pending.count
    }

    /// Buffers one event for best-effort batched delivery. Never fails.
    /// Oracle: `analytics.ts` › `AnalyticsService.record`.
    public func record(_ event: MCPAnalyticsEvent) {
        guard disabled == false else {
            return
        }
        pending.append(PendingEvent(event: event, timestamp: isoFormatter.string(from: clock())))
        if pending.count > Self.maximumBufferedEvents {
            pending.removeFirst(pending.count - Self.maximumBufferedEvents)
        }
    }

    /// Drains the buffer now. On delivery failure the batch goes back to the
    /// front and draining stops — the endpoint is unreachable, later batches
    /// would fail the same way. Never fails. Oracle: `analytics.ts` ›
    /// `flush` + "re-queues the batch when delivery fails".
    public func flush() async {
        guard disabled == false else {
            return
        }
        while pending.isEmpty == false {
            let batchEvents = Array(pending.prefix(Self.flushBatchSize))
            pending.removeFirst(batchEvents.count)
            let delivered = await sender(makeBatch(batchEvents))
            if delivered == false {
                pending.insert(contentsOf: batchEvents, at: 0)
                return
            }
        }
    }

    /// Starts automatic flushing on a fixed cadence. Oracle: `analytics.ts` ›
    /// `Schedule.spaced(flushInterval)`. Idempotent: restarting replaces the
    /// previous schedule. The loop ends when `stopCadence` runs or the buffer
    /// deallocates; a flush already in flight always runs to completion.
    public func startCadence(every interval: TimeInterval = flushCadenceSeconds) {
        stopCadence()
        guard interval > 0 else {
            return
        }
        cadenceTask = Task { [weak self] in
            while let self {
                // Clamped: a huge interval sleeps long, never traps the
                // `UInt64` conversion; a tiny one still yields the executor.
                let nanoseconds = UInt64(Swift.min(Swift.max(interval, 0.001), 86_400) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                if Task.isCancelled {
                    break
                }
                await self.flush()
            }
        }
    }

    /// Stops automatic flushing. A flush already in flight runs to completion.
    public func stopCadence() {
        cadenceTask?.cancel()
        cadenceTask = nil
    }

    /// Stops the cadence and drains the buffer: the shutdown finalizer.
    /// Oracle: `analytics.ts` › `Effect.addFinalizer(() => flush)`.
    public func shutdown() async {
        stopCadence()
        await flush()
    }

    private func makeBatch(_ events: [PendingEvent]) -> MCPAnalyticsBatch {
        MCPAnalyticsBatch(
            distinctID: distinctID,
            events: events.map { entry in
                var properties = entry.event.properties
                // Anonymous events only: never materialize a person profile.
                properties["$process_person_profile"] = .bool(false)
                properties["surface"] = .string(surface.rawValue)
                properties["channel"] = .string(channel.rawValue)
                properties["app_version"] = .string(version)
                return MCPAnalyticsBatchEvent(
                    event: entry.event.name,
                    properties: properties,
                    timestamp: entry.timestamp
                )
            }
        )
    }
}

// MARK: - Invoke-path wrapper (port of `engine.ts` › `withExecutionAnalytics`)

// Labels bound structurally at the wrap point — the wrap point IS the plane,
// so misattribution is impossible the way it would be with a header or flag.
// Oracle: `engine.ts` › `ExecutionAnalyticsContext`.
public struct MCPExecutionContext: Sendable, Equatable {
    public let plane: MCPExecutionPlane
    /// Whether this invoke path serves a toolkit-scoped endpoint.
    public let toolkit: Bool

    public init(plane: MCPExecutionPlane, toolkit: Bool) {
        self.plane = plane
        self.toolkit = toolkit
    }
}

/// One invoke-path outcome. Only `.completed` is terminal; a pause records
/// when its resume completes, so approve-then-complete counts once. Oracle:
/// `engine.ts` header comment › outcome semantics.
public enum MCPInvokeTerminalOutcome: Sendable, Equatable {
    /// The invocation finished; `ok` is false for tool-level and
    /// infrastructure-level failures alike.
    case completed(ok: Bool)
    /// The invocation paused for elicitation or approval. Not terminal.
    case paused
}

/// Records one `execution_completed` per terminal invoke-path outcome. The
/// RV counterpart of Executor's `withExecutionAnalytics` engine decorator,
/// generic over invoke closures so the analytics layer stays free of the
/// isolation layer. Oracle: `engine.ts` › `withExecutionAnalytics`.
public struct MCPAnalyticsInvokeWrapper: Sendable {
    public let context: MCPExecutionContext
    public let recorder: @Sendable (MCPAnalyticsEvent) async -> Void

    public init(
        context: MCPExecutionContext,
        recorder: @escaping @Sendable (MCPAnalyticsEvent) async -> Void
    ) {
        self.context = context
        self.recorder = recorder
    }

    /// Runs a single-shot invoke, recording its terminal outcome. A returned
    /// value records `ok` from `succeeded`; a thrown error records not-ok
    /// and rethrows the original error. Cancellation is not an outcome and
    /// rethrows unrecorded. Oracle: `engine.test.ts` › "records ok on a
    /// completed execution" + "records not-ok when the engine fails on the
    /// error channel".
    public func recordCall<T>(
        operation: () async throws -> T,
        succeeded: @Sendable (T) -> Bool
    ) async throws -> T {
        do {
            let value = try await operation()
            await completed(ok: succeeded(value))
            return value
        } catch let error as CancellationError {
            // Mirrors Effect's `tapError`, which does not fire on
            // interruption: a cancelled invoke observed no outcome.
            throw error
        } catch {
            await completed(ok: false)
            throw error
        }
    }

    /// Runs a resumable invoke, recording terminal completions once. Pauses
    /// record nothing; an unknown execution (`nil`, e.g. resume-of-unknown)
    /// records nothing; a thrown error records not-ok and rethrows.
    /// Cancellation rethrows unrecorded. Oracle: `engine.test.ts` › "does
    /// not record a pause; records when the resume completes" + "resume of
    /// an unknown execution records nothing".
    ///
    /// The `.paused` arm is unreachable via `ScopedInvoker.invoke`, which
    /// parks elicitation internally until terminal: no wave-1 path yields
    /// `.paused` here. Wave-2 serving chooses the shape — block the caller
    /// up to the elicitation TTL (then `recordCall` suffices and this API
    /// stays pause-free), or add a non-blocking invoke whose pauses flow
    /// through this arm — and records its choice here.
    public func recordResumable(
        operation: () async throws -> MCPInvokeTerminalOutcome?
    ) async throws -> MCPInvokeTerminalOutcome? {
        do {
            let outcome = try await operation()
            switch outcome {
            case .completed(let ok):
                await completed(ok: ok)
            case .paused:
                break
            case .none:
                break
            }
            return outcome
        } catch let error as CancellationError {
            throw error
        } catch {
            await completed(ok: false)
            throw error
        }
    }

    private func completed(ok: Bool) async {
        await recorder(
            .executionCompleted(ok: ok, plane: context.plane, toolkit: context.toolkit)
        )
    }
}
