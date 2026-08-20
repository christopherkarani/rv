import ArgumentParser

public struct RV: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "rv",
        abstract: "Block destructive shell commands.",
        subcommands: [
            Test.self,
            Explain.self,
            Packs.self,
            Service.self,
            Hook.self,
            Setup.self,
            Uninstall.self,
            Doctor.self,
            AllowOnceCommand.self,
            AllowlistCommand.self,
        ]
    )

    public init() {}
}
