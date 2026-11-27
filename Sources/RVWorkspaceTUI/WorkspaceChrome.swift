import Foundation

/// What a piece of chrome means, which picks its colour. Healthy chrome
/// is `quiet`; colour is spent only on what needs a decision.
enum WorkspaceTone: Equatable, Sendable {
    case quiet
    case ok
    /// Something wants you: an ask, a pane that needs a look.
    case wants
    case stopped
}

/// A word with its meaning. Every coloured indicator carries a word, so
/// no state is signalled by colour alone (UX-07).
struct WorkspaceToned: Equatable, Sendable {
    var text: String
    var tone: WorkspaceTone
}

/// The shell's one header line: `◆ app · sealed · 2 agents` in quiet
/// tones, and one toned word at the right edge.
struct WorkspaceHeader: Equatable, Sendable {
    var name: String
    /// `· sealed · 2 agents`, always quiet.
    var words: String
    var edge: WorkspaceToned

    static func make(
        project: String, connection: ConnectionState, terminalNeedsAttention: Bool,
        phase: String, protected: Bool, panes: Int, agents: Int, pending: Int
    ) -> Self {
        let name = WorkspacePaneChrome.safe(URL(fileURLWithPath: project).lastPathComponent) ?? "workspace"
        let state = phase == "active" && protected ? "sealed" : (WorkspacePaneChrome.safe(phase) ?? "starting")
        let count = agents > 0
            ? "\(agents) \(agents == 1 ? "agent" : "agents")"
            : "\(panes) \(panes == 1 ? "pane" : "panes")"
        return Self(name: name, words: " · \(state) · \(count)", edge: rightEdge(
            connection: connection, terminalNeedsAttention: terminalNeedsAttention,
            phase: phase, protected: protected, pending: pending))
    }

    /// The right edge, most urgent first.
    static func rightEdge(
        connection: ConnectionState, terminalNeedsAttention: Bool,
        phase: String, protected: Bool, pending: Int
    ) -> WorkspaceToned {
        if connection == .disconnected { return WorkspaceToned(text: "✕ disconnected", tone: .stopped) }
        if pending > 0 { return WorkspaceToned(text: "◐ \(pending) wants out", tone: .wants) }
        if terminalNeedsAttention { return WorkspaceToned(text: "◐ needs a look", tone: .wants) }
        if phase == "active", protected { return WorkspaceToned(text: "✓ quiet", tone: .ok) }
        return WorkspaceToned(text: "· idle", tone: .quiet)
    }
}

/// A pane's top row: `╭▸ ⏺ claude ────── read only ╮`. The pieces are
/// measured in terminal cells and always add up to the pane's width.
struct WorkspacePaneTopRow: Equatable, Sendable {
    /// `╭▸ ` focused, `╭─ ` not: focus is a glyph as well as a colour.
    var lead: String
    var title: String
    var titleCells: Int
    var rule: String
    /// Empty while the pane is simply running.
    var status: String
    var statusCells: Int
    var corner: String { "╮" }

    static let leadCells = 3

    static func make(width: Int, focused: Bool, title: String, agent: Bool, status: String) -> Self {
        let lead = focused ? "╭▸ " : "╭─ "
        let statusBudget = min(20, max(10, width / 3))
        let statusText = status.isEmpty ? "" : " " + WorkspaceCells.clip(status, to: statusBudget - 2) + " "
        let statusCells = WorkspaceCells.width(statusText)
        // One cell for the corner, one for the space before the rule.
        let titleBudget = max(1, width - leadCells - statusCells - 2)
        let clipped = WorkspaceCells.clip((agent ? "⏺ " : "") + title, to: titleBudget)
        let titleCells = WorkspaceCells.width(clipped)
        let ruleCells = max(0, width - leadCells - titleCells - statusCells - 1)
        let rule = ruleCells == 0 ? "" : " " + String(repeating: "─", count: ruleCells - 1)
        return Self(lead: lead, title: clipped, titleCells: titleCells, rule: rule,
                    status: statusText, statusCells: statusCells)
    }
}

/// A pane's bottom row: `╰ ◐ wants out api.stripe.com:443 · ^B R answer ─╯`
/// when an ask is shown, a plain rule otherwise.
struct WorkspacePaneBottomRow: Equatable, Sendable {
    var lead: String
    var ask: String
    var askCells: Int
    var rule: String

    static func make(width: Int, ask: String?) -> Self {
        guard let ask, width >= 4 else {
            return Self(lead: "╰", ask: "", askCells: 0, rule: String(repeating: "─", count: max(0, width - 2)))
        }
        let clipped = WorkspaceCells.clip(ask, to: width - 4)
        let cells = WorkspaceCells.width(clipped)
        return Self(lead: "╰ ", ask: clipped, askCells: cells,
                    rule: " " + String(repeating: "─", count: max(0, width - 4 - cells)))
    }
}

enum WorkspaceStatusLabel {
    /// The pane's status word and its meaning. Running is silent: an
    /// empty word, so the screen is not green all day.
    static func pane(_ pane: WorkspacePane, terminal: WorkspaceTerminalState?,
                     recentOutputOnly: Bool) -> WorkspaceToned {
        let text = WorkspacePaneChrome.status(pane, terminal: terminal, recentOutputOnly: recentOutputOnly)
        if text == "running" { return WorkspaceToned(text: "", tone: .quiet) }
        if terminal?.overflowed == true || recentOutputOnly { return WorkspaceToned(text: text, tone: .wants) }
        switch pane.lifecycle {
        case .empty, .launching, .attaching:
            return WorkspaceToned(text: text, tone: .quiet)
        case .running:
            return WorkspaceToned(text: text, tone: .wants)
        case .exited:
            if case .exited(let code)? = pane.lastOutcome, code != 0 {
                return WorkspaceToned(text: text, tone: .stopped)
            }
            return WorkspaceToned(text: text, tone: .quiet)
        case .launchFailed, .disconnected, .missing:
            return WorkspaceToned(text: text, tone: .stopped)
        }
    }

    static func scroll(hasNewOutput: Bool) -> WorkspaceToned {
        hasNewOutput ? WorkspaceToned(text: "SCROLL • new", tone: .wants) : WorkspaceToned(text: "SCROLL", tone: .quiet)
    }

    /// Agents rv knows by name. Display only: the name picks the title's
    /// colour and `⏺`, nothing else.
    static let agentNames: Set<String> = ["claude", "codex", "opencode", "gemini", "cursor", "aider", "goose", "copilot"]

    /// True when the title's first word is an agent's name: `✳ Claude
    /// Code`, `/usr/local/bin/aider --yes`, `Codex: fixing tests`. A name
    /// later in the title (`vim claude.md`) is not the agent running.
    static func isAgent(_ title: String) -> Bool {
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "/" && $0 != "-" })
        guard let first = words.first?.split(separator: "/").last else { return false }
        return agentNames.contains(String(first))
    }
}

/// The footer teaches the keys for the first few sessions, then shrinks
/// to `^B ?`.
enum WorkspaceFooter {
    static let teachingSessions = 3

    static func teaches(sessionsStarted: Int?) -> Bool {
        guard let sessionsStarted else { return true }
        return sessionsStarted <= teachingSessions
    }

    static func text(tabs: Int, panes: Int, teaching: Bool, connection: ConnectionState, reconnecting: Bool) -> String {
        var parts: [String] = []
        if teaching {
            parts.append("\(tabs) \(tabs == 1 ? "tab" : "tabs")")
            parts.append("\(panes) \(panes == 1 ? "pane" : "panes")")
        }
        if connection == .disconnected {
            parts.append(reconnecting ? "reconnecting…" : "workspace disconnected · Enter retry")
        }
        parts.append(teaching ? "^B ? help · ^B w runtimes · ^B R review" : "^B ?")
        return parts.joined(separator: " · ")
    }
}

/// Terminal cell widths, close enough for chrome. Wide East Asian and
/// emoji clusters take two cells; views still frame each piece, so a
/// miscount can only trim, never push the border out of line.
enum WorkspaceCells {
    static func width(_ text: String) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }

    static func width(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if character.unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// `text` within `cells`, cut at the end with a visible `…`.
    static func clip(_ text: String, to cells: Int) -> String {
        guard cells > 0 else { return "" }
        guard width(text) > cells else { return text }
        var kept = ""
        var used = 0
        for character in text {
            let next = width(of: character)
            if used + next > cells - 1 { break }
            kept.append(character)
            used += next
        }
        return kept + "…"
    }
}
