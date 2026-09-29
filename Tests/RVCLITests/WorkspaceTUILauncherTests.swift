import Foundation
import RVDomain
import Testing
@testable import RVCLI

#if os(macOS)
@Test func workspaceShellLauncherDisablesZshPromptSp() {
    let choices = WorkspaceTUICommand.launcherChoices()
    let shell = choices.first { $0.id == "shell" }
    let entry = try? #require(shell)
    #expect(entry?.hook == nil)
    if entry?.executable == "/bin/zsh" {
        #expect(entry?.arguments == ["-o", "NO_PROMPT_SP"])
    } else {
        #expect(entry?.executable == "/bin/sh")
        #expect(entry?.arguments == [])
    }
}

@Test func workspaceLauncherKeepsPresetsAsMetadataOnly() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let choices = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    #expect(choices.map(\.id) == ["shell", "run", "claude", "codex", "opencode", "muse"])
    #expect(choices[1].executable.isEmpty)
    #expect(choices.dropFirst(2).allSatisfy { $0.hook == nil })
    #expect(choices.dropFirst(2).allSatisfy { $0.arguments.isEmpty })
    #expect(choices.first { $0.id == "codex" }?.executable == "/test/bin/codex")
}

private func agentProfile(
    id: String = "agents",
    projects: [String] = ["/proj"],
    agents: [String] = [],
    links: [(String, String)] = [
        ("muse", "/real/muse-bin"),
        ("codex", "/real/codex"),
    ]
) -> RuntimeResourceProfile {
    RuntimeResourceProfile(
        id: id,
        projects: projects,
        agents: agents,
        executableLinks: links.map {
            RuntimeResourceProfile.ExecutableLink(name: $0.0, target: $0.1)
        }
    )
}

@Test func launcherProfilesEmptyLeavesChoicesUntouched() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(base, profiles: [], project: "/proj")
    #expect(enriched == base)
}

@Test func launcherProfilesIgnoreOtherProjects() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base, profiles: [agentProfile(projects: ["/elsewhere"])], project: "/proj"
    )
    #expect(enriched == base)
}

@Test func launcherProfilesAttachUniqueAgentMatch() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base, profiles: [agentProfile()], project: "/proj"
    )
    let muse = try? #require(enriched.first { $0.id == "muse" })
    #expect(muse?.executable == "/real/muse-bin")
    #expect(muse?.resourceProfileID == "agents")
    #expect(muse?.title == "muse · agents")
    let codex = try? #require(enriched.first { $0.id == "codex" })
    #expect(codex?.executable == "/real/codex")
    #expect(codex?.resourceProfileID == "agents")
    #expect(enriched.first { $0.id == "claude" } == nil)
    let run = try? #require(enriched.first { $0.id == "run" })
    #expect(run?.resourceProfileID == nil)
}

@Test func launcherProfilesLeaveAmbiguousAgentDirect() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let other = agentProfile(id: "other", links: [("muse", "/other/muse")])
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base, profiles: [agentProfile(), other], project: "/proj"
    )
    let muse = try? #require(enriched.first { $0.id == "muse" })
    #expect(muse?.executable == "/test/bin/muse")
    #expect(muse?.resourceProfileID == nil)
    #expect(muse?.title == "muse")
}

@Test func launcherProfilesAppendShellVariants() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base, profiles: [agentProfile()], project: "/proj"
    )
    let shell = try? #require(enriched.first { $0.id == "shell" })
    #expect(shell?.resourceProfileID == nil)
    let variant = try? #require(enriched.first { $0.id == "shell:agents" })
    #expect(variant?.title == "shell · agents")
    #expect(variant?.executable == shell?.executable)
    #expect(variant?.arguments == shell?.arguments)
    #expect(variant?.hook == shell?.hook)
    #expect(variant?.resourceProfileID == "agents")
    #expect(enriched.map(\.id) == ["shell", "run", "codex", "muse", "shell:agents"])
}

@Test func launcherProfilesDeriveMarkedAgentsWithoutBaseEntries() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    #expect(base.contains { $0.id == "grok" } == false)
    let profile = agentProfile(
        agents: ["grok"],
        links: [("grok", "/real/grok")]
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base, profiles: [profile], project: "/proj"
    )
    let grok = try? #require(enriched.first { $0.id == "grok" })
    #expect(grok?.title == "grok · agents")
    #expect(grok?.executable == "/real/grok")
    #expect(grok?.arguments == [])
    #expect(grok?.resourceProfileID == "agents")
    #expect(grok?.hook == HookHost.grok.rawValue)
}

@Test func launcherProfilesSkipAmbiguousDerivedMarks() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let first = agentProfile(agents: ["grok"], links: [("grok", "/real/grok")])
    let second = agentProfile(id: "other", agents: ["grok"], links: [("grok", "/other/grok")])
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base, profiles: [first, second], project: "/proj"
    )
    #expect(enriched.contains { $0.id == "grok" } == false)
}

@Test func launcherProfilesSkipMarksWithoutLinksAndReservedIds() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let profile = agentProfile(
        agents: ["hal", "shell", "run"],
        links: [("shell", "/real/shell")]
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base, profiles: [profile], project: "/proj"
    )
    #expect(enriched.contains { $0.id == "hal" } == false)
    #expect(enriched.filter { $0.id == "shell" }.count == 1)
    #expect(enriched.filter { $0.id == "run" }.count == 1)
}

@Test func launcherProfilesAttachHookToEnrichedAgents() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base, profiles: [agentProfile()], project: "/proj"
    )
    #expect(enriched.first { $0.id == "codex" }?.hook == HookHost.codex.rawValue)
    #expect(enriched.first { $0.id == "muse" }?.hook == "muse")
    #expect(enriched.first { $0.id == "shell:agents" }?.hook == nil)
}

@Test func launcherProfilesAttachStagingOnlyTagToUnclaimedHookNames() {
    let available: Set<String> = ["/test/bin/newagent"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    // "newagent" is not a base entry and names no HookHost; a marked link
    // still derives a row whose hook wire carries the agent tag for
    // credential staging. Shells stay hook-less.
    let profile = agentProfile(
        agents: ["newagent"],
        links: [("newagent", "/real/newagent")]
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base, profiles: [profile], project: "/proj"
    )
    #expect(enriched.first { $0.id == "newagent" }?.hook == "newagent")
    #expect(enriched.first { $0.id == "newagent" }?.resourceProfileID == "agents")
    #expect(enriched.first { $0.id == "shell:agents" }?.hook == nil)
}

@Test func launcherProfilesLoadFromOperatorHome() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-launcher-home-\(UUID().uuidString)", isDirectory: true)
    let config = home.appendingPathComponent(".config/rv", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: config.path)
    let file = config.appendingPathComponent("runtime-resources.json")
    try Data("""
    {"version":1,"profiles":[{"id":"agents","projects":["/proj"],"executableLinks":[],"readFiles":[],"readTrees":[],"writeTrees":[],"credentials":[],"environment":[]}]}
    """.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = try #require(HomePath(validating: home.path))
    #expect(WorkspaceTUICommand.loadResourceProfiles(home: directory).profiles.map(\.id) == ["agents"])
    #expect(WorkspaceTUICommand.loadResourceProfiles(home: nil) == .empty)
}

@Test func launcherAgentMarksClaimWithoutLinks() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base, profiles: [agentProfile(agents: ["muse"], links: [])], project: "/proj"
    )
    let muse = try? #require(enriched.first { $0.id == "muse" })
    #expect(muse?.executable == "/test/bin/muse")
    #expect(muse?.resourceProfileID == "agents")
    #expect(muse?.title == "muse · agents")
    #expect(enriched.first { $0.id == "codex" } == nil)
}

@Test func launcherAgentMarksBeatLinkNames() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base,
        profiles: [agentProfile(agents: ["codex"], links: [("muse", "/real/muse-bin")])],
        project: "/proj"
    )
    #expect(enriched.first { $0.id == "muse" } == nil)
    let codex = try? #require(enriched.first { $0.id == "codex" })
    #expect(codex?.executable == "/test/bin/codex")
    #expect(codex?.resourceProfileID == "agents")
    #expect(codex?.title == "codex · agents")
}

@Test func launcherMarksAmbiguityLeavesAgentDirect() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base,
        profiles: [
            agentProfile(id: "one", agents: ["muse"], links: []),
            agentProfile(id: "two", agents: ["muse"], links: []),
        ],
        project: "/proj"
    )
    let muse = try? #require(enriched.first { $0.id == "muse" })
    #expect(muse?.executable == "/test/bin/muse")
    #expect(muse?.resourceProfileID == nil)
    #expect(muse?.title == "muse")
    #expect(enriched.map(\.id) == ["shell", "run", "muse", "shell:one", "shell:two"])
}

@Test func launcherShellVariantsSortByIDWithDefaultFirst() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base,
        profiles: [
            agentProfile(id: "zeta", links: []),
            agentProfile(id: "alpha", links: []),
        ],
        project: "/proj",
        defaultProfile: "zeta"
    )
    let variants = enriched.filter { $0.id.hasPrefix("shell:") }
    #expect(variants.map(\.id) == ["shell:zeta", "shell:alpha"])
    #expect(variants.first?.title == "shell · zeta (default)")
    #expect(variants.last?.title == "shell · alpha")
    let shell = try? #require(enriched.first { $0.id == "shell" })
    #expect(shell?.title == "shell")
    #expect(shell?.resourceProfileID == nil)
    let run = try? #require(enriched.first { $0.id == "run" })
    #expect(run?.resourceProfileID == nil)
}

@Test func launcherUnknownDefaultIsIgnoredSilently() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base,
        profiles: [
            agentProfile(id: "zeta", links: []),
            agentProfile(id: "alpha", links: []),
        ],
        project: "/proj",
        defaultProfile: "nope"
    )
    #expect(enriched.map(\.id) == ["shell", "run", "shell:alpha", "shell:zeta"])
    #expect(enriched.allSatisfy { $0.title.contains("(default)") == false })
}

@Test func launcherProfilesLoadDefaultFromOperatorHome() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-launcher-home-\(UUID().uuidString)", isDirectory: true)
    let config = home.appendingPathComponent(".config/rv", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: config.path)
    let file = config.appendingPathComponent("runtime-resources.json")
    try Data("""
    {"version":1,"defaultProfile":"docs","profiles":[{"id":"docs","projects":["/proj"],"executableLinks":[],"readFiles":[],"readTrees":[],"writeTrees":[],"credentials":[],"environment":[]}]}
    """.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = try #require(HomePath(validating: home.path))
    let policy = WorkspaceTUICommand.loadResourceProfiles(home: directory)
    #expect(policy.profiles.map(\.id) == ["docs"])
    #expect(policy.defaultProfile == "docs")
}

@Test func launcherChoicesNeverDeriveHooksFromExecutables() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let choices = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    #expect(choices.map(\.id) == ["shell", "run", "claude", "codex", "opencode", "muse"])
    #expect(choices.allSatisfy { $0.hook == nil })
}

@Test func launcherProfilesAttachHooksFromMarksOnly() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base,
        profiles: [
            agentProfile(),
            agentProfile(id: "other", links: [("muse", "/other/muse")]),
        ],
        project: "/proj",
        defaultProfile: "other"
    )
    // A claimed row carries its id as the hook wire (hook protocol when
    // the id names a HookHost, staging-only otherwise); the mark is
    // operator declaration, never executable inference. Ambiguous and
    // direct rows, shell variants, the plain shell, and the run box stay
    // hook-less.
    #expect(enriched.first { $0.id == "codex" }?.hook == HookHost.codex.rawValue)
    #expect(enriched.first { $0.id == "muse" }?.hook == nil)
    #expect(enriched.first { $0.id == "shell:agents" }?.hook == nil)
    #expect(enriched.first { $0.id == "shell:other" }?.hook == nil)
    #expect(enriched.first { $0.id == "shell" }?.hook == nil)
    #expect(enriched.first { $0.id == "run" }?.hook == nil)
    #expect(enriched.first { $0.id == "codex" }?.resourceProfileID == "agents")
    #expect(enriched.first { $0.id == "run" }?.resourceProfileID == nil)
}

@Test func launcherProfilesPreserveStaticEntryHook() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    var base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    guard let index = base.firstIndex(where: { $0.id == "opencode" }) else {
        Issue.record("launcher must offer an opencode row")
        return
    }
    base[index].hook = "opencode"
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base,
        profiles: [agentProfile(agents: ["opencode"], links: [])],
        project: "/proj"
    )
    // A static per-entry hook survives the profile rewrite: hook and profile
    // travel the launch path together, neither derived from the other.
    let opencode = try? #require(enriched.first { $0.id == "opencode" })
    #expect(opencode?.hook == "opencode")
    #expect(opencode?.resourceProfileID == "agents")
    #expect(opencode?.title == "opencode · agents")
}

@Test func launcherDerivedFromPolicyListsClaimedAndMarkedAgents() {
    let available: Set<String> = ["/test/bin/claude", "/test/bin/codex", "/test/bin/opencode", "/test/bin/muse"]
    let base = WorkspaceTUICommand.launcherChoices(
        path: "/test/bin:/other/bin",
        isExecutable: { available.contains($0) }
    )
    let profile = agentProfile(
        agents: ["muse", "codex", "claude", "opencode", "grok"],
        links: [
            ("muse", "/real/muse-bin"),
            ("codex", "/real/codex"),
            ("claude", "/real/claude"),
            ("opencode", "/real/opencode"),
            ("grok", "/real/grok"),
        ]
    )
    let enriched = WorkspaceTUICommand.applyingResourceProfiles(
        base, profiles: [profile], project: "/proj", defaultProfile: "agents"
    )
    // Claimed base entries keep known order, marked-only names derive
    // their own rows, and the default shell variant closes the list.
    // Nothing unclaimed survives: the rows are derived, not annotated.
    #expect(enriched.map(\.id) == [
        "shell", "run", "claude", "codex", "opencode", "muse", "grok", "shell:agents",
    ])
    #expect(enriched.first { $0.id == "grok" }?.title == "grok · agents")
    #expect(enriched.first { $0.id == "grok" }?.hook == HookHost.grok.rawValue)
    #expect(enriched.first { $0.id == "shell:agents" }?.title == "shell · agents (default)")
    #expect(enriched.dropFirst(2).allSatisfy { $0.resourceProfileID == "agents" })
}
#endif
