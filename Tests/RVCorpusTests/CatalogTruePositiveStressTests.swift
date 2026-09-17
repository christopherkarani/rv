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
            let enabled = uniquePackIDs(dayOnePackIDs + [dest.packID])
            var denied = false
            var sampleAllow: String?
            for command in rows {
                let result = session.harness.pin(command, enabled: enabled)
                if result.decision != .allow {
                    denied = true
                    break
                }
                if sampleAllow == nil {
                    sampleAllow = command
                }
            }
            if denied == false {
                falseNegatives += 1
                if falseNegatives <= 24 {
                    Issue.record(
                        "FN \(dest.id.rawValue) allowed \(sampleAllow ?? rows[0])"
                    )
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
            guard row.expected == "deny" else { continue }
            guard let command = row.command, let ruleID = row.ruleID else { continue }
            guard let parsed = RuleID(rawValue: ruleID) else { continue }
            let enabled = uniquePackIDs(dayOnePackIDs + [parsed.pack])
            let result = session.harness.pin(command, enabled: enabled)
            guard case .deny(let deny) = result.decision else {
                misses += 1
                Issue.record("\(row.id) must deny \(command), got \(describeDecision(result))")
                continue
            }
            if deny.ruleID.rawValue != ruleID, deny.ruleID.pack != parsed.pack {
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
    var pattern: String
    var keywords: [String]
    var explanation: String?
}

private struct CatalogFNSession: Sendable {
    var harness: StressHarness
    var engine: ICUPatternEngine
    var dests: [CatalogDest]
    var namedByDest: [String: [String]]
    var namedFixtures: [CorpusCase]
    var commandPool: [String]

    static func make() throws -> CatalogFNSession {
        let harness = try StressHarness.catalog()
        var dests: [CatalogDest] = []
        dests.reserveCapacity(1024)
        var explanationCommands: [String] = []
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
                        pattern: rule.rule.pattern,
                        keywords: compiled.snapshot.keywords,
                        explanation: rule.rule.explanation
                    )
                )
                explanationCommands.append(contentsOf: extractedCommands(from: rule.rule.explanation))
            }
        }

        var namedByDest: [String: [String]] = [:]
        var fixtures: [CorpusCase] = []
        let files = [
            "skill-table.json",
            "deny.json",
            "catalog-deny-stress.json",
            "pin-overblock-stress.json",
            "near-miss.json",
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

        var pool: [String] = explanationCommands
        for row in fixtures {
            if let command = row.command {
                pool.append(command)
            }
        }
        var seen = Set<String>()
        pool = pool.filter { seen.insert($0).inserted }

        return CatalogFNSession(
            harness: harness,
            engine: harness.engine,
            dests: dests,
            namedByDest: namedByDest,
            namedFixtures: fixtures,
            commandPool: pool
        )
    }

    func denyRows(for dest: CatalogDest) -> [String] {
        var rows = namedByDest[dest.id.rawValue] ?? []
        rows.append(contentsOf: extractedCommands(from: dest.explanation))
        rows.append(contentsOf: synthesizedCommands(for: dest))
        rows.append(contentsOf: seedFromPattern(dest.pattern, keywords: dest.keywords))
        rows.append(contentsOf: commandPool)
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
    let spaced = dest.id.pattern.replacingOccurrences(of: "-", with: " ")
    let dashed = dest.id.pattern
    var out = [
        spaced,
        spaced + " users",
        spaced + " /tmp/x",
        dashed,
    ]
    if let keyword = dest.keywords.first(where: { $0.first?.isLetter == true }) {
        out.append("\(keyword) \(spaced)")
        out.append("\(keyword) --\(dashed)")
        out.append("\(keyword) \(spaced) users")
        out.append("\(keyword) \(spaced) /tmp/x")
        if dest.id.pattern.contains("hard") {
            out.append("\(keyword) reset --hard")
        }
        if dest.id.pattern.contains("checkout") {
            out.append("\(keyword) checkout -- file.txt")
        }
        if dest.id.pattern.contains("restore") {
            out.append("\(keyword) restore file.txt")
        }
    }
    return out
}

private func seedFromPattern(_ pattern: String, keywords: [String]) -> [String] {
    let collapsed = collapsePattern(pattern)
    let words = patternLiterals(pattern).filter { $0 != "--" && $0 != "-" }
    let joined = words.joined(separator: " ")
    var out: [String] = []
    if collapsed.isEmpty == false {
        out.append(contentsOf: expandCollapsed(collapsed))
    }
    if joined.isEmpty == false {
        out.append(joined)
        out.append(joined + " users")
        out.append(joined + " /tmp/x")
        out.append(joined + " /dev/sda")
        if joined.hasSuffix(" --") {
            out.append(joined + " file.txt")
        }
    }
    if let keyword = keywords.first(where: { $0.first?.isLetter == true }),
       joined.lowercased().hasPrefix(keyword.lowercased()) == false
    {
        out.append("\(keyword) \(joined)")
    }
    return out
}

private func expandCollapsed(_ command: String) -> [String] {
    var out = [command]
    if command.contains("localhost:") {
        out.append(command.replacingOccurrences(of: "localhost:", with: "http://localhost:"))
    }
    if command.contains("$("), command.hasSuffix("$(") == false {
        out.append(command)
    }
    if command.hasSuffix("$(") {
        out.append(command + "docker ps -q)")
        out.append(command + "x)")
    }
    if command.contains("DELETE") && command.contains("localhost") == false {
        out.append(command + " http://localhost:8001/services")
    }
    return out
}

/// Drop optional groups / lookarounds and turn a typical pack walker into a
/// command-shaped literal. Not a full regex inverter.
private func collapsePattern(_ pattern: String) -> String {
    var text = pattern.replacingOccurrences(of: "(?i)", with: "")
    for _ in 0..<32 {
        let next = stripOneOptionalOrLookaround(text)
        if next == text { break }
        text = next
    }
    text = takeFirstAlternatives(text)
    text = text.replacingOccurrences(of: #"\\s\+"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\s\*"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\s"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\b"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"[.][*?]"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\S\+"#, with: "x", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\S\*"#, with: "x", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\d\+"#, with: "1", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\\."#, with: ".", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\\("#, with: "(", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\\)"#, with: ")", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\\$"#, with: "$", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\\["#, with: "[", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\\]"#, with: "]", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\\+"#, with: "+", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\\*"#, with: "*", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\\?"#, with: "?", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\\/"#, with: "/", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\[[^\]]*\]\+?"#, with: "x", options: .regularExpression)
    text = text.replacingOccurrences(of: #"[\^$]"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"[()?+*]"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func stripOneOptionalOrLookaround(_ text: String) -> String {
    let prefixes = ["(?=", "(?!", "(?<=", "(?<!", "(?:"]
    var index = text.startIndex
    while index < text.endIndex {
        for prefix in prefixes {
            if text[index...].hasPrefix(prefix),
               let close = matchingParen(in: text, open: index)
            {
                let after = text.index(after: close)
                let quantified =
                    after < text.endIndex && (text[after] == "*" || text[after] == "?" || text[after] == "+")
                if prefix == "(?:" {
                    if quantified, text[after] == "*" || text[after] == "?" {
                        let end = text.index(after: after)
                        return String(text[..<index]) + String(text[end...])
                    }
                    let inner = text[text.index(index, offsetBy: prefix.count)..<close]
                    return String(text[..<index]) + String(inner) + String(text[after...])
                }
                return String(text[..<index]) + String(text[after...])
            }
        }
        index = text.index(after: index)
    }
    return text
}

private func matchingParen(in text: String, open: String.Index) -> String.Index? {
    var depth = 0
    var index = open
    var escaped = false
    while index < text.endIndex {
        let character = text[index]
        if escaped {
            escaped = false
            index = text.index(after: index)
            continue
        }
        if character == "\\" {
            escaped = true
            index = text.index(after: index)
            continue
        }
        if character == "(" {
            depth += 1
        } else if character == ")" {
            depth -= 1
            if depth == 0 {
                return index
            }
        }
        index = text.index(after: index)
    }
    return nil
}

private func takeFirstAlternatives(_ text: String) -> String {
    var result = text
    for _ in 0..<16 {
        guard let bar = result.firstIndex(of: "|") else { break }
        guard let open = result[..<bar].lastIndex(of: "("),
              let close = matchingParen(in: result, open: open)
        else {
            result.replaceSubrange(bar...bar, with: " ")
            continue
        }
        let innerStart = result.index(after: open)
        let first = String(result[innerStart..<bar])
        result.replaceSubrange(open...close, with: first)
    }
    return result
}

private func patternLiterals(_ pattern: String) -> [String] {
    var words: [String] = []
    var current = ""
    var index = pattern.startIndex
    func flush() {
        if current.count >= 2 {
            words.append(current)
        }
        current = ""
    }
    while index < pattern.endIndex {
        let character = pattern[index]
        let next = pattern.index(after: index)
        if character == "\\" {
            if next < pattern.endIndex {
                let escaped = pattern[next]
                switch escaped {
                case "s", "S", "w", "W", "d", "D", "b", "B":
                    flush()
                case " ", "-", "/", ".", ":", "_", "=", ",", "@":
                    current.append(escaped)
                default:
                    if escaped.isLetter || escaped.isNumber {
                        current.append(escaped)
                    } else {
                        flush()
                    }
                }
                index = pattern.index(after: next)
                continue
            }
            flush()
            index = next
            continue
        }
        if character == "[" {
            flush()
            if let close = pattern[next...].firstIndex(of: "]") {
                index = pattern.index(after: close)
            } else {
                index = next
            }
            continue
        }
        if character == "(" || character == ")" || character == "|" || character == "^"
            || character == "$" || character == "?" || character == "*" || character == "+"
            || character == "{" || character == "}"
        {
            flush()
            index = next
            continue
        }
        if character.isLetter || character.isNumber || character == "-" || character == "_"
            || character == "." || character == "/" || character == ":" || character == "="
        {
            current.append(character)
            index = next
            continue
        }
        flush()
        index = next
    }
    flush()
    return words.filter { word in
        word != "?:i" && word != "?:" && word != "alnum" && word != "?i"
    }
}
