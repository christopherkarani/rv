import Foundation
import RVDomain

/// The text the device owner reads before approving one allow-once
/// redemption: the whole command, its working directory and the deny rule,
/// so `git push --force origin main` and `git push --force origin feature`
/// read differently.
///
/// Every field goes through `DisplayedText.approvalField`, so control,
/// escape, bidi, invisible and blank-looking characters show as visible
/// `\uXXXX` escapes instead of rewriting or hiding part of the line, and
/// `"` and `\` show as `\"` and `\\`, so a command cannot close its quote
/// and append a fake ` in <cwd> (rule …, code …)` of its own.
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

    /// Nil when the command or cwd is too long to show in full. `code` is
    /// the unlock code being redeemed: the CLI tells the owner which code to
    /// approve, so a prompt raised for another code reads differently.
    public static func reason(
        command: String, cwd: WorkingDirectory, ruleID: RuleID?, code: String? = nil
    ) -> String? {
        let shownCommand = DisplayedText.approvalField(command)
        let shownCwd = DisplayedText.approvalField(cwd.rawValue)
        guard shownCommand.unicodeScalars.count <= maxCommandScalars,
            shownCwd.unicodeScalars.count <= maxCwdScalars
        else { return nil }
        let tags = [
            ruleID.map { "rule \(DisplayedText.approvalField($0.rawValue))" },
            code.map { "code \(DisplayedText.approvalField($0))" },
        ].compactMap { $0 }
        let base = "allow once \"\(shownCommand)\" in \(shownCwd)"
        guard tags.isEmpty == false else { return base }
        return "\(base) (\(tags.joined(separator: ", ")))"
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
    /// The code itself, named in the prompt (the agent already has it from
    /// the deny text; the pending file keeps only its hash).
    public let code: AllowOnceUnlockCode
    public let expiresAt: Date
    /// rvd planted a grant for this code in this lifetime.
    public internal(set) var redeemed: Bool
    /// How the code came to be. Only a hook stop is an ask the menu bar
    /// shows (K2); a pre-armed code is the owner's own.
    public let origin: Origin
    /// The stop's context, for the menu bar's approval sheet. Display
    /// only: never part of what a grant covers.
    public let stop: AllowOnceStopContext?

    public enum Origin: Sendable, Equatable {
        /// A hook denied the command and handed the agent this code.
        case stop
        /// The owner ran `rv allow-once mint`.
        case preArmed
    }
}

/// What the hook knew about the agent behind a stop, kept with the issued
/// code in rvd's memory for the menu bar's approval sheet (K2). Display
/// only: who asked and, when the host sends one, the agent's own one-line
/// description of the command. The agent wrote that line, so the sheet
/// labels it as the agent's words and nothing decides on it.
public struct AllowOnceStopContext: Sendable, Equatable {
    /// Longest agent line kept, in unicode scalars.
    public static let maxAgentSaysScalars = 512

    public let asker: HookHost
    public let agentSays: String?

    public init(asker: HookHost, agentSays: String? = nil) {
        self.asker = asker
        let trimmed = agentSays?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.agentSays = trimmed.isEmpty
            ? nil : String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(Self.maxAgentSaysScalars)))
    }
}
