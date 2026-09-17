import Foundation
import Testing
import RVDomain
import RVEngine
import RVPacks

/// Over-block net for the T9 catalog (95 packs). Pin day-one is still the
/// 0.11.0 scoreboard; this suite asks: when an extra pack is on, does it
/// deny quiet work or data-role text?
///
/// `strict_git` is designed to deny `--force-with-lease`. Those rows are
/// tagged `skip-strict-git`. Empty-keyword packs never scan (quick-reject).
/// Command-name `--help` / `--version` must allow (documentation query).
///
/// Run:
/// `tools/gate.sh --quiet RVCorpusTests --filter AllPacksFalsePositiveStress`
@Suite("All-packs false-positive stress")
struct AllPacksFalsePositiveStressTests {
    static let strictGit = PackID(rawValue: "strict_git")

    @Test func catalog_hasNinetyFivePacks() throws {
        let packs = try PackRegistry.loadAll()
        #expect(packs.count == 95)
        let ids = Set(packs.map(\.id.rawValue))
        #expect(ids.contains("core.git"))
        #expect(ids.contains("core.filesystem"))
        #expect(ids.contains("system.disk"))
        #expect(ids.contains(Self.strictGit.rawValue))
    }

    @Test func perPack_allowCorpus_doesNotDeny() throws {
        let catalog = try CatalogSession.make()
        let rows = try loadCorpus("all-packs-allow.json")
        var overBlocks = 0
        for pack in catalog.packs {
            for row in rows {
                guard let command = row.command else { continue }
                if row.kind == "skip-strict-git", pack.id == Self.strictGit {
                    continue
                }
                let enabled = uniquePackIDs(dayOnePackIDs + [pack.id])
                let result = catalog.run(command, enabled: enabled)
                if result.decision != .allow {
                    overBlocks += 1
                    Issue.record(
                        "\(pack.id.rawValue) over-block \(describe(result)) on \(row.id): \(command)"
                    )
                }
            }
        }
        #expect(overBlocks == 0)
    }

    @Test func catalogMinusStrict_allowCorpus_doesNotDeny() throws {
        let catalog = try CatalogSession.make()
        let enabled = catalog.packs.map(\.id).filter { $0 != Self.strictGit }
        let rows = try loadCorpus("all-packs-allow.json")
        var overBlocks = 0
        for row in rows {
            guard let command = row.command else { continue }
            let result = catalog.run(command, enabled: enabled)
            if result.decision != .allow {
                overBlocks += 1
                Issue.record(
                    "catalog-minus-strict over-block \(describe(result)) on \(row.id): \(command)"
                )
            }
        }
        #expect(overBlocks == 0)
    }

    @Test func allPacks_dataRoleNeverSlip_doesNotDeny() throws {
        let catalog = try CatalogSession.make()
        let enabled = catalog.packs.map(\.id)
        let commands = [
            "echo \"git reset --hard\"",
            "echo \"rm -rf /\"",
            "echo \"DROP TABLE users\"",
            "printf '%s\\n' 'git reset --hard'",
            "git commit -m \"git reset --hard\"",
            "rg -n \"rm -rf\"",
            "python3 -c \"print('git reset --hard')\"",
            "node -e \"console.log('git reset --hard')\"",
            "ruby -e \"puts 'git reset --hard'\"",
        ]
        var overBlocks = 0
        for command in commands {
            let result = catalog.run(command, enabled: enabled)
            if result.decision != .allow {
                overBlocks += 1
                Issue.record("all-packs data-role over-block \(describe(result)) on \(command)")
            }
        }
        #expect(overBlocks == 0)
    }

    @Test func emptyKeywordPacks_neverScan() throws {
        let catalog = try CatalogSession.make()
        let empty = catalog.packs.filter(\.keywords.isEmpty)
        #expect(empty.count == 6)
        for pack in empty {
            #expect(pack.id.rawValue.hasPrefix("careful_company_running_windows."))
        }
        let probe = "Set-MpPreference -DisableRealtimeMonitoring $true"
        let enabled = uniquePackIDs(dayOnePackIDs + empty.map(\.id))
        let result = catalog.run(probe, enabled: enabled)
        #expect(result.decision == .allow, "empty-keyword packs must quick-reject, got \(describe(result))")
    }

    @Test func perPack_keywordQuietProbes_doNotDeny() throws {
        let catalog = try CatalogSession.make()
        var overBlocks = 0
        for pack in catalog.packs {
            let enabled = uniquePackIDs(dayOnePackIDs + [pack.id])
            for command in keywordQuietProbes(for: pack) {
                if pack.id == Self.strictGit, isStrictGitByDesign(command) {
                    continue
                }
                let result = catalog.run(command, enabled: enabled)
                if result.decision != .allow {
                    overBlocks += 1
                    Issue.record(
                        "\(pack.id.rawValue) quiet-probe over-block \(describe(result)) on \(command)"
                    )
                }
            }
        }
        #expect(overBlocks == 0)
    }

    /// Bypass keywords: every blocking walker vs the allow matching view.
    /// Catches over-broad extracted regexes that evaluate currently skips.
    @Test func walkers_allowCorpus_doNotMatchBlocking() throws {
        let catalog = try CatalogSession.make()
        let rows = try loadCorpus("all-packs-allow.json")
        var overBlocks = 0
        var views: [(id: String, command: String, view: String, kind: String?)] = []
        views.reserveCapacity(rows.count)
        for row in rows {
            guard let command = row.command else { continue }
            views.append(
                (
                    id: row.id,
                    command: command,
                    view: Normalize.matchingView(of: command).rawValue,
                    kind: row.kind
                )
            )
        }
        for compiled in catalog.compiled.packs {
            for rule in compiled.destructive where rule.rule.severity.blocksByDefault {
                let ruleID = RuleID(pack: compiled.snapshot.id, pattern: rule.rule.name)
                for row in views {
                    if row.kind == "skip-strict-git", compiled.snapshot.id == Self.strictGit {
                        continue
                    }
                    if catalog.engine.matches(rule.compiled, in: row.view) {
                        overBlocks += 1
                        Issue.record(
                            "walker \(ruleID.rawValue) matches \(row.id): \(row.command)"
                        )
                    }
                }
            }
        }
        #expect(overBlocks == 0)
    }

    @Test func walkers_keywordQuietProbes_doNotMatchBlocking() throws {
        let catalog = try CatalogSession.make()
        var overBlocks = 0
        for compiled in catalog.compiled.packs {
            let probes = keywordQuietProbes(for: compiled.snapshot)
            for rule in compiled.destructive where rule.rule.severity.blocksByDefault {
                let ruleID = RuleID(pack: compiled.snapshot.id, pattern: rule.rule.name)
                for command in probes {
                    if compiled.snapshot.id == Self.strictGit, isStrictGitByDesign(command) {
                        continue
                    }
                    if isDocumentationFlagProbe(command) {
                        continue
                    }
                    let view = Normalize.matchingView(of: command).rawValue
                    if catalog.engine.matches(rule.compiled, in: view) {
                        overBlocks += 1
                        Issue.record("walker \(ruleID.rawValue) matches quiet \(command)")
                    }
                }
            }
        }
        #expect(overBlocks == 0)
    }
}

private struct CatalogSession: Sendable {
    var packs: [PackSnapshot]
    var compiled: CompiledPacks<ICUCompiledPattern>
    var engine: ICUPatternEngine

    static func make() throws -> CatalogSession {
        let packs = try PackRegistry.loadAll()
        let engine = ICUPatternEngine()
        let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
        return CatalogSession(packs: packs, compiled: compiled, engine: engine)
    }

    func run(_ command: String, enabled: [PackID]) -> EvaluationResult {
        evaluate(
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: enabled),
            packs: packs,
            engine: engine,
            compiled: compiled
        )
    }
}

private func isCommandNameKeyword(_ keyword: String) -> Bool {
    guard let first = keyword.first, first.isLetter else { return false }
    return keyword.unicodeScalars.allSatisfy { scalar in
        guard scalar.isASCII else { return false }
        let value = scalar.value
        return (65...90).contains(value)
            || (97...122).contains(value)
            || (48...57).contains(value)
            || value == 45
            || value == 46
            || value == 95
    }
}

private func keywordQuietProbes(for pack: PackSnapshot) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for keyword in pack.keywords where isCommandNameKeyword(keyword) {
        let probes = [
            "\(keyword) --help",
            "\(keyword) --version",
            "echo \"\(keyword)\"",
        ]
        for command in probes where seen.insert(command).inserted {
            out.append(command)
        }
    }
    return out
}

/// Pin command-name walkers still deny `--help` / `--version` (extracted regex).
/// That class is residual until the documentation-query allow lands.
private func isDocumentationFlagProbe(_ command: String) -> Bool {
    command.hasSuffix(" --help") || command.hasSuffix(" --version")
}

/// `strict_git` is designed to deny rebase / force-with-lease / history rewrite.
private func isStrictGitByDesign(_ command: String) -> Bool {
    let view = command.lowercased()
    return view.contains("rebase")
        || view.contains("force-with-lease")
        || view.contains("--force")
        || view.contains(" --amend")
        || view.contains("cherry-pick")
        || view.contains("filter-branch")
        || view.contains("filter-repo")
        || view.contains("reflog expire")
        || view.contains("worktree remove")
}

private func describe(_ result: EvaluationResult) -> String {
    switch result.decision {
    case .allow:
        if let ruleID = result.matched?.ruleID.rawValue {
            return "allow+\(ruleID)"
        }
        return "allow"
    case .deny(let deny):
        return "deny \(deny.ruleID.rawValue)"
    case .indeterminate(let reason):
        return "indeterminate \(reason.rawValue)"
    }
}

private func loadCorpus(_ name: String) throws -> [CorpusCase] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("RVEngineTests/Fixtures/corpus")
        .appendingPathComponent(name)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(CorpusFile.self, from: data).cases
}
