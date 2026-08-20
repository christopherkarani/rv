public struct EvaluationBudget: Sendable, Equatable, Codable {
    public var maxPatternAttempts: Int

    public init(maxPatternAttempts: Int) {
        self.maxPatternAttempts = maxPatternAttempts
    }
}

public struct EvaluationRequest: Sendable, Equatable, Codable {
    public var command: ShellCommand
    public var enabledPacks: [PackID]
    public var budget: EvaluationBudget?

    public init(
        command: ShellCommand,
        enabledPacks: [PackID],
        budget: EvaluationBudget? = nil
    ) {
        self.command = command
        self.enabledPacks = enabledPacks
        self.budget = budget
    }

    /// Day-one packs only (`core.filesystem`, `core.git`) and the default budget.
    public static func makeDayOne(command: ShellCommand) -> EvaluationRequest {
        EvaluationRequest(command: command, enabledPacks: dayOnePackIDs)
    }
}
