import Testing
@testable import RVCLI
#if os(macOS)
import RVIsolation
#endif

@Test func workspaceRunParsesExplicitResourceProfileSeparatelyFromCommand() throws {
    let parsed = try WorkspaceRun.parse([
        "--workspace", "/private/tmp/project",
        "--resource-profile", "synthetic-a",
        "--", "/bin/echo", "hello",
    ])
    #expect(parsed.resourceProfile == "synthetic-a")
    #expect(parsed.command == ["--", "/bin/echo", "hello"] || parsed.command == ["/bin/echo", "hello"])
}

@Test func workspaceRunParsesHookTagSeparatelyFromCommand() throws {
    let parsed = try WorkspaceRun.parse([
        "--workspace", "/private/tmp/project",
        "--resource-profile", "synthetic-a",
        "--hook", "muse",
        "--", "/bin/echo", "hello",
    ])
    #expect(parsed.hook == "muse")
    #expect(parsed.resourceProfile == "synthetic-a")
}

#if os(macOS)
@Test func workspaceRunRejectsMalformedHookBeforeTouchingTheHost() {
    // The probe project does not exist: a hook error (not a host error)
    // proves validation runs before any host contact.
    do {
        try WorkspaceCommandRun.run(
            "/nonexistent-phase04-hook-probe", rows: 24, columns: 80,
            command: ["/bin/sh"], hook: "bad hook!"
        )
        Issue.record("a malformed hook tag must fail")
    } catch {
        #expect("\(error)".contains("hook must be an agent tag"))
    }
}

@Test func workspaceRunDenialEchoesRequestedProfile() {
    #expect(
        WorkspaceCommandRun.text(.resourceProfileUnavailable, resourceProfileID: "docs")
            == "runtime resource profile 'docs' is unavailable for this project"
    )
}

@Test func workspaceRunDenialWithoutIDStaysGeneric() {
    #expect(
        WorkspaceCommandRun.text(.resourceProfileUnavailable, resourceProfileID: nil)
            == "runtime resource profile is unavailable"
    )
}

@Test func workspaceRunOtherFailuresIgnoreProfileID() {
    #expect(
        WorkspaceCommandRun.text(.runtimeNotFound, resourceProfileID: "docs")
            == "runtime not found"
    )
}

@Test func workspaceRunStagingDenialNamesTheGrant() {
    #expect(
        WorkspaceCommandRun.text(
            .resourceStagingFailed("executable link 'grok'"), resourceProfileID: "agents"
        )
            == "runtime resource profile 'agents' staging failed: executable link 'grok' is unusable"
    )
    #expect(
        WorkspaceCommandRun.text(
            .resourceStagingFailed("executable link 'grok'"), resourceProfileID: nil
        )
            == "runtime resource staging failed: executable link 'grok' is unusable"
    )
}

@Test func workspaceAgentRejectsNulArgumentsBeforeTouchingTheHost() {
    // The probe project does not exist: a NUL error (not a host error)
    // proves argv validation runs before any host contact, mirroring `run`.
    do {
        try WorkspaceCommandRun.runAgent(
            "/nonexistent-phase8b-nul-probe", definitionID: "test-agent",
            arguments: ["ok", "has-\0-nul"], rows: 24, columns: 80
        )
        Issue.record("NUL bytes in agent arguments must fail")
    } catch {
        #expect("\(error)".contains("NUL"))
    }
}

@Test func workspaceCustomRejectsNulArgumentsBeforeTouchingTheHost() {
    do {
        try WorkspaceCommandRun.runCustom(
            "/nonexistent-phase8b-nul-probe",
            command: ["/bin/echo", "ok", "has-\0-nul"],
            expectedContentDigestSHA256: String(repeating: "a", count: 64),
            rows: 24, columns: 80
        )
        Issue.record("NUL bytes in custom arguments must fail")
    } catch {
        #expect("\(error)".contains("NUL"))
    }
}
#endif
