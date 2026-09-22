import RVDomain

/// Normalizes one admitted shell command against the runtime RV launched.
///
/// The command text is the only untrusted action field. Workspace and session
/// identity come from `subject`. Unwrap-limited input produces no proposal.
public func normalizeRuntimeAdmission(
    subject: RuntimeAdmissionSubject,
    command: ShellCommand
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    guard let root = RepositoryRoot(validating: subject.policyWorkspace.rawValue) else {
        return .failure(.failed)
    }
    let analysis = analyzeSemantics(
        command,
        gitWorld: .unprobed,
        filesystemWorld: .probed(
            FilesystemAnalysisContext(
                workingDirectory: subject.policyWorkspace,
                repositoryRoot: root
            )
        )
    )
    let fingerprint = ActionFingerprint(
        rawValue: "runtime:\(subject.session.id.rawValue.uuidString):\(subject.policyWorkspace.rawValue):\(command.rawValue)"
    )
    let scope = ActionScope(workingDirectory: subject.policyWorkspace)
    switch analysis.innermost {
    case .unwrapLimited:
        return .failure(.failed)
    case .git(let git):
        return .success(
            .shell(
                ShellAction(
                    fingerprint: fingerprint,
                    scope: scope,
                    supportingCommand: command,
                    analysis: .git(git)
                )
            )
        )
    case .filesystem(let filesystem):
        return .success(
            .shell(
                ShellAction(
                    fingerprint: fingerprint,
                    scope: scope,
                    supportingCommand: command,
                    analysis: .filesystem(filesystem)
                )
            )
        )
    case .wrapper, .unknown:
        return .success(
            .shell(
                ShellAction(
                    fingerprint: fingerprint,
                    effects: ActionEffects(),
                    resources: ActionResources(),
                    scope: scope,
                    supportingCommand: command
                )
            )
        )
    }
}
