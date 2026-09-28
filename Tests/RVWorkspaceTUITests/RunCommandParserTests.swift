import Foundation
import Testing
@testable import RVWorkspaceTUI

@Test func runCommandParsesQuotesEscapesUnicodeAndEmptyArguments() throws {
    let parsed = try RunCommandParser.parse("tool 'two words' \"hé 🌍\" a\\ b ''").get()
    #expect(parsed.executable == "tool")
    #expect(parsed.arguments == ["two words", "hé 🌍", "a b", ""])
}

@Test func runCommandRejectsIncompleteOrAmbiguousShellSyntax() {
    #expect(RunCommandParser.parse("   ") == .failure(.empty))
    #expect(RunCommandParser.parse("tool 'unfinished") == .failure(.unterminatedQuote))
    #expect(RunCommandParser.parse("tool arg\\") == .failure(.trailingEscape))
    #expect(RunCommandParser.parse("tool x | other") == .failure(.unsupportedShellSyntax("|")))
    #expect(RunCommandParser.parse("tool x > out") == .failure(.unsupportedShellSyntax(">")))
}

@Test func explicitShellInvocationRetainsItsCommandAsOneArgument() throws {
    let parsed = try RunCommandParser.parse("sh -c 'echo hello | cat'").get()
    #expect(parsed.executable == "sh")
    #expect(parsed.arguments == ["-c", "echo hello | cat"])
    #expect(try RunCommandParser.parse("tool \\| literal").get().arguments == ["|", "literal"])
}

@Test func parseErrorsRenderAsHumanReadableOverlayText() {
    #expect(RunCommandParseError.empty.message == "Enter a command to run")
    #expect(RunCommandParseError.trailingEscape.message.contains("escape"))
    #expect(RunCommandParseError.unterminatedQuote.message == "Unterminated quote")
    #expect(RunCommandParseError.unsupportedShellSyntax("|").message.contains("|"))
    #expect(RunCommandParseError.unsupportedShellSyntax("|").message.contains("not supported"))
    #expect(RunCommandParseError.executableUnavailable.message.contains("not found"))
    for error: RunCommandParseError in [.empty, .trailingEscape, .unterminatedQuote, .unsupportedShellSyntax("|"), .executableUnavailable] {
        #expect(error.message.contains(String(describing: error)) == false)
    }
}

@Test func executableDiscoveryUsesOnlyAbsolutePathEntriesAndNeverRunsCandidates() throws {
    let parsed = try RunCommandParser.parse("mystery --flag").get()
    var checked: [String] = []
    let resolved = RunCommandParser.resolve(parsed, path: "relative:/opt/tools::/usr/bin") { candidate in
        checked.append(candidate)
        return candidate == "/opt/tools/mystery"
    }
    #expect(resolved == .success(ParsedRuntimeCommand(executable: "/opt/tools/mystery", arguments: ["--flag"])))
    #expect(checked == ["/opt/tools/mystery"])
    #expect(RunCommandParser.resolve(parsed, path: "/missing", isExecutable: { _ in false }) == .failure(.executableUnavailable))
}
