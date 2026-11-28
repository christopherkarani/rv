import RVDomain

/// Required ports for a live hook door. Production and tests build one value.
///
/// Step 8B: no spend port. Human approval arrives via RVOperatorUI or TTY
/// allow-once; the agent retries and the retry consumes the planted grant
/// through the ordinary evaluate port.
public struct HookEvaluateWorld: Sendable {
    public var evaluate: @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult
    public var evaluateFile: @Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult
    public var mintOnDeny: @Sendable (EvaluationResult, WorkingDirectory?) async -> AllowOnceUnlockMint?
    public var recordHostAsk: @Sendable (HookRequest, ProposedAction) async throws -> Void
    /// M-07 command-carrying mint port. Preferred over `mintOnDeny` when
    /// set: the exact command lets the daemon bind the minted row's
    /// payload digest. Nil keeps the legacy port (existing worlds
    /// unchanged). The command never leaves the daemon in-process: only
    /// its payload digest is stored in the row.
    public var mintOnDenyWithCommand:
        (@Sendable (EvaluationResult, WorkingDirectory?, ShellCommand) async -> AllowOnceUnlockMint?)?
    /// Who a stop asks to act and what each rule's pack offers (B1).
    /// `.plain` says "your user" and offers no safer command; rvd and the
    /// hook-local pass give the owner's first name and the pack advice.
    public var voice: StopVoice
    /// Whether a pack's safer command is one rv allows here, in the mode
    /// that stopped the original (B1). A stop shows its `safer` line only
    /// when this says yes, so the advice is never a command rv would stop
    /// too. Nil (tests, worlds with no advice) shows the voice's advice as
    /// it is.
    public var saferAllowed: (@Sendable (ShellCommand, WorkingDirectory?) async -> Bool)?
    /// B4: the facts rv tells an agent at session start, for the session's
    /// cwd. Nil (the port, or its answer) sends no house rules: the event
    /// passes like a foreign one. Read-only; it never changes policy.
    public var houseRules: (@Sendable (WorkingDirectory?) async -> HouseRules?)?
    /// B5: counts one stop shown to an agent session and returns how many
    /// stops of the same rule that session has hit lately, this one
    /// included. rvd keeps the count in memory; nil (tests, the C hook's
    /// own worlds) counts nothing, and every stop reads as a first.
    public var countStop: (@Sendable (StopStreakKey) -> Int)?

    public init(
        evaluate: @escaping @Sendable (ShellCommand, WorkingDirectory?) async -> EvaluationResult,
        evaluateFile: @escaping @Sendable (FileToolAction, WorkingDirectory?) async -> EvaluationResult,
        mintOnDeny: @escaping @Sendable (EvaluationResult, WorkingDirectory?) async -> AllowOnceUnlockMint?,
        recordHostAsk: @escaping @Sendable (HookRequest, ProposedAction) async throws -> Void,
        mintOnDenyWithCommand: (
            @Sendable (EvaluationResult, WorkingDirectory?, ShellCommand) async -> AllowOnceUnlockMint?
        )? = nil,
        voice: StopVoice = .plain,
        saferAllowed: (@Sendable (ShellCommand, WorkingDirectory?) async -> Bool)? = nil,
        houseRules: (@Sendable (WorkingDirectory?) async -> HouseRules?)? = nil,
        countStop: (@Sendable (StopStreakKey) -> Int)? = nil
    ) {
        self.evaluate = evaluate
        self.evaluateFile = evaluateFile
        self.mintOnDeny = mintOnDeny
        self.recordHostAsk = recordHostAsk
        self.mintOnDenyWithCommand = mintOnDenyWithCommand
        self.voice = voice
        self.saferAllowed = saferAllowed
        self.houseRules = houseRules
        self.countStop = countStop
    }
}
