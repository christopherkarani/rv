import Foundation
import RVIsolation
import RVTheme
import Testing
@testable import RVCLI

@Suite("rv run")
struct RunCommandTests {
    @Test func registeredAndDocumented() {
        #expect(RV.configuration.subcommands.contains { $0.configuration.commandName == "run" })
        #expect(HelpDispatch.topic(arguments: ["run", "--help"]) == .run)
        #expect(HelpDispatch.topic(arguments: ["help", "run"]) == .run)
        #expect(HelpDispatch.topic(arguments: ["run", "--", "--help"]) == nil)
        let help = HelpDispatch.text(.run, palette: colorOffPalette)
        #expect(help.contains("rv run"))
        #expect(help.contains("Agent-tagged secrets do not stage"))
    }

    @Test func parsesPassthroughAfterDoubleDash() throws {
        let parsed = try Run.parse(["--resource-profile", "main", "--", "python", "-c", "print(1)"])
        #expect(parsed.resourceProfile == "main")
        #expect(parsed.command == ["--", "python", "-c", "print(1)"])
    }

    @Test func prepareResolvesAbsolutePathAndPATH() throws {
        let environment = ["PATH": "/bin:/usr/bin"]
        let absolute = try RunRun.prepare(
            command: ["/bin/sh", "-c", "true"], workspace: "/tmp", environment: environment).get()
        #expect(absolute.executable.hasSuffix("/sh"))
        #expect(absolute.arguments == ["-c", "true"])
        let searched = try RunRun.prepare(
            command: ["sh", "-c", "true"], workspace: "/tmp", environment: environment).get()
        #expect(searched.executable.hasPrefix("/"))
        #expect(searched.executable.hasSuffix("/sh"))
    }

    @Test func prepareRejectsMissingRelativeAndEmpty() {
        let environment = ["PATH": "/bin:/usr/bin"]
        guard case .failure(.executableUnavailable(let name)) = RunRun.prepare(
            command: ["definitely-not-a-command-xyz"], workspace: "/tmp", environment: environment)
        else {
            Issue.record("missing command must be unavailable")
            return
        }
        #expect(name == "definitely-not-a-command-xyz")
        guard case .failure(.executableMustBeAbsolute) = RunRun.prepare(
            command: ["./local.sh"], workspace: "/tmp", environment: environment)
        else {
            Issue.record("relative path must be refused")
            return
        }
        guard case .failure(.emptyCommand) = RunRun.prepare(
            command: [], workspace: "/tmp", environment: environment)
        else {
            Issue.record("empty command must be refused")
            return
        }
        guard case .failure(.workspaceMustBeAbsolute) = RunRun.prepare(
            command: ["sh"], workspace: "relative", environment: environment)
        else {
            Issue.record("relative workspace must be refused")
            return
        }
    }

    @Test func opencodeResolutionUnchangedByGeneralization() {
        let environment = ["PATH": "/bin:/usr/bin"]
        // No opencode in /bin or /usr/bin on the test host: unavailable, as before.
        guard case .failure(.executableUnavailable) = OpenCodeRun.resolveExecutable(nil, environment: environment) else {
            // Hosts with opencode in /usr/bin resolve it; either way the
            // generalized form must agree.
            #expect(OpenCodeRun.resolveExecutable(nil, environment: environment)
                == OpenCodeRun.resolveExecutable(nil, named: "opencode", environment: environment))
            return
        }
        guard case .failure(.executableUnavailable) = OpenCodeRun.resolveExecutable(
            nil, named: "opencode", environment: environment) else {
            Issue.record("generalized resolver disagrees with the opencode form")
            return
        }
    }

    @Test func unreadableConfigurationIsNotZeroBindings() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-run-home-\(UUID().uuidString)", isDirectory: true)
        let config = home.appendingPathComponent(".config/rv", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(RunRun.dotenvBoundCount(environment: ["HOME": home.path]) == 0)
        try Data("{not json".utf8).write(to: config.appendingPathComponent("secrets.json"))
        #expect(RunRun.dotenvBoundCount(environment: ["HOME": home.path]) == nil)
    }

    @Test func dotenvBoundCountAndRefusalWording() {
        let configuration = SecretsConfiguration(secrets: [
            SecretDefinition(name: "A", source: .dotenv(path: "/p/.env", variable: "A"), delivery: .environment),
            SecretDefinition(name: "B", source: .dotenv(path: "/p/.env", variable: "B"), delivery: .environment),
            SecretDefinition(name: "C", source: .hostEnvironment(variable: "C"), delivery: .environment),
        ])
        #expect(RunRun.dotenvBoundCount(in: configuration) == 2)
        let refusal = RunRun.missingProfileRefusal(dotenvBoundCount: 2)
        #expect(refusal.contains("2 dotenv-bound secrets would not stage"))
        #expect(refusal.contains("--resource-profile"))
        #expect(RunRun.missingProfileRefusal(dotenvBoundCount: 1).contains("1 dotenv-bound secret would"))
    }

}
