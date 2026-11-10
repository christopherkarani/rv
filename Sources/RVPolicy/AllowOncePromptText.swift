import Foundation
import RVDomain

/// The text the device owner reads before approving one allow-once
/// redemption: the whole command, its working directory and the deny rule,
/// so `git push --force origin main` and `git push --force origin feature`
/// read differently.
///
/// Every field goes through `DisplayedText.approvalField`, so control,
/// escape, bidi, invisible and blank-looking characters show as visible
/// `\uXXXX` escapes instead of rewriting or hiding part of the line.
///
/// Nothing is ever cut. The grant covers the whole command and cwd, so a
/// shortened prompt would hide exactly the part that runs
/// (`git status ; : <padding> ; rm -rf ~/work`). A value that does not fit,
/// measured in unicode scalars after escaping, makes `reason` nil, and the
/// caller must refuse to prompt.
///
/// Phrased as a verb phrase because macOS puts the asking process in front
/// of it ("rvd is trying to allow once …").
public enum AllowOncePromptText {
    public static let maxCommandScalars = 300
    public static let maxCwdScalars = 256

    /// Nil when the command or cwd is too long to show in full.
    public static func reason(command: String, cwd: WorkingDirectory, ruleID: RuleID?) -> String? {
        let shownCommand = DisplayedText.approvalField(command)
        let shownCwd = DisplayedText.approvalField(cwd.rawValue)
        guard shownCommand.unicodeScalars.count <= maxCommandScalars,
            shownCwd.unicodeScalars.count <= maxCwdScalars
        else { return nil }
        let base = "allow once \"\(shownCommand)\" in \(shownCwd)"
        guard let ruleID else { return base }
        return "\(base) (rule \(DisplayedText.approvalField(ruleID.rawValue)))"
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
    /// The exact text the hook denied: env values, wrapper flags, the
    /// argv0 path and interpreter code included, none of which the matching
    /// view keeps. It can carry secrets, so it lives only here and goes
    /// only to the owner's local prompt, through `AllowOncePromptText`
    /// (on Linux via the redeeming CLI, which proved it holds the code);
    /// never to a file or the audit log. Nil when the mint had only
    /// the view: rvd cannot show what the grant covers and will not prompt.
    public let command: String?
    public let ruleID: RuleID?
    public let expiresAt: Date
    /// rvd planted a grant for this code in this lifetime.
    public internal(set) var redeemed: Bool
}
