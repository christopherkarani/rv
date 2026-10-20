import Testing
@testable import RVCLI

// UX-06: a missing --resource-profile warning must name the remedy: the flag
// itself, the operator file where profile IDs are defined, and `rv init`,
// which generates a profile for the current project.
@Test func opencodeMissingProfileWarningNamesRemedy() {
    let warning = OpenCodeRun.missingProfileWarning
    #expect(warning.contains("--resource-profile <id>"))
    #expect(warning.contains("runtime-resources.json"))
    #expect(warning.contains("credentials are unstaged"))
    #expect(warning.contains("rv init"))
}

@Test func workspaceRunMissingProfileWarningNamesRemedy() {
    let warning = WorkspaceCommandRun.missingProfileWarning
    #expect(warning.contains("rv workspace run"))
    #expect(warning.contains("--resource-profile <id>"))
    #expect(warning.contains("runtime-resources.json"))
    #expect(warning.contains("credentials are unstaged"))
    #expect(warning.contains("rv init"))
}

@Test func workspaceRunWithoutProfileParsesAsUnprofiled() throws {
    let parsed = try WorkspaceRun.parse(["--", "/bin/echo", "hello"])
    #expect(parsed.resourceProfile == nil)
}
