import Foundation
import RVDomain

/// The text the device owner reads before approving one allow-once
/// redemption: the whole command, its working directory and the deny rule,
/// so `git push --force origin main` and `git push --force origin feature`
/// read differently.
///
/// Every field goes through `DisplayedText.field`, so control, escape and
/// bidi characters show as visible `\uXXXX` escapes instead of rewriting the
/// line. Long values are cut with a visible `…`: the command keeps its head
/// (the program and its first arguments), the directory keeps its tail
/// (the repo name).
///
/// Phrased as a verb phrase because macOS puts the asking process in front
/// of it ("rvd is trying to allow once …").
public enum AllowOncePromptText {
    public static let maxCommandCharacters = 240
    public static let maxCwdCharacters = 120

    public static func reason(command: String, cwd: WorkingDirectory, ruleID: RuleID?) -> String {
        let shownCommand = keepingHead(DisplayedText.field(command), max: maxCommandCharacters)
        let shownCwd = keepingTail(DisplayedText.field(cwd.rawValue), max: maxCwdCharacters)
        let base = "allow once \"\(shownCommand)\" in \(shownCwd)"
        guard let ruleID else { return base }
        return "\(base) (rule \(DisplayedText.field(ruleID.rawValue)))"
    }

    /// The command as invoked: the wrapper tag the normalized view erases
    /// (`sudo`, `FOO=… sudo`) in front of the view.
    public static func invoked(view: String, invocationDisplay: String?) -> String {
        guard let invocationDisplay, invocationDisplay.isEmpty == false else { return view }
        return "\(invocationDisplay) \(view)"
    }

    private static func keepingHead(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max - 1)) + "…"
    }

    private static func keepingTail(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        return "…" + String(text.suffix(max - 1))
    }
}

/// What rvd saw when it issued one deny code. Memory only, held by rvd's
/// own `AllowOnceStore`: the same-user projection file keeps only the
/// redacted head (a full command can carry a secret), and anything in that
/// file can be rewritten by the agent. This record is what lets rvd name
/// the whole command in the owner's prompt from its own knowledge.
public struct IssuedAllowOnce: Sendable, Equatable {
    public let fingerprint: GrantFingerprint
    public let cwd: WorkingDirectory
    public let payloadDigest: ContentPayloadDigest?
    /// Wrapper tag plus the matching view (quoted payloads already masked).
    /// Raw: render it only through `AllowOncePromptText`.
    public let command: String
    public let ruleID: RuleID?
    public let expiresAt: Date
    /// rvd planted a grant for this code in this lifetime.
    public internal(set) var redeemed: Bool
}
