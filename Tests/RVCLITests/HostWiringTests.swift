import Foundation
import RVDomain
import RVPresentation
import Testing
@testable import RVCLI

@Test func hostWiring_claudeFileToolMatchersAreWired() throws {
    let bytes = try ClaudeSettingsMerge.merge(
        existingData: nil,
        rvPath: "/usr/local/bin/rv",
        adapterPath: "/tmp/rv-t1/.claude/hooks/rv-guard.py",
        force: false
    ).data

    #expect(
        HostWiring.fileTools(host: .claude, adapterBytes: bytes, companionJSON: nil) == .wired
    )
}

@Test func hostWiring_claudeWiredAdapterWithoutFileToolMatchersIsShellOnly() throws {
    let bytes = try claudeSettings(matchers: [ClaudeSettingsMerge.matcher])

    #expect(
        HostWiring.fileTools(host: .claude, adapterBytes: bytes, companionJSON: nil) == .shellOnly
    )
}

@Test func hostWiring_cursorCompanionFileToolEntryIsWired() throws {
    let companion = try CursorHooksMerge.merge(
        existingData: nil,
        adapterPath: "/tmp/rv-t1/.cursor/hooks/rv-guard.py"
    ).data

    #expect(
        HostWiring.fileTools(
            host: .cursor,
            adapterBytes: Data("{}".utf8),
            companionJSON: companion
        ) == .wired
    )
}

@Test func hostWiring_cursorCompanionWithoutFileToolEntryIsShellOnly() throws {
    let companion = try cursorCompanionWithoutFileToolEntry()

    #expect(
        HostWiring.fileTools(
            host: .cursor,
            adapterBytes: Data("{}".utf8),
            companionJSON: companion
        ) == .shellOnly
    )
}

@Test func hostWiring_cursorMissingCompanionIsShellOnly() {
    #expect(
        HostWiring.fileTools(
            host: .cursor,
            adapterBytes: Data("{}".utf8),
            companionJSON: nil
        ) == .shellOnly
    )
}

@Test func hostWiring_cursorCompanionWithoutWiredAdapterIsNotApplicable() throws {
    let companion = try CursorHooksMerge.merge(
        existingData: nil,
        adapterPath: "/tmp/rv-t1/.cursor/hooks/rv-guard.py"
    ).data

    #expect(
        HostWiring.fileTools(host: .cursor, adapterBytes: nil, companionJSON: companion)
            == .notApplicable
    )
}

@Test(arguments: [HookHost.pi, .opencode, .openclaw, .hermes, .codex] as [HookHost])
func hostWiring_hostsWithoutFileToolDoorIgnoreBytes(_ host: HookHost) {
    #expect(
        HostWiring.fileTools(
            host: host,
            adapterBytes: Data("not-json".utf8),
            companionJSON: Data("{}".utf8)
        ) == .notApplicable
    )
}

@Test func hostWiring_fileToolHostsWithNilAdapterBytesAreNotApplicable() {
    #expect(
        HostWiring.fileTools(host: .claude, adapterBytes: nil, companionJSON: nil)
            == .notApplicable
    )
    #expect(
        HostWiring.fileTools(host: .grok, adapterBytes: nil, companionJSON: nil)
            == .notApplicable
    )
}

@Test func hostWiring_applyClaudeCurrentMatchers_fileToolsOnReturnedDataEqualsApplyAndIsWired() throws {
    let rvPath = "/usr/local/bin/rv"
    let adapterPath = "/tmp/rv-t2/.claude/hooks/rv-guard.py"
    let applied = try HostWiring.applyClaude(
        existing: nil,
        rvPath: rvPath,
        adapterPath: adapterPath
    )
    let inspected = HostWiring.fileTools(
        host: .claude,
        adapterBytes: applied.data,
        companionJSON: nil
    )
    #expect(inspected == applied.fileTools)
    #expect(applied.fileTools == .wired)
    let merged = try ClaudeSettingsMerge.merge(
        existingData: nil,
        rvPath: rvPath,
        adapterPath: adapterPath,
        force: false
    )
    #expect(applied.data == merged.data)
    #expect(applied.wrote == merged.wrote)
}

@Test func hostWiring_applyCursorCompanion_fileToolsOnReturnedDataEqualsApplyAndIsWired() throws {
    let adapterPath = "/tmp/rv-t2/.cursor/hooks/rv-guard.py"
    let applied = try HostWiring.applyCursor(existing: nil, adapterPath: adapterPath)
    let inspected = HostWiring.fileTools(
        host: .cursor,
        adapterBytes: applied.data,
        companionJSON: applied.data
    )
    #expect(inspected == applied.fileTools)
    #expect(applied.fileTools == .wired)
    let merged = try CursorHooksMerge.merge(existingData: nil, adapterPath: adapterPath)
    #expect(applied.data == merged.data)
    #expect(applied.wrote == merged.wrote)
}

@Test func hostWiring_applyGrokOpenPreToolUse_fileToolsOnReturnedDataEqualsApplyAndIsWired() {
    let rendered = Data(
        """
        {"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/usr/local/bin/rv hook --host grok","timeout":5}]}]}}
        """.utf8
    )
    let applied = HostWiring.applyGrok(existing: nil, rendered: rendered)
    let inspected = HostWiring.fileTools(
        host: .grok,
        adapterBytes: applied.data,
        companionJSON: nil
    )
    #expect(inspected == applied.fileTools)
    #expect(applied.fileTools == .wired)
    #expect(applied.data == rendered)
    #expect(applied.wrote)
}

private func claudeSettings(matchers: [String]) throws -> Data {
    let root: [String: Any] = [
        ClaudeSettingsMerge.hooksRootKey: [
            ClaudeSettingsMerge.preToolUseKey: matchers.map { matcher in
                ClaudeSettingsMerge.rvEntry(
                    rvPath: "/usr/local/bin/rv",
                    adapterPath: "/tmp/rv-t1/.claude/hooks/rv-guard.py",
                    matcher: matcher
                )
            },
        ],
    ]
    return try JSONSerialization.data(withJSONObject: root)
}

private func cursorCompanionWithoutFileToolEntry() throws -> Data {
    let adapterPath = "/tmp/rv-t1/.cursor/hooks/rv-guard.py"
    let root: [String: Any] = [
        CursorHooksMerge.versionKey: CursorHooksMerge.schemaVersion,
        CursorHooksMerge.hooksRootKey: [
            CursorHooksMerge.beforeShellKey: [CursorHooksMerge.rvEntry(adapterPath: adapterPath)],
        ],
    ]
    return try JSONSerialization.data(withJSONObject: root)
}
