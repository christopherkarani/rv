import ArgumentParser

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Show why a command is allowed or blocked."
    )

    @OptionGroup
    var format: FormatFlags

    @Argument(parsing: .captureForPassthrough, help: "Command to explain.")
    var commandParts: [String] = []

    func run() throws {
        try CommandInvocation.emit(kind: .explain, commandParts: commandParts, format: format)
    }
}
