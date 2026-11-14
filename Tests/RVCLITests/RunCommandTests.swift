import ArgumentParser
import RVIsolation
import RVTheme
import Testing
@testable import RVCLI

@Suite("rv run command")
struct RunCommandTests {
    @Test func isATopLevelCommand() {
        #expect(RV.configuration.subcommands.contains { $0.configuration.commandName == "run" })
    }

    @Test func parsesRepeatedSecretsAndPassesTheCommandThrough() throws {
        let command = try Run.parse(["--secret", "A", "--secret", "B", "--", "claude", "--help", "--secret", "C"])
        #expect(command.secrets == ["A", "B"])
        #expect(command.all == false)
        let request = RunCommandRun.request(secrets: command.secrets, all: command.all, captured: command.command)
        #expect(request == SecretRunRequest(secrets: ["A", "B"], all: false, command: ["claude", "--help", "--secret", "C"]))
    }

    @Test func parsesAllAndACommandWithoutTheSeparator() throws {
        let command = try Run.parse(["--all", "env"])
        #expect(command.all)
        #expect(RunCommandRun.request(secrets: [], all: true, captured: command.command).command == ["env"])
    }

    @Test func allAndSecretTogetherAreRejected() {
        #expect(throws: (any Error).self) { try Run.parse(["--all", "--secret", "A", "--", "env"]) }
    }

    @Test func refusalsAreOnePrefixedLine() {
        let line = RunCommandRun.refusalLine(.peerBindingUnavailable)
        #expect(line.hasPrefix("rv run: "))
        #expect(line.contains("\n") == false)
    }

    @Test func helpRoutesOnlyRunsOwnFlags() {
        #expect(HelpDispatch.topic(arguments: ["run", "--help"]) == .run)
        #expect(HelpDispatch.topic(arguments: ["help", "run"]) == .run)
        #expect(HelpDispatch.topic(arguments: ["run", "--secret", "A", "--all", "-h"]) == .run)
        #expect(HelpDispatch.topic(arguments: ["run", "--secret=A", "--help"]) == .run)
        #expect(HelpDispatch.topic(arguments: ["run", "--", "claude", "--help"]) == nil)
        #expect(HelpDispatch.topic(arguments: ["run", "claude", "--help"]) == nil)
    }

    @Test func helpSaysPlainlyItIsNotASandbox() {
        let text = HelpDispatch.text(.run, palette: colorOffPalette)
        #expect(text.contains("not a sandbox"))
        #expect(text.contains("Does not"))
        #expect(text.contains("Linux"))
        #expect(text.contains("128+N"))
    }
}
