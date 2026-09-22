/// Fail-closed normalize outcome. Unknown analysis is not an error.
public enum AgentNormalizationError: Error, Sendable, Equatable {
    /// Innermost analysis is unwrap-limited. No `ProposedAction` is produced.
    case unwrapLimited
}

extension ProposedAction {
    /// Host-door process proposal from already-run semantic analysis.
    ///
    /// Unwrap-limited fails closed. Git and filesystem shells derive effects
    /// and resources from the innermost subject. Unknown is an empty-effect
    /// shell proposal. Fingerprint is `ActionFingerprint.make`, never semantic
    /// `shell:git.*` / `shell:fs.*`.
    public static func process(
        host: HookHost,
        session: SessionID?,
        cwd: WorkingDirectory?,
        command: ShellCommand,
        analysis: SemanticAnalysis
    ) -> Result<ProposedAction, AgentNormalizationError> {
        if case .unwrapLimited = analysis.innermost {
            return .failure(.unwrapLimited)
        }
        return .success(
            .shell(
                hostDoorShell(
                    host: host,
                    session: session,
                    cwd: cwd,
                    command: command,
                    analysis: analysis
                )
            )
        )
    }

    /// Shared host-door shell construction for hook `pendingAction` and agent normalize.
    ///
    /// Unwrap-limited is empty-effect here so the hook door can keep dropping it on
    /// the stored action. Agent normalize must fail before calling this.
    static func hostDoorShell(
        host: HookHost,
        session: SessionID?,
        cwd: WorkingDirectory?,
        command: ShellCommand,
        analysis: SemanticAnalysis
    ) -> ShellAction {
        let fingerprint = ActionFingerprint.make(
            host: host,
            session: session,
            cwd: cwd,
            command: command
        )
        let scope = ActionScope(workingDirectory: cwd)
        switch analysis.innermost {
        case .git(let git):
            return ShellAction(
                fingerprint: fingerprint,
                scope: scope,
                supportingCommand: command,
                analysis: .git(git)
            )
        case .filesystem(let filesystem):
            return ShellAction(
                fingerprint: fingerprint,
                scope: scope,
                supportingCommand: command,
                analysis: .filesystem(filesystem)
            )
        case .wrapper, .unwrapLimited, .unknown:
            return ShellAction(
                fingerprint: fingerprint,
                effects: ActionEffects(),
                resources: ActionResources(),
                scope: scope,
                supportingCommand: command
            )
        }
    }
}
