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
