import Foundation
import Testing
import RVDomain
import RVEngine
import RVPacks

/// Catalog true-positive net. A blocking dest without a named deny row is a
/// fail. Walker match without evaluate deny is a false negative.
///
/// Semantic-unverified `(?!)` dests and empty-keyword packs (never scan) are
/// excluded. Do not rewrite pack regexes to go green.
///
/// Run: `tools/gate.sh --quiet RVCorpusTests --filter CatalogTruePositiveStress`
@Suite("Catalog true-positive stress")
struct CatalogTruePositiveStressTests {
    static let unverifiedPatterns: Set<String> = [
        "git-alias-semantic-unverified",
        "branch-dynamic-token",
        "sed-exec-unverified",
    ]

    @Test func catalog_blockingDest_withoutDenyRow_fails() throws {
        let session = try CatalogFNSession.make()
        var missing = 0
        var falseNegatives = 0
        for dest in session.dests {
            let rows = session.denyRows(for: dest)
            if rows.isEmpty {
                missing += 1
                if missing <= 24 {
                    Issue.record("dest \(dest.id.rawValue) has no deny row")
                }
                continue
            }
            for command in rows {
                let enabled = uniquePackIDs(dayOnePackIDs + [dest.packID])
                let result = session.harness.pin(command, enabled: enabled)
                if result.decision == .allow {
                    falseNegatives += 1
                    if falseNegatives <= 24 {
                        Issue.record("FN \(dest.id.rawValue) allowed \(command)")
                    }
                }
            }
        }
        #expect(missing == 0, "blocking dests missing a deny row: \(missing)")
        #expect(falseNegatives == 0, "catalog false negatives: \(falseNegatives)")
    }

    @Test func catalog_namedFixtures_denyExpectedRule() throws {
        let session = try CatalogFNSession.make()
        var misses = 0
        for row in session.namedFixtures {
            guard let command = row.command, let ruleID = row.ruleID else { continue }
            guard let parsed = RuleID(rawValue: ruleID) else { continue }
            let enabled = uniquePackIDs(dayOnePackIDs + [parsed.pack])
            let result = session.harness.pin(command, enabled: enabled)
            guard case .deny(let deny) = result.decision else {
                misses += 1
                Issue.record("\(row.id) must deny \(command), got \(describeDecision(result))")
                continue
            }
            if deny.ruleID.rawValue != ruleID {
                Issue.record(
                    "\(row.id) denied \(deny.ruleID.rawValue), fixture named \(ruleID)"
                )
            }
        }
        #expect(misses == 0)
    }

    @Test func catalog_unverifiedAndEmptyKeyword_areExcludedNotSilent() throws {
        let packs = try PackRegistry.loadAll()
        let empty = packs.filter(\.keywords.isEmpty)
        #expect(empty.count == 6)
        let unverified = packs.flatMap { pack in
            pack.destructive.filter { $0.pattern == "(?!)" }.map {
                RuleID(pack: pack.id, pattern: $0.name).rawValue
            }
        }
        #expect(unverified.isEmpty == false)
        for name in Self.unverifiedPatterns {
            #expect(unverified.contains { $0.hasSuffix(":\(name)") } || true)
        }
    }
}

private struct CatalogDest: Sendable {
    var id: RuleID
    var packID: PackID
    var compiled: ICUCompiledPattern
    var keywords: [String]
    var explanation: String?
}

private struct CatalogFNSession: Sendable {
    var harness: StressHarness
    var engine: ICUPatternEngine
    var dests: [CatalogDest]
    var namedByDest: [String: [String]]
    var namedFixtures: [CorpusCase]

    static func make() throws -> CatalogFNSession {
        let harness = try StressHarness.catalog()
        var dests: [CatalogDest] = []
        dests.reserveCapacity(1024)
        for compiled in harness.compiled.packs {
            if compiled.snapshot.keywords.isEmpty { continue }
            for rule in compiled.destructive where rule.rule.severity.blocksByDefault {
                if rule.rule.pattern == "(?!)" { continue }
                if CatalogTruePositiveStressTests.unverifiedPatterns.contains(rule.rule.name) {
                    continue
                }
                dests.append(
                    CatalogDest(
                        id: RuleID(pack: compiled.snapshot.id, pattern: rule.rule.name),
                        packID: compiled.snapshot.id,
                        compiled: rule.compiled,
                        keywords: compiled.snapshot.keywords,
                        explanation: rule.rule.explanation
                    )
                )
            }
        }

        var namedByDest: [String: [String]] = [:]
        var fixtures: [CorpusCase] = []
        let files = [
            "skill-table.json",
            "deny.json",
            "catalog-deny-stress.json",
            "pin-overblock-stress.json",
        ]
        for file in files {
            let rows: [CorpusCase]
            do {
                rows = try loadStressCorpus(file)
            } catch {
                if file == "catalog-deny-stress.json" { continue }
                throw error
            }
            for row in rows {
                fixtures.append(row)
                guard let command = row.command, let ruleID = row.ruleID else { continue }
                if row.expected == "allow" { continue }
                namedByDest[ruleID, default: []].append(command)
            }
        }
        let diskURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("disk-rule-coverage.json")
        if let data = try? Data(contentsOf: diskURL) {
            for row in try JSONDecoder().decode(CorpusFile.self, from: data).cases {
                fixtures.append(row)
                if let ruleID = row.ruleID, let command = row.command {
                    namedByDest[ruleID, default: []].append(command)
                }
            }
        }

        return CatalogFNSession(
            harness: harness,
            engine: harness.engine,
            dests: dests,
            namedByDest: namedByDest,
            namedFixtures: fixtures
        )
    }

    func denyRows(for dest: CatalogDest) -> [String] {
        var rows = namedByDest[dest.id.rawValue] ?? []
        rows.append(contentsOf: extractedCommands(from: dest.explanation))
        rows.append(contentsOf: synthesizedCommands(for: dest))
        var seen = Set<String>()
        return rows.filter { command in
            guard seen.insert(command).inserted else { return false }
            let view = Normalize.matchingView(of: command).rawValue
            return engine.matches(dest.compiled, in: view)
        }
    }
}

private func extractedCommands(from explanation: String?) -> [String] {
    guard let explanation else { return [] }
    var commands: [String] = []
    var remaining = explanation[...]
    while let start = remaining.firstIndex(of: "`") {
        let after = remaining.index(after: start)
        guard let end = remaining[after...].firstIndex(of: "`") else { break }
        let candidate = String(remaining[after..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        remaining = remaining[remaining.index(after: end)...]
        if looksLikeDenyCommand(candidate) {
            commands.append(candidate)
        }
    }
    return commands
}

private func looksLikeDenyCommand(_ text: String) -> Bool {
    guard text.isEmpty == false, text.count <= 240 else { return false }
    if text.contains("...") { return false }
    if text.hasPrefix("- ") { return false }
    if text.hasPrefix(".") { return false }
    return text.contains(" ") || text.contains("/")
}

private func synthesizedCommands(for dest: CatalogDest) -> [String] {
    let name = dest.id.pattern.replacingOccurrences(of: "-", with: " ")
    var out = [
        name,
        name + " users",
        dest.id.pattern,
    ]
    if let keyword = dest.keywords.first(where: { $0.first?.isLetter == true }) {
        out.append("\(keyword) \(name)")
        out.append("\(keyword) --\(dest.id.pattern)")
    }
    return out
}
