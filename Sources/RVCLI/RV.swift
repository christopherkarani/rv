import ArgumentParser
import RVDomain

public struct RV: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "rv",
        abstract: "Block destructive shell commands.",
        version: ProductVersion.semver,
        subcommands: [
            Test.self,
            Explain.self,
            Packs.self,
            Policy.self,
            Scan.self,
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
