import Testing
import RVDomain
@testable import RVEngine

private struct SelectiveEngine: PatternEngine {
    var rejected: Set<String>

    func compile(_ pattern: String) throws(PatternCompileError) -> String {
        if rejected.contains(pattern) {
            throw .invalidPattern(name: pattern, message: "rejected")
        }
        return pattern
    }

    func matches(_ compiled: String, in text: String) -> Bool { false }

    func firstMatch(_ compiled: String, in text: String) -> Range<String.Index>? { nil }
}

private func pack(
    _ id: PackID,
    safe: [String],
    destructive: [(name: String, severity: Severity)] = []
) -> PackSnapshot {
    PackSnapshot(
        id: id,
        name: id.rawValue,
        description: "test",
        keywords: [],
        safe: safe.map { NamedPattern(name: $0, pattern: $0) },
        destructive: destructive.map {
            DestructiveRule(
                name: $0.name,
                pattern: $0.name,
                severity: $0.severity,
                reason: "reason",
                explanation: nil
            )
        }
    )
}

@Test func compile_quarantinesRejectedSafePatterns() throws {
    let result = try CompiledPacks<String>.compile(
        packs: [pack(.coreGit, safe: ["ok", "bad"])],
        using: SelectiveEngine(rejected: ["bad"])
    )
    #expect(result.packs[0].safe.map(\.name) == ["ok"])
    #expect(result.quarantined == [RuleID(pack: .coreGit, pattern: "bad")])
}

@Test func compile_requiredDestructiveFailureThrowsTypedError() {
    #expect(
        throws: PatternCompileError.invalidPattern(
            name: "core.git:reset-hard",
            message: "required pattern failed to compile"
        )
    ) {
        try CompiledPacks<String>.compile(
            packs: [pack(.coreGit, safe: [], destructive: [("reset-hard", .critical)])],
            using: SelectiveEngine(rejected: ["reset-hard"])
        )
    }
}

@Test func compile_nonRequiredDestructiveFailureQuarantines() throws {
    let result = try CompiledPacks<String>.compile(
        packs: [pack(.coreGit, safe: [], destructive: [("noise", .low)])],
        using: SelectiveEngine(rejected: ["noise"])
    )
    #expect(result.packs[0].destructive.isEmpty)
    #expect(result.quarantined == [RuleID(pack: .coreGit, pattern: "noise")])
}

@Test func compiledPackIndexPreservesEnabledOrderAndDuplicates() throws {
    let result = try CompiledPacks<String>.compile(
        packs: [pack(.coreGit, safe: ["git"]), pack(.coreFilesystem, safe: ["rm"])],
        using: SelectiveEngine(rejected: [])
    )
    let enabledIDs: [PackID] = [.coreFilesystem, .coreGit, .coreFilesystem]

    let indices = enabledIDs.compactMap { result.packIndex(for: $0) }
    #expect(indices == [1, 0, 1])
    #expect(indices.map { result.packs[$0].snapshot.id } == enabledIDs)
}

@Test func compiledPackIndexUsesFirstDuplicateIDAndRefreshesAfterMutation() throws {
    var result = try CompiledPacks<String>.compile(
        packs: [
            pack(.coreGit, safe: ["first"]),
            pack(.coreGit, safe: ["second"]),
            pack(.coreFilesystem, safe: ["rm"]),
        ],
        using: SelectiveEngine(rejected: [])
    )
    #expect(result.packIndex(for: .coreGit) == 0)

    result.packs = [result.packs[1], result.packs[2]]
    #expect(result.packIndex(for: .coreGit) == 0)
    #expect(result.packs[result.packIndex(for: .coreGit) ?? -1].safe[0].name == "second")
}
