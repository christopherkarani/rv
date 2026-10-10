import Foundation

/// Canonical host wire vocabulary: one table per host for the tool and
/// hook-event spellings matched by the 9 hook codecs (strict) and the 8
/// scan adapters (loose), plus the shared fallback-chain helper.
///
/// Each host's known spellings are exhaustive cases; anything else parses
/// to `other(String)`, which carries the raw spelling without ever
/// matching. Parsing is total and policy-independent: a spelling known to
/// either side keeps its case under both policies, so strict-vs-loose
/// differences read as explicit per-case tables (`strictMatch` /
/// `looseMatch`), never as coincidental literals.
///
/// Scope boundary (T3a; T3b/T3c adopt without redesigning):
/// - Covered: shell tool spellings, file tool spellings, hook-event
///   spellings, and order-contract key-probe lists (session / timestamp /
///   recurse / nested-container / working-directory).
/// - NOT covered: codec `CodingKeys` (frozen by CON-001, stay in the
///   envelopes), adapter-internal record navigation (single-key lookups,
///   `type` / `role` discriminators, binary `??` key fallbacks, SQL, layout
///   paths) — each appears once, so tabling it would duplicate, not dedupe.
/// - File aliases (`Read` / `read_file` / …) stay canonical in
///   `FileToolKind`; host tool enums delegate to it instead of re-listing
///   the six spellings. Only Antigravity's native file names
///   (`view_file` / …) are tabled here — they appear nowhere else.
/// - Missing-field flow (`nil` event, empty-string command chains) stays
///   in the consumers; only the spellings move down.

/// Which side's matching semantics apply to a vocabulary table.
///
/// - `strict`: hook-codec matching — exact wire spellings only.
/// - `loose`: scan-adapter matching — legacy spellings and dual keys.
/// The two policies are explicit tables over the same per-host cases.
public enum HostWirePolicy: Sendable, Equatable, Hashable {
    case strict
    case loose
}

/// How a parsed tool name classifies under a policy.
public enum HostToolMatch: Sendable, Equatable, Hashable {
    /// Admitted as a shell-tool invocation.
    case shell
    /// A file-tool invocation of this closed kind.
    case file(FileToolKind)
    /// Not a shell or file invocation for this host.
    case foreign
}

/// First non-empty value in order, or nil when all are nil or empty.
///
/// Shared by the hook codecs (one copy replaces the nine private copies).
/// Whitespace-only strings COUNT as non-empty — this is deliberately
/// narrower than `FileToolPath.firstPresent`, which trims whitespace.
public func firstNonEmpty(_ values: String?...) -> String? {
    firstNonEmpty(values)
}

/// Array form of `firstNonEmpty(_:)`, for computed candidate lists.
public func firstNonEmpty(_ values: [String?]) -> String? {
    for value in values {
        if let value, value.isEmpty == false {
            return value
        }
    }
    return nil
}

// MARK: - Grok

/// Grok tool-name vocabulary (codec `toolName` + adapter `tool_calls[].name`).
///
/// Strict and loose admit the same shell set. File tools are the shared
/// `FileToolKind` aliases, delegated — never re-listed — in the parser.
public enum GrokToolName: Sendable, Equatable, Hashable, Codable {
    /// `run_terminal_command`: strict + loose shell.
    case runTerminalCommand
    /// `run_terminal_cmd`: strict + loose shell.
    case runTerminalCmd
    /// `Bash`: strict + loose shell.
    case bash
    /// A shared file-tool alias; canonical spelling in `FileToolKind`.
    case file(FileToolKind)
    /// Unknown spelling, carried verbatim. Never matches.
    case other(String)

    /// Total parse: known spellings map to cases, all else is carried.
    public init(wireValue: String) {
        switch wireValue {
        case "run_terminal_command":
            self = .runTerminalCommand
        case "run_terminal_cmd":
            self = .runTerminalCmd
        case "Bash":
            self = .bash
        default:
            if let kind = FileToolKind(toolName: wireValue) {
                self = .file(kind)
            } else {
                self = .other(wireValue)
            }
        }
    }

    /// Nil-preserving parse: a missing tool field stays missing (foreign flow).
    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    /// Exact wire spelling; `.file` canonicalizes to the ledger name
    /// (`Read` / `Edit` / `Write`).
    public var wireValue: String {
        switch self {
        case .runTerminalCommand:
            "run_terminal_command"
        case .runTerminalCmd:
            "run_terminal_cmd"
        case .bash:
            "Bash"
        case .file(let kind):
            kind.ledgerName
        case .other(let raw):
            raw
        }
    }

    /// Strict-policy table (hook codec).
    public var strictMatch: HostToolMatch {
        switch self {
        case .runTerminalCommand, .runTerminalCmd, .bash:
            .shell
        case .file(let kind):
            .file(kind)
        case .other:
            .foreign
        }
    }

    /// Loose-policy table (scan adapter).
    public var looseMatch: HostToolMatch {
        switch self {
        case .runTerminalCommand, .runTerminalCmd, .bash:
            .shell
        case .file(let kind):
            .file(kind)
        case .other:
            .foreign
        }
    }

    /// Classifies this tool name under `policy`.
    public func match(policy: HostWirePolicy) -> HostToolMatch {
        switch policy {
        case .strict:
            strictMatch
        case .loose:
            looseMatch
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// Grok hook-event vocabulary (`hookEventName`, camelCase envelope).
public enum GrokEventName: Sendable, Equatable, Hashable, Codable {
    /// `pre_tool_use`: the only admitted event.
    case preToolUse
    /// Unknown spelling, carried verbatim. Never matches.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "pre_tool_use":
            self = .preToolUse
        default:
            self = .other(wireValue)
        }
    }

    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    public var wireValue: String {
        switch self {
        case .preToolUse:
            "pre_tool_use"
        case .other(let raw):
            raw
        }
    }

    public var strictMatch: Bool {
        switch self {
        case .preToolUse:
            true
        case .other:
            false
        }
    }

    public var looseMatch: Bool {
        switch self {
        case .preToolUse:
            true
        case .other:
            false
        }
    }

    public func match(policy: HostWirePolicy) -> Bool {
        switch policy {
        case .strict:
            strictMatch
        case .loose:
            looseMatch
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - Pi

/// Pi tool-name vocabulary (codec `toolName` + adapter `toolCall` name).
///
/// Single spelling; strict and loose agree. No event gate, no file tools.
public enum PiToolName: Sendable, Equatable, Hashable, Codable {
    /// `bash`: strict + loose shell.
    case bash
    /// Unknown spelling, carried verbatim. Never matches.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "bash":
            self = .bash
        default:
            self = .other(wireValue)
        }
    }

    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    public var wireValue: String {
        switch self {
        case .bash:
            "bash"
        case .other(let raw):
            raw
        }
    }

    public var strictMatch: HostToolMatch {
        switch self {
        case .bash:
            .shell
        case .other:
            .foreign
        }
    }

    public var looseMatch: HostToolMatch {
        switch self {
        case .bash:
            .shell
        case .other:
            .foreign
        }
    }

    public func match(policy: HostWirePolicy) -> HostToolMatch {
        switch policy {
        case .strict:
            strictMatch
        case .loose:
            looseMatch
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - OpenCode

/// OpenCode tool-name vocabulary (codec `tool` + adapter `part.tool`).
///
/// Note the reversed policy direction: strict admits the TUI door
/// `session.shell`, while the loose store adapter only ever sees `bash`.
/// No event gate, no file tools.
public enum OpenCodeToolName: Sendable, Equatable, Hashable, Codable {
    /// `bash`: strict + loose shell.
    case bash
    /// `session.shell`: strict-only shell (same shell door, TUI id).
    case sessionShell
    /// Unknown spelling, carried verbatim. Never matches.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "bash":
            self = .bash
        case "session.shell":
            self = .sessionShell
        default:
            self = .other(wireValue)
        }
    }

    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    public var wireValue: String {
        switch self {
        case .bash:
            "bash"
        case .sessionShell:
            "session.shell"
        case .other(let raw):
            raw
        }
    }

    public var strictMatch: HostToolMatch {
        switch self {
        case .bash, .sessionShell:
            .shell
        case .other:
            .foreign
        }
    }

    public var looseMatch: HostToolMatch {
        switch self {
        case .bash:
            .shell
        case .sessionShell, .other:
            .foreign
        }
    }

    public func match(policy: HostWirePolicy) -> HostToolMatch {
        switch policy {
        case .strict:
            strictMatch
        case .loose:
            looseMatch
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - Claude

/// Claude tool-name vocabulary (codec `tool_name` + adapter block `name`).
///
/// Strict admits only `Bash` as shell; loose also admits the legacy
/// lowercase / capitalized variants. File tools are the shared
/// `FileToolKind` aliases, delegated — never re-listed — in the parser.
public enum ClaudeToolName: Sendable, Equatable, Hashable, Codable {
    /// `Bash`: strict + loose shell.
    case bash
    /// `bash`: loose-only shell (legacy spelling).
    case bashLowercase
    /// `Shell`: loose-only shell (legacy spelling).
    case shell
    /// `shell`: loose-only shell (legacy spelling).
    case shellLowercase
    /// A shared file-tool alias; canonical spelling in `FileToolKind`.
    case file(FileToolKind)
    /// Unknown spelling, carried verbatim. Never matches.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "Bash":
            self = .bash
        case "bash":
            self = .bashLowercase
        case "Shell":
            self = .shell
        case "shell":
            self = .shellLowercase
        default:
            if let kind = FileToolKind(toolName: wireValue) {
                self = .file(kind)
            } else {
                self = .other(wireValue)
            }
        }
    }

    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    /// Exact wire spelling; `.file` canonicalizes to the ledger name.
    public var wireValue: String {
        switch self {
        case .bash:
            "Bash"
        case .bashLowercase:
            "bash"
        case .shell:
            "Shell"
        case .shellLowercase:
            "shell"
        case .file(let kind):
            kind.ledgerName
        case .other(let raw):
            raw
        }
    }

    public var strictMatch: HostToolMatch {
        switch self {
        case .bash:
            .shell
        case .file(let kind):
            .file(kind)
        case .bashLowercase, .shell, .shellLowercase, .other:
            .foreign
        }
    }

    public var looseMatch: HostToolMatch {
        switch self {
        case .bash, .bashLowercase, .shell, .shellLowercase:
            .shell
        case .file(let kind):
            .file(kind)
        case .other:
            .foreign
        }
    }

    public func match(policy: HostWirePolicy) -> HostToolMatch {
        switch policy {
        case .strict:
            strictMatch
        case .loose:
            looseMatch
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// Claude hook-event vocabulary (`hook_event_name`).
public enum ClaudeEventName: Sendable, Equatable, Hashable, Codable {
    /// `PreToolUse`: the only admitted event.
    case preToolUse
    /// Unknown spelling, carried verbatim. Never matches.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "PreToolUse":
            self = .preToolUse
        default:
            self = .other(wireValue)
        }
    }

    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    public var wireValue: String {
        switch self {
        case .preToolUse:
            "PreToolUse"
        case .other(let raw):
            raw
        }
    }

    public var strictMatch: Bool {
        switch self {
        case .preToolUse:
            true
        case .other:
            false
        }
    }

    public var looseMatch: Bool {
        switch self {
        case .preToolUse:
            true
        case .other:
            false
        }
    }

    public func match(policy: HostWirePolicy) -> Bool {
        switch policy {
        case .strict:
            strictMatch
        case .loose:
            looseMatch
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - OpenClaw

/// OpenClaw tool-name vocabulary (codec `toolName` + adapter `name`).
///
/// Single spelling; strict and loose agree. No event gate, no file tools.
/// The `code_mode_exec` exclusion reads `OpenClawToolKind`, below.
public enum OpenClawToolName: Sendable, Equatable, Hashable, Codable {
    /// `exec`: strict + loose shell.
    case exec
    /// Unknown spelling, carried verbatim. Never matches.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "exec":
            self = .exec
        default:
            self = .other(wireValue)
        }
    }

    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    public var wireValue: String {
        switch self {
        case .exec:
            "exec"
        case .other(let raw):
            raw
        }
    }

    public var strictMatch: HostToolMatch {
        switch self {
        case .exec:
            .shell
        case .other:
            .foreign
        }
    }

    public var looseMatch: HostToolMatch {
        switch self {
        case .exec:
            .shell
        case .other:
            .foreign
        }
    }

    public func match(policy: HostWirePolicy) -> HostToolMatch {
        switch policy {
        case .strict:
            strictMatch
        case .loose:
            looseMatch
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// OpenClaw `toolKind` discriminator vocabulary (codec-only concept).
///
/// `code_mode_exec` is a strict-side exclusion: the codec returns foreign
/// before tool matching. No policies — adapters never read this field.
public enum OpenClawToolKind: Sendable, Equatable, Hashable, Codable {
    /// `code_mode_exec`: excluded from shell decoding (foreign).
    case codeModeExec
    /// Any other kind, carried verbatim.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "code_mode_exec":
            self = .codeModeExec
        default:
            self = .other(wireValue)
        }
    }

    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    public var wireValue: String {
        switch self {
        case .codeModeExec:
            "code_mode_exec"
        case .other(let raw):
            raw
        }
    }

    /// True only for the excluded `code_mode_exec` kind.
    public var isExcludedCodeMode: Bool {
        switch self {
        case .codeModeExec:
            true
        case .other:
            false
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - Hermes

/// Hermes tool-name vocabulary (codec `toolName` + adapter `name`).
///
/// Single spelling; strict and loose agree. No event gate, no file tools.
public enum HermesToolName: Sendable, Equatable, Hashable, Codable {
    /// `terminal`: strict + loose shell.
    case terminal
    /// Unknown spelling, carried verbatim. Never matches.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "terminal":
            self = .terminal
        default:
            self = .other(wireValue)
        }
    }

    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    public var wireValue: String {
        switch self {
        case .terminal:
            "terminal"
        case .other(let raw):
            raw
        }
    }

    public var strictMatch: HostToolMatch {
        switch self {
        case .terminal:
            .shell
        case .other:
            .foreign
        }
    }

    public var looseMatch: HostToolMatch {
        switch self {
        case .terminal:
            .shell
        case .other:
            .foreign
        }
    }

    public func match(policy: HostWirePolicy) -> HostToolMatch {
        switch policy {
        case .strict:
            strictMatch
        case .loose:
            looseMatch
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - Codex

/// Codex tool-name vocabulary (codec `tool_name` + adapter tool names).
///
/// Strict admits only `Bash`; loose also admits the lowercase / generic
/// spellings seen in rollout stores. No file tools.
public enum CodexToolName: Sendable, Equatable, Hashable, Codable {
    /// `Bash`: strict + loose shell.
    case bash
    /// `bash`: loose-only shell (legacy spelling).
    case bashLowercase
    /// `shell`: loose-only shell (generic spelling).
    case shell
    /// `local_shell`: loose-only shell (rollout spelling).
    case localShell
    /// Unknown spelling, carried verbatim. Never matches.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "Bash":
            self = .bash
        case "bash":
            self = .bashLowercase
        case "shell":
            self = .shell
        case "local_shell":
            self = .localShell
        default:
            self = .other(wireValue)
        }
    }

    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    public var wireValue: String {
        switch self {
        case .bash:
            "Bash"
        case .bashLowercase:
            "bash"
        case .shell:
            "shell"
        case .localShell:
            "local_shell"
        case .other(let raw):
            raw
        }
    }

    public var strictMatch: HostToolMatch {
        switch self {
        case .bash:
            .shell
        case .bashLowercase, .shell, .localShell, .other:
            .foreign
        }
    }

    public var looseMatch: HostToolMatch {
        switch self {
        case .bash, .bashLowercase, .shell, .localShell:
            .shell
        case .other:
            .foreign
        }
    }

    public func match(policy: HostWirePolicy) -> HostToolMatch {
        switch policy {
        case .strict:
            strictMatch
        case .loose:
            looseMatch
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// Codex hook-event vocabulary (`hook_event_name`).
///
/// Both policies admit `PreToolUse`; the loose side additionally tolerates
/// a missing event, which is adapter flow — not a spelling — and stays put.
public enum CodexEventName: Sendable, Equatable, Hashable, Codable {
    /// `PreToolUse`: the only admitted event.
    case preToolUse
    /// Unknown spelling, carried verbatim. Never matches.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "PreToolUse":
            self = .preToolUse
        default:
            self = .other(wireValue)
        }
    }

    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    public var wireValue: String {
        switch self {
        case .preToolUse:
            "PreToolUse"
        case .other(let raw):
            raw
        }
    }

    public var strictMatch: Bool {
        switch self {
        case .preToolUse:
            true
        case .other:
            false
        }
    }

    public var looseMatch: Bool {
        switch self {
        case .preToolUse:
            true
        case .other:
            false
        }
    }

    public func match(policy: HostWirePolicy) -> Bool {
        switch policy {
        case .strict:
            strictMatch
        case .loose:
            looseMatch
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - Cursor

/// Cursor tool-name vocabulary (codec `tool_name` + adapter tool names).
///
/// Strict admits `Shell` / `Bash` (under `preToolUse`); loose also admits
/// the lowercase variants. File tools are the shared `FileToolKind`
/// aliases, delegated — never re-listed — in the parser.
public enum CursorToolName: Sendable, Equatable, Hashable, Codable {
    /// `Shell`: strict + loose shell.
    case shell
    /// `Bash`: strict + loose shell.
    case bash
    /// `shell`: loose-only shell (legacy spelling).
    case shellLowercase
    /// `bash`: loose-only shell (legacy spelling).
    case bashLowercase
    /// A shared file-tool alias; canonical spelling in `FileToolKind`.
    case file(FileToolKind)
    /// Unknown spelling, carried verbatim. Never matches.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "Shell":
            self = .shell
        case "Bash":
            self = .bash
        case "shell":
            self = .shellLowercase
        case "bash":
            self = .bashLowercase
        default:
            if let kind = FileToolKind(toolName: wireValue) {
                self = .file(kind)
            } else {
                self = .other(wireValue)
            }
        }
    }

    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    /// Exact wire spelling; `.file` canonicalizes to the ledger name.
    public var wireValue: String {
        switch self {
        case .shell:
            "Shell"
        case .bash:
            "Bash"
        case .shellLowercase:
            "shell"
        case .bashLowercase:
            "bash"
        case .file(let kind):
            kind.ledgerName
        case .other(let raw):
            raw
        }
    }

    public var strictMatch: HostToolMatch {
        switch self {
        case .shell, .bash:
            .shell
        case .file(let kind):
            .file(kind)
        case .shellLowercase, .bashLowercase, .other:
            .foreign
        }
    }

    public var looseMatch: HostToolMatch {
        switch self {
        case .shell, .bash, .shellLowercase, .bashLowercase:
            .shell
        case .file(let kind):
            .file(kind)
        case .other:
            .foreign
        }
    }

    public func match(policy: HostWirePolicy) -> HostToolMatch {
        switch policy {
        case .strict:
            strictMatch
        case .loose:
            looseMatch
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// Cursor hook-event vocabulary (`hook_event_name`).
///
/// The empty / missing event (shell by default) is consumer flow, not a
/// spelling: it stays in the codec and adapter. `PreToolUse` (capitalized)
/// appears only on the loose side.
public enum CursorEventName: Sendable, Equatable, Hashable, Codable {
    /// `beforeShellExecution`: strict + loose shell event.
    case beforeShellExecution
    /// `preToolUse`: strict + loose tool-dispatch event.
    case preToolUse
    /// `PreToolUse`: loose-only spelling (capitalized variant).
    case preToolUseCapitalized
    /// Unknown spelling, carried verbatim. Never matches.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "beforeShellExecution":
            self = .beforeShellExecution
        case "preToolUse":
            self = .preToolUse
        case "PreToolUse":
            self = .preToolUseCapitalized
        default:
            self = .other(wireValue)
        }
    }

    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    public var wireValue: String {
        switch self {
        case .beforeShellExecution:
            "beforeShellExecution"
        case .preToolUse:
            "preToolUse"
        case .preToolUseCapitalized:
            "PreToolUse"
        case .other(let raw):
            raw
        }
    }

    public var strictMatch: Bool {
        switch self {
        case .beforeShellExecution, .preToolUse:
            true
        case .preToolUseCapitalized, .other:
            false
        }
    }

    public var looseMatch: Bool {
        switch self {
        case .beforeShellExecution, .preToolUse, .preToolUseCapitalized:
            true
        case .other:
            false
        }
    }

    public func match(policy: HostWirePolicy) -> Bool {
        switch policy {
        case .strict:
            strictMatch
        case .loose:
            looseMatch
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - Antigravity

/// Antigravity tool-name vocabulary (codec `toolCall.name`; no scan adapter).
///
/// Native file-tool names map onto the closed `FileToolKind` ledger kinds,
/// replacing the codec's private mapping. Both policies agree — there is
/// no loose-side store to diverge. No event field on this wire.
public enum AntigravityToolName: Sendable, Equatable, Hashable, Codable {
    /// `run_command`: strict + loose shell.
    case runCommand
    /// `view_file`: file tool, reads as `FileToolKind.read`.
    case viewFile
    /// `replace_file_content`: file tool, reads as `FileToolKind.edit`.
    case replaceFileContent
    /// `multi_replace_file_content`: file tool, reads as `FileToolKind.edit`.
    case multiReplaceFileContent
    /// `write_to_file`: file tool, reads as `FileToolKind.write`.
    case writeToFile
    /// Unknown spelling, carried verbatim. Never matches.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "run_command":
            self = .runCommand
        case "view_file":
            self = .viewFile
        case "replace_file_content":
            self = .replaceFileContent
        case "multi_replace_file_content":
            self = .multiReplaceFileContent
        case "write_to_file":
            self = .writeToFile
        default:
            self = .other(wireValue)
        }
    }

    public init?(wireValue: String?) {
        guard let wireValue else { return nil }
        self.init(wireValue: wireValue)
    }

    public var wireValue: String {
        switch self {
        case .runCommand:
            "run_command"
        case .viewFile:
            "view_file"
        case .replaceFileContent:
            "replace_file_content"
        case .multiReplaceFileContent:
            "multi_replace_file_content"
        case .writeToFile:
            "write_to_file"
        case .other(let raw):
            raw
        }
    }

    /// The closed file kind for file-tool cases, nil otherwise.
    public var fileKind: FileToolKind? {
        switch self {
        case .viewFile:
            .read
        case .replaceFileContent, .multiReplaceFileContent:
            .edit
        case .writeToFile:
            .write
        case .runCommand, .other:
            nil
        }
    }

    public var strictMatch: HostToolMatch {
        switch self {
        case .runCommand:
            .shell
        case .viewFile:
            .file(.read)
        case .replaceFileContent, .multiReplaceFileContent:
            .file(.edit)
        case .writeToFile:
            .file(.write)
        case .other:
            .foreign
        }
    }

    public var looseMatch: HostToolMatch {
        switch self {
        case .runCommand:
            .shell
        case .viewFile:
            .file(.read)
        case .replaceFileContent, .multiReplaceFileContent:
            .file(.edit)
        case .writeToFile:
            .file(.write)
        case .other:
            .foreign
        }
    }

    public func match(policy: HostWirePolicy) -> HostToolMatch {
        switch policy {
        case .strict:
            strictMatch
        case .loose:
            looseMatch
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: - Key-spelling probe lists

/// Shared loose-side key tables from `SessionStoreAdapter`.
///
/// Order is behavior: the first present key wins. Codec `CodingKeys` are
/// NOT duplicated here — they are frozen wire keys that stay in the
/// envelopes. Single-key inline lookups also stay in the adapters; only
/// order-contract probe lists are tabled.
public enum HostWireKeys {
    /// Nested-command container probe order (`fromEnvelope`).
    public static let nestedContainerKeys = [
        "params", "args", "toolInput", "tool_input", "input",
        "arguments", "state", "payload", "function",
    ]

    /// Working-directory field probe order (`fromFields`).
    public static let workingDirectoryKeys = [
        "cwd", "workdir", "workingDirectory", "working_directory",
    ]
}

/// Codex loose-side probe lists (from the Codex JSONL profile).
public enum CodexWireKeys {
    /// Session lookup order.
    public static let sessionKeys = ["session_id", "sessionId"]
    /// Sub-objects descended into for session lookup.
    public static let recurseSessionKeys = ["payload"]
    /// Timestamp lookup order (coercion stays in `ScanTimestamp`).
    public static let timestampKeys = ["timestamp", "ts"]
}

/// Cursor loose-side probe lists (from the Cursor JSONL profile).
public enum CursorWireKeys {
    /// Session lookup order.
    public static let sessionKeys = ["conversation_id", "session_id", "sessionId"]
    /// Timestamp lookup order (coercion stays in `ScanTimestamp`).
    public static let timestampKeys = ["timestamp", "ts"]
}

/// Claude loose-side probe lists (from the Claude session adapter).
public enum ClaudeWireKeys {
    /// Session lookup order.
    public static let sessionKeys = ["sessionId"]
}
