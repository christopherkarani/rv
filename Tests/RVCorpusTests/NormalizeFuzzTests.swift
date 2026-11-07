import Foundation
import Testing
import RVDomain
import RVEngine
import RVPacks

/// Seeded mutation fuzz over the gate's front door: `Normalize` plus pin
/// `evaluate` and the product door `evaluateWithSemantics`.
///
/// Run: `Scripts/gate.sh --quiet RVCorpusTests --filter NormalizeFuzz`.
/// Longer: `RV_FUZZ_SEED=… RV_FUZZ_ITERATIONS=… swift test --filter NormalizeFuzz`.
/// The libFuzzer twin is `Fuzz/Normalize` (docs/fuzzing.md).
@Suite("Normalize fuzz")
struct NormalizeFuzzTests {
    /// One input slower than this is reported as a hang candidate. Typical
    /// inputs take well under a millisecond; the bound absorbs CI load.
    static let perInputBound: Duration = .seconds(2)

    static let dictionary: [[UInt8]] = [
        "'", "\"", "`", "$(", ")", "${", "}", "$'", "\\", ";", "&&", "||", "|", "|&", "&",
        ">", ">>", "<", "<<", "<<<", "<(", ">(", "2>&1", "\n", "\r", " ", "\t", "#", "=", "(", "{",
        "[[", "]]", "--", "-", "*", "?", "~", "!", "\\x", "\u{0}", "bash -c ", "sh -c ", "eval ",
        "sudo ", "env ", "xargs ", "exec ", "command ", "git ", "rm ", "-rf ", "reset --hard",
        "find . -exec ", "python3 -c ", "cd .. && ", "HOME=/ ",
    ].map { Array($0.utf8) }

    static func seeds() throws -> [[UInt8]] {
        var commands: [String] = []
        for name in ["deny.json", "near-miss.json", "door-bypass.json", "agent-parse-stress.json"] {
            commands += try loadStressCorpus(name).compactMap(\.command)
        }
        return commands.map { Array($0.utf8) }
    }

    /// Denied single-line corpus commands bash would run as line one.
    static func deniedFirstLines(_ harness: StressHarness) throws -> [String] {
        try loadStressCorpus("deny.json").compactMap { row -> String? in
            guard row.expected == "deny", let command = row.command,
                command.contains("\n") == false, command.hasSuffix("\\") == false,
                case .deny = harness.door(command).decision,
                case .deny = harness.pin(command).decision
            else { return nil }
            return command
        }
    }

    /// No input traps or runs past the per-input bound in `Normalize`, pin,
    /// or the door.
    @Test(.timeLimit(.minutes(5)))
    func mutatedCommandsNeverTrapOrHang() throws {
        let harness = try StressHarness.dayOne()
        let seeds = try Self.seeds()
        let budget = FuzzBudget.resolve(defaultSeed: 0x5EED_0001, defaultIterations: 2_000)
        var random = FuzzRandom(seed: budget.seed)
        let clock = ContinuousClock()
        var slow: [String] = []
        for _ in 0..<budget.iterations {
            let bytes = FuzzMutator.mutate(
                seeds.randomElement(using: &random)!, seeds: seeds, dictionary: Self.dictionary,
                maxLength: 4_096, using: &random)
            let command = String(decoding: bytes, as: UTF8.self)
            let elapsed = clock.measure {
                _ = Normalize.matchingView(of: command)
                _ = Normalize.maskedSegments(of: command)
                _ = Normalize.secretScanView(of: ShellCommand(rawValue: command))
                _ = harness.pin(command)
                _ = harness.door(command)
            }
            if elapsed > Self.perInputBound {
                slow.append("\(elapsed) \(FuzzMutator.describe(bytes))")
            }
        }
        #expect(slow.isEmpty, "seed \(budget.seed): slow inputs \(slow.prefix(5))")
    }

    /// Fail closed: a denied command on line one runs before bash ever
    /// parses line two, so no later text — unbalanced quotes, open
    /// substitutions, heredoc openers, binary junk — may turn the whole
    /// command into an allow at the door (the verdict rv returns). Pin
    /// alone is not held to this: it denies `$'\x72m -rf /'`, which bash
    /// runs as a missing command named `rm -rf /`, and stops denying it
    /// once any line follows.
    @Test(.timeLimit(.minutes(5)))
    func deniedFirstLineStaysDeniedWhateverFollows() throws {
        let harness = try StressHarness.dayOne()
        let seeds = try Self.seeds()
        let denied = try Self.deniedFirstLines(harness)
        #expect(denied.count >= 10, "deny.json should seed at least ten single-line denies")
        let budget = FuzzBudget.resolve(defaultSeed: 0x5EED_0002, defaultIterations: 1_500)
        var random = FuzzRandom(seed: budget.seed)
        var allowed: [String] = []
        var heredocAllowed: [String] = []
        for _ in 0..<budget.iterations {
            let suffix = String(decoding: FuzzMutator.mutate(
                seeds.randomElement(using: &random)!, seeds: seeds, dictionary: Self.dictionary,
                maxLength: 1_024, using: &random), as: UTF8.self)
            let command = denied.randomElement(using: &random)! + "\n" + suffix
            guard harness.door(command).decision == .allow else { continue }
            let described = FuzzMutator.describe(Array(command.utf8))
            if Self.heredocBodyRepeatsEarlierText(command) {
                heredocAllowed.append(described)
            } else {
                allowed.append(described)
            }
        }
        #expect(allowed.isEmpty, "seed \(budget.seed): \(allowed.count) allows, first \(allowed.prefix(5))")
        if heredocAllowed.isEmpty == false {
            withKnownIssue("heredoc masking blanks an earlier line; see heredocBodyRepeatingAnEarlierWord") {
                Issue.record("seed \(budget.seed): \(heredocAllowed.count) heredoc allows, first \(heredocAllowed.prefix(3))")
            }
        }
    }

    // TODO(fix/heredoc-mask-position): delete this, its twin in
    // Fuzz/Normalize, and the heredocAllowed split once heredoc masking
    // blanks the body itself rather than the first match of its text.
    /// The known heredoc masking bug shape: a line after a heredoc opener
    /// (`<<`, `<<-`; a `<<<` here-string is not one), other than a
    /// delimiter line, whose text, leading tabs dropped, already occurs
    /// earlier in the command. Masking blanks the first match of the body
    /// text, so only such inputs can hide an earlier line; every other
    /// allow still fails the property.
    static func heredocBodyRepeatsEarlierText(_ command: String) -> Bool {
        let lines = command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let opener = lines.firstIndex(where: { heredocDelimiters($0).isEmpty == false }) else { return false }
        var delimiters = Set<String>()
        var preceding = ""
        for (index, line) in lines.enumerated() {
            let text = line.drop { $0 == "\t" }
            if index > opener, text.isEmpty == false, delimiters.contains(String(text)) == false,
                preceding.range(of: text) != nil
            {
                return true
            }
            delimiters.formUnion(heredocDelimiters(line))
            preceding += (index == 0 ? "" : "\n") + line
        }
        return false
    }

    /// The delimiter word after each `<<` or `<<-` in `line`, quotes and
    /// backslashes dropped. A run of three `<` is a here-string, not an opener.
    static func heredocDelimiters(_ line: Substring) -> [String] {
        var delimiters: [String] = []
        var index = line.startIndex
        while index < line.endIndex {
            guard line[index] == "<" else {
                index = line.index(after: index)
                continue
            }
            let run = line[index...].prefix { $0 == "<" }
            index = run.endIndex
            guard run.count == 2 || run.count >= 4 else { continue }
            var rest = line[index...]
            if rest.first == "-" { rest = rest.dropFirst() }
            let word = rest.drop { $0 == " " || $0 == "\t" }
                .prefix { $0.isWhitespace == false && "|<>;&()".contains($0) == false }
                .filter { $0 != "'" && $0 != "\"" && $0 != "\\" }
            if word.isEmpty == false { delimiters.append(word) }
        }
        return delimiters
    }

    @Test(arguments: [
        ("git reset --hard\ncat <<EOF\ngit\nEOF", true),
        ("rm -rf ~\ncat <<-EOF\n\trm\nEOF", true),
        ("git reset --hard\ncat <<EOF\nnotes\nEOF", false),
        ("git reset --hard\ncat <<-'EOF'\n\tnotes\n\tEOF", false),
        ("git reset --hard\ncat <<< git", false),
        ("git reset --hard\ngit log", false),
    ])
    func heredocExclusionMatchesOnlyTheKnownBugShape(command: String, excluded: Bool) {
        #expect(Self.heredocBodyRepeatsEarlierText(command) == excluded)
    }

    /// Fuzz finding (open): heredoc masking blanks the first occurrence of
    /// the body text anywhere in the command (`text.range(of:
    /// heredoc.body)` in `maskNonExecutingHeredocBodiesDetailed`), so a
    /// body that repeats a word of an earlier line erases that word from
    /// the matching view and the denied line reads as allowed. Drop the
    /// `withKnownIssue` when the masking is fixed.
    @Test(arguments: [
        "git reset --hard\ncat <<EOF\ngit\nEOF",
        "git reset --hard && cat <<EOF > notes.txt\ngit\nEOF",
        "rm -rf ~\ncat <<EOF\nrm\nEOF",
        "git clean -fdx\ncat <<EOF\nclean\nEOF",
    ])
    func heredocBodyRepeatingAnEarlierWordDoesNotHideIt(command: String) throws {
        let harness = try StressHarness.dayOne()
        withKnownIssue("heredoc masking blanks the first match of the body text, not the body") {
            #expect(harness.pin(command).decision != .allow)
            #expect(harness.door(command).decision != .allow)
        }
    }

    /// Fail closed: past the byte cap nothing is parsed; both doors say
    /// indeterminate, whatever the bytes are.
    @Test func oversizedCommandsAreIndeterminate() throws {
        let harness = try StressHarness.dayOne()
        let seeds = try Self.seeds()
        var random = FuzzRandom(seed: 0x5EED_0003)
        for _ in 0..<20 {
            var bytes: [UInt8] = []
            while bytes.count <= commandByteCap {
                bytes += FuzzMutator.mutate(
                    seeds.randomElement(using: &random)!, seeds: seeds, dictionary: Self.dictionary,
                    maxLength: 4_096, using: &random) + [UInt8(ascii: " ")]
            }
            let command = String(decoding: bytes, as: UTF8.self)
            #expect(harness.pin(command).decision == .indeterminate(.commandTooLarge))
            #expect(harness.door(command).decision == .indeterminate(.commandTooLarge))
        }
    }
}
