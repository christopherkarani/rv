import Foundation

// Deterministic, seeded byte mutator for the in-suite fuzz properties.
// Kept identical in Tests/RVCorpusTests and Tests/RVIsolationTests (test
// targets cannot share sources). The libFuzzer harnesses under Fuzz/ do
// not use it: libFuzzer mutates for them. See docs/fuzzing.md.

/// SplitMix64: tiny, seedable, the same sequence on every platform.
struct FuzzRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Seed and iteration count, overridable for longer local runs:
/// `RV_FUZZ_SEED=7 RV_FUZZ_ITERATIONS=200000 swift test --filter Fuzz`.
struct FuzzBudget {
    var seed: UInt64
    var iterations: Int

    static func resolve(defaultSeed: UInt64, defaultIterations: Int) -> FuzzBudget {
        let environment = ProcessInfo.processInfo.environment
        let seed = environment["RV_FUZZ_SEED"].flatMap { UInt64($0) } ?? defaultSeed
        let iterations = environment["RV_FUZZ_ITERATIONS"].flatMap { Int($0) } ?? defaultIterations
        return FuzzBudget(seed: seed, iterations: max(1, iterations))
    }
}

enum FuzzMutator {
    /// Bytes libFuzzer-style mutators favour: boundaries, separators, length
    /// extremes.
    static let interestingBytes: [UInt8] = [0x00, 0x01, 0x09, 0x0A, 0x0D, 0x20, 0x7F, 0x80, 0xFE, 0xFF]

    /// One to four stacked mutations of `input`, drawn from `dictionary`
    /// and `seeds` (for splicing), capped at `maxLength` bytes.
    static func mutate(
        _ input: [UInt8],
        seeds: [[UInt8]],
        dictionary: [[UInt8]],
        maxLength: Int,
        using random: inout FuzzRandom
    ) -> [UInt8] {
        var bytes = input
        for _ in 0..<Int.random(in: 1...4, using: &random) {
            bytes = mutateOnce(bytes, seeds: seeds, dictionary: dictionary, using: &random)
        }
        return bytes.count > maxLength ? Array(bytes.prefix(maxLength)) : bytes
    }

    private static func mutateOnce(
        _ input: [UInt8],
        seeds: [[UInt8]],
        dictionary: [[UInt8]],
        using random: inout FuzzRandom
    ) -> [UInt8] {
        var bytes = input
        let position = { (count: Int, random: inout FuzzRandom) -> Int in
            count == 0 ? 0 : Int.random(in: 0..<count, using: &random)
        }
        switch Int.random(in: 0..<9, using: &random) {
        case 0 where bytes.isEmpty == false:
            let index = position(bytes.count, &random)
            bytes[index] ^= UInt8(1) << UInt8.random(in: 0..<8, using: &random)
        case 1 where bytes.isEmpty == false:
            bytes[position(bytes.count, &random)] = UInt8.random(in: 0...255, using: &random)
        case 2 where bytes.isEmpty == false:
            bytes[position(bytes.count, &random)] = interestingBytes.randomElement(using: &random)!
        case 3 where dictionary.isEmpty == false:
            let token = dictionary.randomElement(using: &random)!
            bytes.insert(contentsOf: token, at: position(bytes.count + 1, &random))
        case 4 where bytes.isEmpty == false:
            let start = position(bytes.count, &random)
            let end = min(bytes.count, start + Int.random(in: 1...16, using: &random))
            bytes.removeSubrange(start..<end)
        case 5 where bytes.isEmpty == false:
            let start = position(bytes.count, &random)
            let end = min(bytes.count, start + Int.random(in: 1...32, using: &random))
            bytes.insert(contentsOf: bytes[start..<end], at: position(bytes.count + 1, &random))
        case 6 where bytes.isEmpty == false:
            bytes = Array(bytes.prefix(position(bytes.count, &random)))
        case 7 where seeds.isEmpty == false:
            let other = seeds.randomElement(using: &random)!
            let cut = position(bytes.count + 1, &random)
            let otherCut = position(other.count + 1, &random)
            bytes = Array(bytes.prefix(cut)) + other.dropFirst(otherCut)
        case 8 where bytes.count >= 2:
            // Big-endian 16-bit field set to an extreme: length prefixes.
            let index = position(bytes.count - 1, &random)
            let value: UInt16 = [0x0000, 0x0001, 0x7FFF, 0x8000, 0xFFFF].randomElement(using: &random)!
            bytes[index] = UInt8(value >> 8)
            bytes[index + 1] = UInt8(value & 0xFF)
        default:
            bytes.append(interestingBytes.randomElement(using: &random)!)
        }
        return bytes
    }

    /// Printable rendering for a failure message: enough to replay.
    static func describe(_ bytes: [UInt8]) -> String {
        "base64:" + Data(bytes).base64EncodedString()
    }
}
