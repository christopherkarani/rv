public struct EvaluationBudget: Sendable, Equatable {
    public var maxPatternAttempts: Int

    public init(maxPatternAttempts: Int) {
        self.maxPatternAttempts = maxPatternAttempts
    }
}

public struct EvaluationRequest: Sendable, Equatable {
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
}
