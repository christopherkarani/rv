/// rv's one vocabulary table: every top-level command, verdict word and
/// glyph rv shows a person or an agent. Help, hook deny text and the docs
/// take their words from here, and the tests check that no help page or doc
/// names a command this table does not, so a rename is one edit here plus
/// an alias.
///
/// It lives in `RVDomain`, not `RVCLI` or `RVPresentation`, because hook
/// deny text (`RVHooks`) depends only on `RVDomain`: this is the lowest
/// module every reader already imports, so no reader needs a new edge. It
/// is plain data with no behavior.
public enum CommandVocabulary {
    /// The program name a person types.
    public static let program = "rv"

    /// Every top-level command `rv` accepts today, plus `help`. The raw
    /// value is the spelling. The parser's subcommand list and this enum
    /// must name the same commands (`CommandVocabularyParityTests`).
    public enum Command: String, CaseIterable, Sendable {
        case run
        case opencode
        case workspace
        case test
        case explain
        case packs
        case policy
        case scan
        case service
        case hook
        case setup
        case initialize = "init"
        case uninstall
        case doctor
        case allowOnce = "allow-once"
        case allowlist
        case egress
        case safety
        case blocks
        case host
        case audit
        case secrets
        case login
        case mcp
        case managed
        case report
        case `operator`
        /// `rv help [<command>]`, answered before the parser runs.
        case help

        /// What a person types: `rv allow-once`.
        public var invocation: String {
            "\(CommandVocabulary.program) \(rawValue)"
        }
    }

    /// Verdict words rv prints today, lowercase. Callers change case
    /// (`DENY`, `BLOCKED`) where their surface needs it.
    public enum Verdict {
        /// The policy verdict that lets a command run.
        public static let allow = "allow"
        /// The policy verdict that stops a command.
        public static let deny = "deny"
        /// The policy verdict that waits for a human.
        public static let ask = "ask"
        /// rv could not finish evaluating (`Decision.indeterminate`).
        public static let incomplete = "incomplete"
        /// `rv test` result for an allow.
        public static let allowed = "allowed"
        /// `rv test` result for a deny.
        public static let blocked = "blocked"
    }

    /// The six glyphs every rv screen is built from (North Star v2,
    /// "The language"). Not printed yet; new screens take them from here.
    ///
    /// Q1 is still open on `⏺`: v2 uses it for an agent's words, the v5c
    /// rv term cut for an ask. It means an agent until Q1 settles.
    public enum Glyph: String, CaseIterable, Sendable {
        /// rv speaking; headers.
        case rv = "◆"
        /// Blocked; the command really did not run.
        case stopped = "✕"
        /// Would stop, ran anyway (watch / observe mode).
        case watched = "◐"
        /// Success, healthy.
        case done = "✓"
        /// The one command to type next.
        case next = "→"
        /// An agent's words, labelled.
        case agent = "⏺"

        /// The word printed beside the glyph.
        public var word: String {
            switch self {
            case .rv: "rv"
            case .stopped: "Stopped"
            case .watched: "Watched"
            case .done: "Done"
            case .next: "Next"
            case .agent: "Agent"
            }
        }
    }

    /// A name rv will accept later as an alias of a command it has today.
    /// Data only: nothing parses these yet (A3 adds them, A4 flips them to
    /// primary, and the old spelling stays a permanent alias).
    public struct PlannedName: Equatable, Sendable {
        public enum Status: Equatable, Sendable {
            /// Chris chose it.
            case decided(by: String, on: String)
            /// The build plan's Q1 recommendation, not yet decided.
            case recommended
        }

        /// The new spelling, placeholders in angle brackets.
        public let spelling: String
        /// The spelling that does it today, or `nil` when no one command does.
        public let today: String?
        public let status: Status

        public init(spelling: String, today: String?, status: Status) {
            self.spelling = spelling
            self.today = today
            self.status = status
        }
    }

    /// Planned names from the North Star build plan, "Decisions for Chris" Q1.
    public static let plannedNames: [PlannedName] = [
        PlannedName(
            spelling: "rv protect <tool>", today: "rv packs enable <pack>",
            status: .decided(by: "Chris", on: "2026-11-22")
        ),
        PlannedName(
            spelling: "rv protect <tool> off", today: "rv packs disable <pack>",
            status: .decided(by: "Chris", on: "2026-11-22")
        ),
        PlannedName(spelling: "rv why", today: "rv explain", status: .recommended),
        PlannedName(spelling: "rv log", today: "rv blocks", status: .recommended),
        PlannedName(spelling: "rv unlock", today: "rv allow-once", status: .recommended),
        PlannedName(spelling: "rv guard <host>", today: "rv host mode <host> block", status: .recommended),
        PlannedName(spelling: "rv watch <host>", today: "rv host mode <host> observe", status: .recommended),
        PlannedName(spelling: "rv secrets add", today: "rv secrets set", status: .recommended),
        PlannedName(spelling: "rv keys forget <name>", today: "rv secrets remove <name>", status: .recommended),
        PlannedName(spelling: "rv rules forget <n>", today: nil, status: .recommended),
        PlannedName(spelling: "rv mcp forget <server>", today: nil, status: .recommended),
    ]

    /// Mode and event words from the v5c rv term cut that Q1 lists as
    /// chosen. Not printed yet.
    public enum PlannedWord {
        /// Host mode `block`, as a state.
        public static let guarding = "guarding"
        /// Host mode `observe`, as a state.
        public static let watching = "watching"
        /// `✓ ran`: the command ran.
        public static let ran = "ran"
        /// `◐ would stop`: watch mode let it run.
        public static let wouldStop = "would stop"
        /// `✕ stopped`: the command did not run.
        public static let stopped = "stopped"
        /// `⏺ asks`: waiting for a human.
        public static let asks = "asks"
    }
}
