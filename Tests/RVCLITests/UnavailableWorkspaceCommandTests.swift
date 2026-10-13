import ArgumentParser
import Foundation
import RVTheme
import Testing
@testable import RVCLI

/// UX-01: `workspace agent`, `workspace custom`, and `workspace abandon`
/// cannot succeed until operator permits and the authenticated service
/// mutation route exist. Help must mark them "(not yet available)" and
/// each refusal must name what is missing and what to do instead.
struct UnavailableWorkspaceCommandTests {
    @Test func workspaceHelpMarksUnavailableCommands() {
        let text = HelpDispatch.text(.workspace, palette: colorOffPalette)
        let lines = text.split(separator: "\n").map(String.init)
        for command in ["rv workspace agent", "rv workspace custom", "rv workspace abandon"] {
            let line = lines.first { $0.contains(command) }
            #expect(
                line?.contains("(not yet available)") == true,
                "\(command) help row must be marked (not yet available)"
            )
        }
        let custom = lines.first { $0.contains("rv workspace custom") }
        #expect(
            custom?.contains(
                "Launch an ad-hoc definition (not yet available); executable image verification is deferred"
            ) == true,
            "custom help must mark the launch unavailable, before image verification"
        )
        #expect(
            custom?.contains("deferred (not yet available)") == false,
            "a suffix on deferred must not satisfy the custom help marker"
        )
    }

    @Test func workspaceParserAbstractsMarkUnavailableCommands() {
        #expect(WorkspaceAgent.configuration.abstract.contains("(not yet available)"))
        #expect(WorkspaceCustom.configuration.abstract.contains("(not yet available)"))
        #expect(WorkspaceAbandon.configuration.abstract.contains("(not yet available)"))
    }

    @Test func abandonRefusalNamesMissingAuthorizationAndInspection() throws {
        var caught: ValidationError?
        do {
            try WorkspaceCommandRun.abandon("/tmp/ws")
        } catch let error as ValidationError {
            caught = error
        }
        let message = String(describing: try #require(caught))
        #expect(message.contains("not yet available"))
        #expect(message.contains("owner authorization"))
        #expect(message.contains("rv workspace status"))
    }

    #if os(macOS)
    @Test func agentRefusalNamesMissingPermitAndRunAlternative() throws {
        var caught: ValidationError?
        do {
            try WorkspaceCommandRun.runAgent(
                nil, definitionID: "test-agent", arguments: [], rows: nil, columns: nil
            )
        } catch let error as ValidationError {
            caught = error
        }
        let message = String(describing: try #require(caught))
        #expect(message.contains("not yet available"))
        #expect(message.contains("operator permit"))
        #expect(message.contains("rv workspace run"))
    }

    @Test func customRefusalNamesMissingPermitAndRunAlternative() throws {
        var caught: ValidationError?
        do {
            try WorkspaceCommandRun.runCustom(
                nil, command: ["/bin/true"],
                expectedContentDigestSHA256: String(repeating: "a", count: 64),
                rows: nil, columns: nil
            )
        } catch let error as ValidationError {
            caught = error
        }
        let message = String(describing: try #require(caught))
        #expect(message.contains("not yet available"))
        #expect(message.contains("operator permit"))
        #expect(message.contains("rv workspace run"))
    }
    #endif
}
