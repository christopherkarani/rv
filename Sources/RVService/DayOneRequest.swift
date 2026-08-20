import RVDomain

public func dayOneEvaluationRequest(command: ShellCommand) -> EvaluationRequest {
    EvaluationRequest(command: command, enabledPacks: dayOnePackIDs)
}
