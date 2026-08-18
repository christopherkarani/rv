import ArgumentParser

struct FormatFlags: ParsableArguments {
    @Flag(name: .customLong("json"), help: "Robot JSON on stdout.")
    var json = false

    @Flag(name: .customLong("robot"), help: "Robot JSON on stdout.")
    var robot = false

    @Flag(name: .customLong("plain"), help: "Disable browse and color.")
    var plain = false

    @Flag(name: .customLong("no-color"), help: "Disable color.")
    var noColor = false
}

struct Test: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Evaluate a command."
    )

    @Flag(name: .customLong("explain"), help: "Print explain steps.")
    var explain = false

    @OptionGroup
    var format: FormatFlags

    @Argument(parsing: .captureForPassthrough, help: "Command to evaluate.")
    var commandParts: [String] = []

    func run() throws {
        try CommandInvocation.emit(
            kind: explain ? .testExplain : .test,
            commandParts: commandParts,
            format: format
        )
    }
}
