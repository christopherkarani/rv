import Foundation
import RVDomain
import Testing
@testable import RVCLI

// MARK: - Shared merge/inspect policy (M1 seam)

/// Per-host case for parameterizing the shared policy over both merge hosts.
private enum SharedMergeHost: CaseIterable, Sendable {
    case claude
    case antigravity

    var descriptor: SettingsMergeDescriptor {
        switch self {
        case .claude:
            ClaudeSettingsMerge.mergeDescriptor
        case .antigravity:
            AntigravityHooksMerge.mergeDescriptor
        }
    }

    var shellMatcher: String {
        switch self {
        case .claude:
            ClaudeSettingsMerge.matcher
        case .antigravity:
            AntigravityHooksMerge.matcher
        }
    }

    var timeout: Int {
        switch self {
        case .claude:
            ClaudeSettingsMerge.timeout
        case .antigravity:
            AntigravityHooksMerge.timeout
        }
    }

    /// Wraps hook-entry fragments into this host's document shape.
    func document(_ entries: String) -> Data {
        switch self {
        case .claude:
            Data("{\"hooks\":{\"PreToolUse\":[\(entries)]}}".utf8)
        case .antigravity:
            Data("{\"rv-guard\":{\"enabled\":true,\"PreToolUse\":[\(entries)]}}".utf8)
        }
    }
}

private func currentEntry(matcher: String, timeout: Int) -> String {
    "{\"matcher\":\"\(matcher)\",\"hooks\":[{\"type\":\"command\",\"command\":\"RV_BINARY=/r python3 /c/hooks/rv-guard.py\",\"timeout\":\(timeout)}]}"
}

private func foreignEntry(matcher: String) -> String {
    "{\"matcher\":\"\(matcher)\",\"hooks\":[{\"type\":\"command\",\"command\":\"other\",\"timeout\":1}]}"
}

private func tamperedEntry(matcher: String, timeout: Int) -> String {
    "{\"matcher\":\"\(matcher)\",\"hooks\":[{\"type\":\"command\",\"command\":\"python3 /opt/other/rv-guard.py\",\"timeout\":\(timeout)}]}"
}

@Test func sharedMerge_hookCommandIsSingleSite() {
    let expected = "RV_BINARY=/r python3 /c/hooks/rv-guard.py"
    #expect(SettingsMergePolicy.hookCommand(rvPath: "/r", adapterPath: "/c/hooks/rv-guard.py") == expected)
    #expect(ClaudeSettingsMerge.hookCommand(rvPath: "/r", adapterPath: "/c/hooks/rv-guard.py") == expected)
    #expect(AntigravityHooksMerge.hookCommand(rvPath: "/r", adapterPath: "/c/hooks/rv-guard.py") == expected)
}

@Test func sharedMerge_adapterPathBuildersDelegate() {
    #expect(
        ClaudeSettingsMerge.adapterPath(settingsPath: "/h/.claude/settings.json")
            == SettingsMergePolicy.adapterPath(
                configPath: "/h/.claude/settings.json",
                descriptor: ClaudeSettingsMerge.mergeDescriptor
            )
    )
    #expect(
        AntigravityHooksMerge.adapterPath(hooksPath: "/h/.gemini/config/hooks.json")
            == SettingsMergePolicy.adapterPath(
                configPath: "/h/.gemini/config/hooks.json",
                descriptor: AntigravityHooksMerge.mergeDescriptor
            )
    )
    #expect(
        SettingsMergePolicy.adapterPath(
            configPath: "/h/.claude/settings.json",
            descriptor: ClaudeSettingsMerge.mergeDescriptor
        ) == "/h/.claude/hooks/rv-guard.py"
    )
}

@Test func sharedMerge_inspectionMatrix() {
    for host in SharedMergeHost.allCases {
        let descriptor = host.descriptor
        #expect(
            SettingsMergePolicy.inspectionState(of: nil, descriptor: descriptor) == .absentFile,
            "\(host) nil data"
        )
        #expect(
            SettingsMergePolicy.inspectionState(of: Data("not json{".utf8), descriptor: descriptor)
                == .occupied,
            "\(host) malformed data"
        )
        #expect(
            SettingsMergePolicy.inspectionState(of: Data("[]".utf8), descriptor: descriptor) == .occupied,
            "\(host) non-object data"
        )
        #expect(
            SettingsMergePolicy.inspectionState(
                of: host.document(foreignEntry(matcher: host.shellMatcher)),
                descriptor: descriptor
            ) == .absentFile,
            "\(host) foreign hooks"
        )
        #expect(
            SettingsMergePolicy.inspectionState(
                of: host.document(tamperedEntry(matcher: host.shellMatcher, timeout: host.timeout)),
                descriptor: descriptor
            ) == .occupied,
            "\(host) tampered guard"
        )
        #expect(
            SettingsMergePolicy.inspectionState(
                of: host.document(currentEntry(matcher: host.shellMatcher, timeout: host.timeout)),
                descriptor: descriptor
            ) == .outdated,
            "\(host) partial matchers"
        )
        let full = descriptor.matchers.map {
            currentEntry(matcher: $0, timeout: host.timeout)
        }.joined(separator: ",")
        #expect(
            SettingsMergePolicy.inspectionState(of: host.document(full), descriptor: descriptor)
                == .wired(bakedPath: "/r"),
            "\(host) full current coverage"
        )
    }
}

@Test func sharedMerge_staleLegacyIsClaudeOnly() {
    let claude = SharedMergeHost.claude
    let stale = "{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"/old/rv hook --host claude\",\"timeout\":10}]}"
    #expect(
        SettingsMergePolicy.inspectionState(
            of: claude.document(stale),
            descriptor: claude.descriptor
        ) == .outdated
    )
    let mixed = stale + "," + tamperedEntry(matcher: "Bash", timeout: 10)
    #expect(
        SettingsMergePolicy.inspectionState(
            of: claude.document(mixed),
            descriptor: claude.descriptor
        ) == .occupied
    )
    let antigravity = SharedMergeHost.antigravity
    let legacyCommand = "/old/rv hook --host claude"
    #expect(
        SettingsMergePolicy.bakedRvPath(in: legacyCommand, descriptor: claude.descriptor) == "/old/rv"
    )
    #expect(
        SettingsMergePolicy.bakedRvPath(in: legacyCommand, descriptor: antigravity.descriptor) == nil
    )
    #expect(ClaudeSettingsMerge.bakedRvPath(in: legacyCommand) == "/old/rv")
    #expect(AntigravityHooksMerge.bakedRvPath(in: legacyCommand) == nil)
    let legacyHook = JSONValue.object([
        "type": .string("command"),
        "command": .string(legacyCommand),
        "timeout": .number(10),
    ])
    #expect(SettingsMergePolicy.isStaleLegacyHook(legacyHook, descriptor: claude.descriptor))
    #expect(
        SettingsMergePolicy.isStaleLegacyHook(legacyHook, descriptor: antigravity.descriptor) == false
    )
    #expect(ClaudeSettingsMerge.isStaleLegacyHook(legacyHook))
}

@Test func sharedMerge_occupiedNeedsForce() throws {
    for host in SharedMergeHost.allCases {
        let occupied = host.document(
            tamperedEntry(matcher: host.shellMatcher, timeout: host.timeout)
        )
        #expect(
            SettingsMergePolicy.inspectionState(of: occupied, descriptor: host.descriptor) == .occupied
        )
        #expect(throws: SettingsMergeError.occupiedWithoutForce) {
            _ = try SettingsMergePolicy.merge(
                existingData: occupied,
                descriptor: host.descriptor,
                rvPath: "/r",
                adapterPath: "/c/hooks/rv-guard.py",
                force: false
            )
        }
        let merged = try SettingsMergePolicy.merge(
            existingData: occupied,
            descriptor: host.descriptor,
            rvPath: "/r",
            adapterPath: "/c/hooks/rv-guard.py",
            force: true
        )
        #expect(merged.wrote)
        #expect(
            SettingsMergePolicy.inspectionState(of: merged.data, descriptor: host.descriptor)
                == .wired(bakedPath: "/r")
        )
    }
}

@Test func sharedMerge_outdatedRewritesWithoutForce() throws {
    let claude = SharedMergeHost.claude
    let stale = claude.document(
        "{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"/old/rv hook --host claude\",\"timeout\":10}]}"
    )
    #expect(
        SettingsMergePolicy.inspectionState(of: stale, descriptor: claude.descriptor) == .outdated
    )
    let claudeMerged = try SettingsMergePolicy.merge(
        existingData: stale,
        descriptor: claude.descriptor,
        rvPath: "/r",
        adapterPath: "/c/hooks/rv-guard.py",
        force: false
    )
    #expect(claudeMerged.wrote)

    let antigravity = SharedMergeHost.antigravity
    let partial = antigravity.document(
        currentEntry(matcher: antigravity.shellMatcher, timeout: antigravity.timeout)
    )
    #expect(
        SettingsMergePolicy.inspectionState(of: partial, descriptor: antigravity.descriptor)
            == .outdated
    )
    let antigravityMerged = try SettingsMergePolicy.merge(
        existingData: partial,
        descriptor: antigravity.descriptor,
        rvPath: "/r",
        adapterPath: "/c/hooks/rv-guard.py",
        force: false
    )
    #expect(antigravityMerged.wrote)
}

@Test func sharedMerge_matchesPerHostMergeBytes() throws {
    for host in SharedMergeHost.allCases {
        let shared = try SettingsMergePolicy.merge(
            existingData: nil,
            descriptor: host.descriptor,
            rvPath: "/r",
            adapterPath: "/c/hooks/rv-guard.py",
            force: false
        )
        let own: (data: Data, wrote: Bool)
        switch host {
        case .claude:
            own = try ClaudeSettingsMerge.merge(
                existingData: nil,
                rvPath: "/r",
                adapterPath: "/c/hooks/rv-guard.py",
                force: false
            )
        case .antigravity:
            own = try AntigravityHooksMerge.merge(
                existingData: nil,
                rvPath: "/r",
                adapterPath: "/c/hooks/rv-guard.py",
                force: false
            )
        }
        #expect(shared.data == own.data)
        #expect(shared.wrote == own.wrote)
    }
}
