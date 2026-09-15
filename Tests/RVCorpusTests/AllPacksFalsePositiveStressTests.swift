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
                let result = catalog.evaluate(command, enabled: enabled)
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
            let result = catalog.evaluate(command, enabled: enabled)
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
            let result = catalog.evaluate(command, enabled: enabled)
            if result.decision != .allow {
                overBlocks += 1
                Issue.record("all-packs data-role over-block \(describe(result)) on \(command)")
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

    func evaluate(_ command: String, enabled: [PackID]) -> EvaluationResult {
        evaluate(
            EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: enabled),
            packs: packs,
            engine: engine,
            compiled: compiled
        )
    }
}

private func uniquePackIDs(_ ids: [PackID]) -> [PackID] {
    var seen = Set<PackID>()
    var out: [PackID] = []
    for id in ids where seen.insert(id).inserted {
        out.append(id)
    }
    return out
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
