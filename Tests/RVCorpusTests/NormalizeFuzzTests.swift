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
        for _ in 0..<budget.iterations {
            let suffix = String(decoding: FuzzMutator.mutate(
                seeds.randomElement(using: &random)!, seeds: seeds, dictionary: Self.dictionary,
                maxLength: 1_024, using: &random), as: UTF8.self)
            let command = denied.randomElement(using: &random)! + "\n" + suffix
            guard harness.door(command).decision == .allow else { continue }
            allowed.append(FuzzMutator.describe(Array(command.utf8)))
        }
        #expect(allowed.isEmpty, "seed \(budget.seed): \(allowed.count) allows, first \(allowed.prefix(5))")
    }

    /// Fuzz finding (fixed in #543): heredoc masking used to blank the first
    /// occurrence of the body text anywhere in the command, so a body that
    /// repeated a word of an earlier line erased that word from the
    /// matching view and the denied line read as allowed.
    @Test(arguments: [
        "git reset --hard\ncat <<EOF\ngit\nEOF",
        "git reset --hard && cat <<EOF > notes.txt\ngit\nEOF",
        "rm -rf ~\ncat <<EOF\nrm\nEOF",
        "git clean -fdx\ncat <<EOF\nclean\nEOF",
    ])
    func heredocBodyRepeatingAnEarlierWordDoesNotHideIt(command: String) throws {
        let harness = try StressHarness.dayOne()
        #expect(harness.pin(command).decision != .allow)
        #expect(harness.door(command).decision != .allow)
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
