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
