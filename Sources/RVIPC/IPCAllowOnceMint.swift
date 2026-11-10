import Foundation
import RVDomain

/// `rv allow-once mint`: asks rvd to pre-arm one unlock code for a command
/// the owner typed. rvd mints only after the device owner approves, in the
/// same owner check as redeem (rvd's own prompt on macOS, the login
/// password in `ownerProof` on Linux), and remembers the code in memory
/// with the exact command, so a later redeem raises rvd's prompt naming
/// it. The code is lost when rvd restarts.
public struct MintAllowOnceParams: Sendable, Equatable, Codable {
    /// The exact command text the owner typed. rvd shows it, escaped and
    /// in full, in the owner's prompt and keeps it in memory only.
    public var command: String
    public var cwd: WorkingDirectory
    public var clientSemver: String
    /// Linux: the owner's login password, sent after rvd answered a first
    /// request with its own description. macOS sends none.
    public var ownerProof: OwnerProof?

    public init(command: String, cwd: WorkingDirectory, clientSemver: String, ownerProof: OwnerProof? = nil) {
        self.command = command
        self.cwd = cwd
        self.clientSemver = clientSemver
        self.ownerProof = ownerProof
    }
}

public struct MintAllowOnceReply: Sendable, Equatable, Codable {
    /// The new six-hex code, set only when rvd minted one.
    public var code: String?
    /// Set when the owner check refused or, on Linux, still needs the
    /// password (`proofRequired`, with `promptText`). Nothing was minted.
    public var ownerCheck: ConfirmOwnerActionReply?
    /// True when the command or cwd is too long to show in full; rvd
    /// never prompts with a shortened command.
    public var notShowable: Bool?
    /// A live code already exists for this command and cwd.
    public var alreadyPending: Bool?
    /// Linux: rvd's description, shown above the password prompt.
    public var promptText: String?

    public init(
        code: String? = nil, ownerCheck: ConfirmOwnerActionReply? = nil, notShowable: Bool? = nil,
        alreadyPending: Bool? = nil, promptText: String? = nil
    ) {
        self.code = code
        self.ownerCheck = ownerCheck
        self.notShowable = notShowable
        self.alreadyPending = alreadyPending
        self.promptText = promptText
    }
}

public struct MintAllowOnceCall: IPCCall {
    public var params: MintAllowOnceParams
    public var method: IPCMethod { .mintAllowOnce(params) }

    public init(params: MintAllowOnceParams) {
        self.params = params
    }

    public static func extract(_ result: IPCResult) -> MintAllowOnceReply? {
        if case .mintAllowOnce(let reply) = result { return reply }
        return nil
    }
}
