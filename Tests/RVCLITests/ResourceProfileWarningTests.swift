import Testing
@testable import RVCLI

// UX-06: a missing --resource-profile warning must name the remedy. No CLI
// command lists profiles on this base, so the remedy is the flag itself plus
// the operator file where profile IDs are defined.
@Test func opencodeMissingProfileWarningNamesRemedy() {
    let warning = OpenCodeRun.missingProfileWarning
    #expect(warning.contains("--resource-profile <id>"))
    #expect(warning.contains("runtime-resources.json"))
    #expect(warning.contains("credentials are unstaged"))
}

@Test func workspaceRunMissingProfileWarningNamesRemedy() {
    let warning = WorkspaceCommandRun.missingProfileWarning
    #expect(warning.contains("rv workspace run"))
    #expect(warning.contains("--resource-profile <id>"))
    #expect(warning.contains("runtime-resources.json"))
    #expect(warning.contains("credentials are unstaged"))
}

@Test func workspaceRunWithoutProfileParsesAsUnprofiled() throws {
    let parsed = try WorkspaceRun.parse(["--", "/bin/echo", "hello"])
    #expect(parsed.resourceProfile == nil)
}
