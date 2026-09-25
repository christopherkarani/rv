import Foundation
import Testing
@testable import RVCLI

// MARK: - Byte-exact fresh merges (engine serialization proof)

private let claudeFreshBytes = """
{
  "hooks" : {
    "PreToolUse" : [
      {
        "hooks" : [
          {
            "command" : "RV_BINARY=\\/usr\\/local\\/bin\\/rv python3 \\/tmp\\/home\\/.claude\\/hooks\\/rv-guard.py",
            "timeout" : 90,
            "type" : "command"
          }
        ],
        "matcher" : "Bash"
      },
      {
        "hooks" : [
          {
            "command" : "RV_BINARY=\\/usr\\/local\\/bin\\/rv python3 \\/tmp\\/home\\/.claude\\/hooks\\/rv-guard.py",
            "timeout" : 90,
            "type" : "command"
          }
        ],
        "matcher" : "Read"
      },
      {
        "hooks" : [
          {
            "command" : "RV_BINARY=\\/usr\\/local\\/bin\\/rv python3 \\/tmp\\/home\\/.claude\\/hooks\\/rv-guard.py",
            "timeout" : 90,
            "type" : "command"
          }
        ],
        "matcher" : "Edit"
      },
      {
        "hooks" : [
          {
            "command" : "RV_BINARY=\\/usr\\/local\\/bin\\/rv python3 \\/tmp\\/home\\/.claude\\/hooks\\/rv-guard.py",
            "timeout" : 90,
            "type" : "command"
          }
        ],
        "matcher" : "Write"
      }
    ]
  }
}
"""

private let codexFreshBytes = """
{
  "hooks" : {
    "PreToolUse" : [
      {
        "hooks" : [
          {
            "command" : "python3 \\/tmp\\/home\\/.codex\\/hooks\\/rv-guard.py",
            "statusMessage" : "RV",
            "timeout" : 5,
            "type" : "command"
          }
        ],
        "matcher" : "Bash"
      }
    ]
  }
}
"""

private let cursorFreshBytes = """
{
  "hooks" : {
    "beforeShellExecution" : [
      {
        "command" : "python3 \\/tmp\\/home\\/.cursor\\/hooks\\/rv-guard.py",
        "failClosed" : true,
        "timeout" : 5
      }
    ],
    "preToolUse" : [
      {
        "command" : "python3 \\/tmp\\/home\\/.cursor\\/hooks\\/rv-guard.py",
        "failClosed" : true,
        "timeout" : 5
      }
    ]
  },
  "version" : 1
}
"""

@Test func mergeEngine_claudeFreshMergeIsByteExact() throws {
    let merged = try ClaudeSettingsMerge.merge(
        existingData: nil,
        rvPath: "/usr/local/bin/rv",
        adapterPath: "/tmp/home/.claude/hooks/rv-guard.py",
        force: false
    )
    #expect(merged.wrote)
    #expect(merged.data == Data(claudeFreshBytes.utf8))
}

@Test func mergeEngine_codexFreshMergeIsByteExact() throws {
    let merged = try CodexHooksMerge.merge(
        existingData: nil,
        adapterPath: "/tmp/home/.codex/hooks/rv-guard.py"
    )
    #expect(merged.wrote)
    #expect(merged.data == Data(codexFreshBytes.utf8))
}

@Test func mergeEngine_cursorFreshMergeIsByteExact() throws {
    let merged = try CursorHooksMerge.merge(
        existingData: nil,
        adapterPath: "/tmp/home/.cursor/hooks/rv-guard.py"
    )
    #expect(merged.wrote)
    #expect(merged.data == Data(cursorFreshBytes.utf8))
}

// MARK: - Synthetic descriptor behavior (engine tested once)

private let syntheticNested = HostWiringDescriptor(
    layout: .nested(hooksRootKey: "h", listKey: "L"),
    matchers: ["M1", "M2"],
    hookType: "cmd",
    isFingerprintedCommand: { $0.contains("ours") },
    buildEntry: { context, _ in
        HookEntry(command: "run \(context.adapterPath)", timeout: 7, type: "cmd")
    }
)

private let syntheticFlat = HostWiringDescriptor(
    layout: .flat(
        hooksRootKey: "h",
        listKeys: ["A", "B"],
        versionKey: "v",
        schemaVersion: 3
    ),
    matchers: [],
    hookType: nil,
    isFingerprintedCommand: { $0.contains("ours") },
    buildEntry: { context, _ in
        HookEntry(command: "run \(context.adapterPath)", timeout: 7, failClosed: true)
    }
)

private func syntheticContext() -> HookCommandContext {
    HookCommandContext(rvPath: nil, adapterPath: "/a/ours")
}

@Test func mergeEngine_nestedStripIsIdempotentAndKeepsForeign() throws {
    let existing = Data(
        """
        {"h":{"L":[{"matcher":"M1","hooks":[{"type":"cmd","command":"foreign","timeout":1},{"type":"cmd","command":"old ours","timeout":1}]}]}}
        """.utf8
    )
    let root = try HostHooksMergeEngine.parseRoot(existing)
    let once = HostHooksMergeEngine.stripFingerprinted(from: root, descriptor: syntheticNested)
    let twice = HostHooksMergeEngine.stripFingerprinted(from: once, descriptor: syntheticNested)
    #expect((once as NSDictionary) == (twice as NSDictionary))
    let list = ((once["h"] as? [String: Any])?["L"] as? [[String: Any]]).flatMap { $0 }
    let hooks = try #require(list?.first?["hooks"] as? [[String: Any]])
    #expect(hooks.count == 1)
    #expect(hooks[0]["command"] as? String == "foreign")
}

@Test func mergeEngine_nestedMergeAppendsOneEntryPerMatcher() throws {
    let merged = try HostHooksMergeEngine.merge(
        existingData: nil,
        descriptor: syntheticNested,
        context: syntheticContext()
    )
    #expect(merged.wrote)
    let root = try #require(
        JSONSerialization.jsonObject(with: merged.data) as? [String: Any]
    )
    let list = try #require((root["h"] as? [String: Any])?["L"] as? [[String: Any]])
    #expect(list.compactMap { $0["matcher"] as? String } == ["M1", "M2"])
    for entry in list {
        let hooks = try #require(entry["hooks"] as? [[String: Any]])
        #expect(hooks.count == 1)
        #expect(hooks[0]["command"] as? String == "run /a/ours")
    }
}

@Test func mergeEngine_nestedUninstallToNilAndDirtyBit() throws {
    let merged = try HostHooksMergeEngine.merge(
        existingData: nil,
        descriptor: syntheticNested,
        context: syntheticContext()
    )
    #expect(try HostHooksMergeEngine.uninstall(
        existingData: merged.data,
        descriptor: syntheticNested
    ) == nil)
    let again = try HostHooksMergeEngine.merge(
        existingData: merged.data,
        descriptor: syntheticNested,
        context: syntheticContext()
    )
    #expect(again.wrote == false)
    #expect(again.data == merged.data)
}

@Test func mergeEngine_flatMergeAddsVersionAndUninstallVersionOnlyIsNil() throws {
    let merged = try HostHooksMergeEngine.merge(
        existingData: nil,
        descriptor: syntheticFlat,
        context: syntheticContext()
    )
    let root = try #require(
        JSONSerialization.jsonObject(with: merged.data) as? [String: Any]
    )
    #expect(root["v"] as? Int == 3)
    #expect(try HostHooksMergeEngine.uninstall(
        existingData: merged.data,
        descriptor: syntheticFlat
    ) == nil)

    let pinned = Data("{\"v\":9,\"h\":{\"A\":[{\"command\":\"foreign\",\"timeout\":1}]}}".utf8)
    let kept = try HostHooksMergeEngine.merge(
        existingData: pinned,
        descriptor: syntheticFlat,
        context: syntheticContext()
    )
    let keptRoot = try #require(
        JSONSerialization.jsonObject(with: kept.data) as? [String: Any]
    )
    #expect(keptRoot["v"] as? Int == 9)
}

@Test func mergeEngine_willMergeSeesPreStripRoot() throws {
    let existing = Data(
        """
        {"h":{"L":[{"matcher":"M1","hooks":[{"type":"cmd","command":"old ours","timeout":1}]}]}}
        """.utf8
    )
    var seen = 0
    let merged = try HostHooksMergeEngine.merge(
        existingData: existing,
        descriptor: syntheticNested,
        context: syntheticContext(),
        willMerge: { root in
            seen = HostHooksMergeEngine.locateFingerprintedHooks(
                in: root,
                descriptor: syntheticNested
            ).count
        }
    )
    #expect(seen == 1)
    let located = HostHooksMergeEngine.locateFingerprintedHooks(
        in: try HostHooksMergeEngine.parseRoot(merged.data),
        descriptor: syntheticNested
    )
    #expect(located.count == 2)
}

@Test func mergeEngine_locateReportsMatcherAndListKey() throws {
    let claude = try ClaudeSettingsMerge.merge(
        existingData: nil,
        rvPath: "/r",
        adapterPath: "/c/hooks/rv-guard.py",
        force: false
    )
    let claudeLocated = HostHooksMergeEngine.locateFingerprintedHooks(
        in: try HostHooksMergeEngine.parseRoot(claude.data),
        descriptor: ClaudeSettingsMerge.wiringDescriptor
    )
    #expect(Set(claudeLocated.compactMap { $0.matcher }) == Set(ClaudeSettingsMerge.matchers))
    #expect(Set(claudeLocated.map { $0.listKey }) == [ClaudeSettingsMerge.preToolUseKey])

    let cursor = try CursorHooksMerge.merge(existingData: nil, adapterPath: "/u/rv-guard.py")
    let cursorLocated = HostHooksMergeEngine.locateFingerprintedHooks(
        in: try HostHooksMergeEngine.parseRoot(cursor.data),
        descriptor: CursorHooksMerge.wiringDescriptor
    )
    #expect(cursorLocated.allSatisfy { $0.matcher == nil })
    #expect(Set(cursorLocated.map { $0.listKey }) == [
        CursorHooksMerge.beforeShellKey,
        CursorHooksMerge.preToolUseKey,
    ])
}

@Test func mergeEngine_hookDictionaryOmitsNilExtras() {
    #expect(
        HostHooksMergeEngine.hookDictionary(HookEntry(command: "c", timeout: 1)) as NSDictionary
            == ["command": "c", "timeout": 1] as NSDictionary
    )
    let full = HostHooksMergeEngine.hookDictionary(
        HookEntry(command: "c", timeout: 1, type: "t", failClosed: true, statusMessage: "s")
    )
    #expect(full.keys.sorted() == ["command", "failClosed", "statusMessage", "timeout", "type"])
}

@Test func mergeEngine_unreadableIsFailClosed() {
    #expect(throws: HostHooksMergeError.unreadable) {
        _ = try HostHooksMergeEngine.merge(
            existingData: Data("[]".utf8),
            descriptor: syntheticNested,
            context: syntheticContext()
        )
    }
    #expect(throws: HostHooksMergeError.unreadable) {
        _ = try HostHooksMergeEngine.uninstall(
            existingData: Data("[]".utf8),
            descriptor: syntheticNested
        )
    }
}

@Test func mergeEngine_malformedBytesAreUnreadable() {
    let malformed = Data("not json{".utf8)
    #expect(throws: HostHooksMergeError.unreadable) {
        _ = try HostHooksMergeEngine.merge(
            existingData: malformed,
            descriptor: syntheticNested,
            context: syntheticContext()
        )
    }
    #expect(throws: HostHooksMergeError.unreadable) {
        _ = try HostHooksMergeEngine.uninstall(
            existingData: malformed,
            descriptor: syntheticNested
        )
    }
    #expect(throws: HostHooksMergeError.unreadable) {
        _ = try HostHooksMergeEngine.parseRoot(malformed)
    }
}

// MARK: - Occupancy + stale-legacy preserved (Claude inspection)

@Test func mergeEngine_claudeInspectionStatesPreserved() {
    #expect(ClaudeSettingsMerge.inspectionState(of: nil) == .absentFile)
    #expect(ClaudeSettingsMerge.inspectionState(of: Data("not json{".utf8)) == .occupied)
    #expect(ClaudeSettingsMerge.inspectionState(of: Data("[]".utf8)) == .occupied)
    let foreign = Data(
        """
        {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other","timeout":1}]}]}}
        """.utf8
    )
    #expect(ClaudeSettingsMerge.inspectionState(of: foreign) == .absentFile)
    let stale = Data(
        """
        {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/old/rv hook --host claude","timeout":10}]}]}}
        """.utf8
    )
    #expect(ClaudeSettingsMerge.inspectionState(of: stale) == .outdated)
    let bashOnly = Data(
        """
        {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"RV_BINARY=/r python3 /c/hooks/rv-guard.py","timeout":90}]}]}}
        """.utf8
    )
    #expect(ClaudeSettingsMerge.inspectionState(of: bashOnly) == .outdated)
    let guardForeign = Data(
        """
        {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 /opt/other/rv-guard.py","timeout":10}]}]}}
        """.utf8
    )
    #expect(ClaudeSettingsMerge.inspectionState(of: guardForeign) == .occupied)
}

@Test func mergeEngine_claudeWiredReportsBakedPath() throws {
    let merged = try ClaudeSettingsMerge.merge(
        existingData: nil,
        rvPath: "/usr/local/bin/rv",
        adapterPath: "/tmp/home/.claude/hooks/rv-guard.py",
        force: false
    )
    #expect(
        ClaudeSettingsMerge.inspectionState(of: merged.data)
            == .wired(bakedPath: "/usr/local/bin/rv")
    )
}

@Test func mergeEngine_claudeForceRewritesOccupied() throws {
    let occupied = Data(
        """
        {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"python3 /opt/other/rv-guard.py","timeout":10}]}]}}
        """.utf8
    )
    #expect(ClaudeSettingsMerge.inspectionState(of: occupied) == .occupied)
    let merged = try ClaudeSettingsMerge.merge(
        existingData: occupied,
        rvPath: "/r",
        adapterPath: "/c/hooks/rv-guard.py",
        force: true
    )
    #expect(merged.wrote)
    #expect(ClaudeSettingsMerge.inspectionState(of: merged.data) == .wired(bakedPath: "/r"))
}

@Test func mergeEngine_claudeStaleRewritesWithoutForce() throws {
    let stale = Data(
        """
        {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/old/rv hook --host claude","timeout":10}]}]}}
        """.utf8
    )
    let merged = try ClaudeSettingsMerge.merge(
        existingData: stale,
        rvPath: "/r",
        adapterPath: "/c/hooks/rv-guard.py",
        force: false
    )
    #expect(merged.wrote)
    #expect(ClaudeSettingsMerge.inspectionState(of: merged.data) == .wired(bakedPath: "/r"))
}

// MARK: - Merge -> uninstall round-trips keep foreign bytes

private func sortedReencode(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .prettyPrinted]
    )
}

@Test func mergeEngine_roundTripsKeepForeignBytes() throws {
    let claudeForeign = Data(
        """
        {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"other","timeout":1}]}]}}
        """.utf8
    )
    let claudeMerged = try ClaudeSettingsMerge.merge(
        existingData: claudeForeign,
        rvPath: "/r",
        adapterPath: "/c/hooks/rv-guard.py",
        force: false
    )
    #expect(
        try ClaudeSettingsMerge.uninstall(existingData: claudeMerged.data)
            == sortedReencode(claudeForeign)
    )

    let codexMerged = try CodexHooksMerge.merge(
        existingData: claudeForeign,
        adapterPath: "/x/hooks/rv-guard.py"
    )
    #expect(
        try CodexHooksMerge.uninstall(existingData: codexMerged.data)
            == sortedReencode(claudeForeign)
    )

    let cursorForeign = Data(
        """
        {"version":1,"hooks":{"beforeShellExecution":[{"command":"other","timeout":1}]}}
        """.utf8
    )
    let cursorMerged = try CursorHooksMerge.merge(
        existingData: cursorForeign,
        adapterPath: "/u/rv-guard.py"
    )
    #expect(
        try CursorHooksMerge.uninstall(existingData: cursorMerged.data)
            == sortedReencode(cursorForeign)
    )
}

@Test func mergeEngine_realDescriptorsAreIdempotent() throws {
    let claude = try ClaudeSettingsMerge.merge(
        existingData: nil,
        rvPath: "/r",
        adapterPath: "/c/hooks/rv-guard.py",
        force: false
    )
    #expect(claude.wrote)
    let claudeLocated = HostHooksMergeEngine.locateFingerprintedHooks(
        in: try HostHooksMergeEngine.parseRoot(claude.data),
        descriptor: ClaudeSettingsMerge.wiringDescriptor
    )
    #expect(claudeLocated.count == ClaudeSettingsMerge.matchers.count)
    let claudeAgain = try ClaudeSettingsMerge.merge(
        existingData: claude.data,
        rvPath: "/r",
        adapterPath: "/c/hooks/rv-guard.py",
        force: false
    )
    #expect(claudeAgain.wrote == false)
    #expect(claudeAgain.data == claude.data)

    let codex = try CodexHooksMerge.merge(existingData: nil, adapterPath: "/x/hooks/rv-guard.py")
    #expect(codex.wrote)
    let codexAgain = try CodexHooksMerge.merge(existingData: codex.data, adapterPath: "/x/hooks/rv-guard.py")
    #expect(codexAgain.wrote == false)
    #expect(codexAgain.data == codex.data)

    let cursor = try CursorHooksMerge.merge(existingData: nil, adapterPath: "/u/rv-guard.py")
    #expect(cursor.wrote)
    let cursorAgain = try CursorHooksMerge.merge(existingData: cursor.data, adapterPath: "/u/rv-guard.py")
    #expect(cursorAgain.wrote == false)
    #expect(cursorAgain.data == cursor.data)
}

@Test func mergeEngine_cursorIdempotentWithForeignHooksAndPinnedVersion() throws {
    let pinned = Data(
        """
        {"version":9,"hooks":{"beforeShellExecution":[{"command":"foreign","timeout":1}],"preToolUse":[{"command":"other","timeout":2}]}}
        """.utf8
    )
    let merged = try CursorHooksMerge.merge(existingData: pinned, adapterPath: "/u/rv-guard.py")
    #expect(merged.wrote)
    let root = try #require(
        JSONSerialization.jsonObject(with: merged.data) as? [String: Any]
    )
    #expect(root["version"] as? Int == 9)
    let again = try CursorHooksMerge.merge(existingData: merged.data, adapterPath: "/u/rv-guard.py")
    #expect(again.wrote == false)
    #expect(again.data == merged.data)
}

@Test func mergeEngine_freshUninstallRemovesFile() throws {
    let claude = try ClaudeSettingsMerge.merge(
        existingData: nil,
        rvPath: "/r",
        adapterPath: "/c/hooks/rv-guard.py",
        force: false
    )
    #expect(try ClaudeSettingsMerge.uninstall(existingData: claude.data) == nil)
    let codex = try CodexHooksMerge.merge(existingData: nil, adapterPath: "/x/rv-guard.py")
    #expect(try CodexHooksMerge.uninstall(existingData: codex.data) == nil)
    let cursor = try CursorHooksMerge.merge(existingData: nil, adapterPath: "/u/rv-guard.py")
    #expect(try CursorHooksMerge.uninstall(existingData: cursor.data) == nil)
}
