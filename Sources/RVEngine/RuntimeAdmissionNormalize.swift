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
    let analyzed: (ActionEffects, ActionResources, SemanticAction?)
    switch analysis.innermost {
    case .unwrapLimited:
        return .failure(.failed)
    case .git(let git):
        analyzed = (git.effects, git.resources, .git(git))
    case .filesystem(let filesystem):
        analyzed = (filesystem.effects, filesystem.resources, .filesystem(filesystem))
    case .wrapper, .unknown:
        analyzed = (ActionEffects(), ActionResources(), nil)
    }
    let fingerprint = ActionFingerprint(
        rawValue: "runtime:\(subject.session.id.rawValue.uuidString):\(subject.policyWorkspace.rawValue):\(command.rawValue)"
    )
    return .success(
        .shell(
            ShellAction(
                fingerprint: fingerprint,
                effects: analyzed.0,
                resources: analyzed.1,
                scope: ActionScope(workingDirectory: subject.policyWorkspace),
                supportingCommand: command,
                analysis: analyzed.2
            )
        )
    )
}
