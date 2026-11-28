import Foundation
import RVDomain
import RVIPC

// K2, Approvals with Touch ID (Menu bar v5, "Answer with a fingertip"):
// what the glass sheet under the diamond shows for one stop that can be
// unlocked, as a value. Display only: every decisive field (the command,
// the code, rvd's prompt text) is rvd's, shown as rvd sent it, and nothing
// here can approve anything. The shell renders it and asks Touch ID.

/// One stop waiting for the person, as the Glance state and the
/// notification etiquette see it: no command text, so nothing secret can
/// reach a banner or the lock screen.
public struct GlanceUnlockAsk: Sendable, Equatable {
    public var codeHash: String
    public var host: HookHost
    /// `orchid · rocket · crane`.
    public var checkWords: String

    public init(codeHash: String, host: HookHost, checkWords: String) {
        self.codeHash = codeHash
        self.host = host
        self.checkWords = checkWords
    }

    /// The asks rvd listed, keyed by code hash. An ask rvd recorded no
    /// agent for can still be answered on the sheet, but never notifies.
    public static func asks(from items: [UIUnlockItemDTO]) -> [String: GlanceUnlockAsk] {
        var asks: [String: GlanceUnlockAsk] = [:]
        for item in items {
            guard let host = item.host else { continue }
            asks[item.codeHash] = GlanceUnlockAsk(
                codeHash: item.codeHash, host: host, checkWords: item.checkWords.joined(separator: CheckWords.separator))
        }
        return asks
    }
}

/// The sheet for one unlock ask.
public struct UnlockSheet: Sendable, Equatable {
    public var codeHash: String
    /// "Needs you".
    public var title: String
    /// "claude is waiting · expires in 12m".
    public var subtitle: String
    /// "Claude Code · /Users/chris/rv".
    public var who: String
    /// The whole command, verbatim as rvd escaped it. Never shortened: the
    /// view wraps it and scrolls.
    public var command: String
    /// What the command would do, in plain words (K5 template). Never the
    /// agent's words, never a verdict.
    public var effect: String
    /// "claude says", shown only beside `agentSays`.
    public var agentSaysLabel: String
    /// The agent's own description, labelled as the agent's.
    public var agentSays: String?
    /// "Check the words in your terminal: orchid · rocket · crane".
    public var checkWords: String
    /// "code a7c835 · rule core.git:push-force".
    public var codeLine: String
    /// What each answer does, said before the person answers.
    public var onceScope: String
    public var alwaysScope: String
    /// Set when nothing can be approved here; the buttons stay off.
    public var unavailable: String?

    public static let allowOnceLabel = "Allow once"
    public static let alwaysAllowLabel = "Always allow"
    public static let denyLabel = "Deny"

    public var canApprove: Bool { unavailable == nil }

    public init(_ item: UIUnlockItemDTO, now: Date) {
        let agent = item.host?.rawValue ?? "the agent"
        // The words are worked out here from the code, the way `rv wait`
        // works them out, never taken from the reply.
        let code = AllowOnceUnlockCode(validating: item.code)
        let words = code.map(CheckWords.line(for:)) ?? "unavailable"
        codeHash = item.codeHash
        title = "Needs you"
        subtitle = "\(agent) is waiting · \(Self.expiry(item.advisoryExpiresWall, now: now))"
        who = "\(item.host.map(GlanceAgent.displayName) ?? "An agent") · \(item.workingDirectory)"
        command = item.command
        effect = PlainTemplate.line(for: PlainRequest(
            host: item.host ?? .claude, tool: .bash, text: item.command, outcome: .stopped, rule: item.rule)).text
        agentSaysLabel = "\(agent) says"
        agentSays = item.agentSays
        checkWords = "Check the words in your terminal: \(words)"
        codeLine = (["code \(item.code)"] + (item.rule.map { ["rule \($0)"] } ?? [])).joined(separator: " · ")
        onceScope = "Allow once: this exact command runs one time, in this folder. Then rv stops it again."
        alwaysScope = "Always allow: rv lets this exact command run from now on, in any folder. "
            + "Undo with rv allowlist remove."
        if code == nil {
            unavailable = "rv sent a code this app can't read, so it can't be approved here."
        } else if !item.approvable {
            unavailable = "This command is too long to approve in a prompt. Run it yourself in a terminal instead."
        } else {
            unavailable = nil
        }
    }

    /// The Touch ID prompt's reason. Built from the code and its words
    /// only, never from text an agent wrote, so the prompt cannot be
    /// dressed up; the sheet beside it shows the whole command.
    public static func touchIDReason(code: AllowOnceUnlockCode, decision: UIUnlockDecision) -> String {
        let words = CheckWords.line(for: code)
        let code = code.rawValue
        switch decision {
        case .allowOnce:
            return "allow the stopped command once (code \(code), \(words))"
        case .alwaysAllow:
            return "always allow the stopped command (code \(code), \(words))"
        }
    }

    /// "expires in 12m", "expires now".
    static func expiry(_ at: Date, now: Date) -> String {
        let seconds = Int(at.timeIntervalSince(now))
        guard seconds >= 60 else { return "expires now" }
        return seconds < 3600 ? "expires in \(seconds / 60)m" : "expires in \(seconds / 3600)h"
    }
}

/// What the sheet says once an answer is in.
public enum UnlockOutcomeText {
    public static func line(_ status: UIUnlockStatus, agent: String) -> String {
        switch status {
        case .allowedOnce:
            "\(CommandVocabulary.Glyph.done.rawValue) Allowed once. \(agent) can retry it now."
        case .alwaysAllowed:
            "\(CommandVocabulary.Glyph.done.rawValue) Always allowed. \(agent) can retry it now."
        case .alreadyAnswered:
            "\(CommandVocabulary.Glyph.done.rawValue) Already answered in a terminal."
        case .waiting, .awaitingAuthentication, .unknown:
            "\(CommandVocabulary.Glyph.stopped.rawValue) Still stopped."
        }
    }
}

/// The unlock banner's actions (K2), and where a tap on one leads. Pure:
/// the macOS app registers the category with these ids and hands each
/// response here. A banner action never answers anything by itself: the
/// most it does is open the sheet and start the Touch ID prompt, which the
/// person still has to pass, beside the sheet showing the whole command.
public enum UnlockNoticeAction {
    public static let category = "rv.unlock"
    public static let allowOnce = "rv.unlock.allow-once"
    public static let allowOnceTitle = "Allow once…"
    public static let codeHashKey = "rv.unlock.code-hash"
    /// UserNotifications' ids for a tap on the banner and for a dismissal.
    public static let openBanner = "com.apple.UNNotificationDefaultActionIdentifier"
    public static let dismissBanner = "com.apple.UNNotificationDismissActionIdentifier"

    public struct Route: Sendable, Equatable {
        public var codeHash: String
        /// Set when the action itself asked to allow: the sheet opens and
        /// Touch ID starts at once.
        public var then: UIUnlockDecision?
    }

    /// Nil for a dismissal, an unknown action, or a banner that names no
    /// code: the command stays stopped and nothing opens.
    public static func route(actionID: String, codeHash: String?) -> Route? {
        guard let codeHash, isCodeHash(codeHash) else { return nil }
        switch actionID {
        case allowOnce: return Route(codeHash: codeHash, then: .allowOnce)
        case openBanner: return Route(codeHash: codeHash, then: nil)
        default: return nil
        }
    }

    /// 64 lowercase hex characters (sha256 of a code).
    static func isCodeHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
