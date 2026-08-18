import RVDomain

enum BrokenCoreSnapshots {
    static func uncompilableResetHard() -> [PackSnapshot] {
        [
            PackSnapshot(
                id: .coreFilesystem,
                name: "filesystem",
                description: "core filesystem",
                keywords: ["rm"],
                safe: [NamedPattern(name: "keep", pattern: "rm")],
                destructive: [
                    DestructiveRule(
                        name: "fork-bomb",
                        pattern: "(",
                        severity: .critical,
                        reason: "uncompilable required pattern"
                    ),
                ]
            ),
            PackSnapshot(
                id: .coreGit,
                name: "git",
                description: "core git",
                keywords: ["git"],
                safe: [NamedPattern(name: "keep", pattern: "git")],
                destructive: [
                    DestructiveRule(
                        name: "reset-hard",
                        pattern: "(",
                        severity: .critical,
                        reason: "uncompilable required pattern"
                    ),
                ]
            ),
        ]
    }
}
