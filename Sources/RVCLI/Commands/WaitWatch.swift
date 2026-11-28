import Foundation
import RVDomain
import RVPolicy
import RVTheme

// `rv wait <code>` (workstream H, chunk H2): the pure part. What the
// unlock ledger and rvd's live events say about one stop's code, and the
// words the agent reads. Nothing here can approve anything: it reads rows
// and events and returns a value.

/// One stop's code as the agent was given it (`rv unlock a7c835`): six
/// lowercase hex characters. `a7c-835` (the grouped spelling) and upper
/// case are accepted and mean the same code.
struct WaitCode: Equatable, Sendable {
    let code: AllowOnceUnlockCode

    init?(_ typed: String) {
        let squeezed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
        guard let code = AllowOnceUnlockCode(validating: squeezed) else { return nil }
        self.code = code
    }

    /// How the stop wrote it.
    var shown: String { code.rawValue }

    /// The unlock ledger's key for this code.
    var codeHash: String { sha256Hex(code.rawValue) }
}

/// One unlock-ledger row, as much as `rv wait` reads of it.
struct WaitLedgerRow: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case pending, granted, consumed
    }

    var kind: Kind
    var codeHash: String
    var commandRedacted: String
    var cwd: String
    var createdAt: Date

    init(kind: Kind, codeHash: String, commandRedacted: String, cwd: String, createdAt: Date) {
        self.kind = kind
        self.codeHash = codeHash
        self.commandRedacted = commandRedacted
        self.cwd = cwd
        self.createdAt = createdAt
    }

    init(_ row: AllowOnceListRow) {
        let kind: Kind = switch row.kind {
        case .pending: .pending
        case .granted: .granted
        case .consumed: .consumed
        }
        self.init(
            kind: kind, codeHash: row.codeHash, commandRedacted: row.commandRedacted, cwd: row.cwd.rawValue,
            createdAt: row.createdAt)
    }
}

/// The ask a code names, read from the unlock ledger once at the start.
struct WaitAsk: Equatable, Sendable {
    let codeHash: String
    let commandRedacted: String
    let cwd: String
    let createdAt: Date
}

/// How the person's unlock reached rv.
enum WaitUnlockRoute: Equatable, Sendable {
    /// `rv unlock <code>` (`rv allow-once`) in a terminal.
    case code
    /// The review window approved the same command in the same folder.
    case review
}

/// Where one wait stands.
enum WaitState: Equatable, Sendable {
    case waiting
    /// The person unlocked it: retry the exact command.
    case unlocked(WaitUnlockRoute)
    /// Unlocked, and the unlock is already spent: a retry ran.
    case alreadyUsed
    /// The code ran out before anyone answered.
    case expired
    /// rvd restarted: it forgets the codes it issued, so this one is dead.
    case rvdRestarted

    var isFinal: Bool { self != .waiting }
}

/// Reads the unlock ledger (`rv allow-once list`'s rows) for one code. Pure.
enum WaitWatch {
    /// Prefix of the rows rvd projects when the review window approves a
    /// held ask (`HookAskResolver`).
    static let reviewCodePrefix = "pending:"

    /// The ask `code` names, or nil when the ledger has no row for it
    /// (never issued, typed wrong, or long gone).
    static func ask(for code: WaitCode, in rows: [WaitLedgerRow]) -> WaitAsk? {
        rows.first { $0.codeHash == code.codeHash }.map {
            WaitAsk(codeHash: $0.codeHash, commandRedacted: $0.commandRedacted, cwd: $0.cwd, createdAt: $0.createdAt)
        }
    }

    /// Where `ask` stands in `rows` (the ledger now; expired rows already
    /// left out, as `AllowOnceStore.list` leaves them out).
    ///
    /// The ledger is a display projection in a file the agent's own user
    /// can write. That is fine here: this only tells the agent when to
    /// retry. rvd's memory holds the grant, so a forged "unlocked" earns
    /// the agent one more stop, never a run.
    static func state(of ask: WaitAsk, in rows: [WaitLedgerRow]) -> WaitState {
        if let own = rows.first(where: { $0.codeHash == ask.codeHash }) {
            switch own.kind {
            case .granted: return .unlocked(.code)
            case .consumed: return .alreadyUsed
            case .pending: break
            }
        }
        // The review window keys its grant by the held ask, not the code:
        // the same command in the same folder, approved after the stop.
        let approved = rows.filter {
            $0.codeHash.hasPrefix(reviewCodePrefix) && $0.commandRedacted == ask.commandRedacted
                && $0.cwd == ask.cwd && $0.createdAt >= ask.createdAt
        }
        if approved.contains(where: { $0.kind == .granted }) { return .unlocked(.review) }
        if approved.contains(where: { $0.kind == .consumed }) { return .alreadyUsed }
        if rows.contains(where: { $0.codeHash == ask.codeHash }) { return .waiting }
        return .expired
    }
}

/// What `rv wait` ends with. `stillWaiting` is the time limit passing with
/// no answer yet.
enum WaitEnding: Equatable, Sendable {
    case finished(WaitState)
    case unknownCode
    case stillWaiting

    /// 0 carry on; 2 no such code; 1 anything else (A5's table).
    var exitCode: Int32 {
        switch self {
        case .finished(.unlocked): 0
        case .unknownCode: 2
        case .finished, .stillWaiting: 1
        }
    }
}

/// The words of `rv wait`: the v3 "Approved, carry on" frame. One idea per
/// line, the next command last.
enum WaitScreen {
    private typealias Glyph = CommandVocabulary.Glyph

    static func lines(
        _ ending: WaitEnding, code: WaitCode, owner: String, waited: Duration, palette: Palette
    ) -> [String] {
        let again = "\(CommandVocabulary.Command.wait.invocation) \(code.shown)"
        switch ending {
        case .finished(.unlocked):
            return ["\(paint("\(Glyph.done.rawValue) \(owner) unlocked it", palette.allow, palette)) "
                + "\(paint("(\(clock(waited)))", palette.muted, palette)). Retry the exact command."]
        case .finished(.alreadyUsed):
            return [
                "\(paint("\(Glyph.done.rawValue) \(owner) unlocked it", palette.allow, palette)), and it already ran once.",
                "Running it again needs a new unlock.",
            ]
        case .finished(.expired):
            return [
                "\(paint("\(Glyph.stopped.rawValue) Code \(code.shown) expired", palette.deny, palette)) before \(owner) answered.",
                "Retry the exact command for a new code.",
            ]
        case .finished(.rvdRestarted):
            return [
                "\(paint("\(Glyph.stopped.rawValue) rv restarted", palette.deny, palette)), so code \(code.shown) no longer works.",
                "Retry the exact command for a new code.",
            ]
        case .finished(.waiting), .stillWaiting:
            return [
                "\(paint("\(Glyph.ask.rawValue) Still waiting on \(owner)", palette.mark, palette)) "
                    + "\(paint("(\(clock(waited)))", palette.muted, palette)).",
                paint("\(Glyph.next.rawValue) \(again)", palette.heading, palette),
            ]
        case .unknownCode:
            return [
                "\(paint("\(Glyph.stopped.rawValue) rv has no stop with code \(code.shown)", palette.deny, palette)).",
                "Use the code from rv's stop message.",
            ]
        }
    }

    /// `1m 12s`, `40s`, `1h 5m`.
    static func clock(_ duration: Duration) -> String {
        let seconds = max(0, Int(duration.components.seconds))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    private static func paint(_ text: String, _ ink: String, _ palette: Palette) -> String {
        guard palette.colorsEnabled else { return text }
        return ink + text + palette.reset
    }
}

/// The name the agent's words use for the person who decides: the first
/// word of the account's full name, or "The owner" when there is none.
enum WaitOwnerName {
    static let fallback = "The owner"

    static func from(fullName: String?) -> String {
        let first = fullName?
            .split(separator: ",").first?
            .split(separator: " ").first
            .map(String.init)
        guard let first, first.isEmpty == false, first.count <= 32,
            first.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" })
        else { return fallback }
        return first
    }
}
