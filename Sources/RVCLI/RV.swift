import ArgumentParser

public struct RV: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "rv",
        abstract: "Block destructive shell commands.",
        subcommands: [Test.self, Explain.self, Service.self]
    )

    public init() {}
}
