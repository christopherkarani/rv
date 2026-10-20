import Foundation

#if canImport(CoreML)
import CoreML
#endif

/// Session context for the fine-tuned judge, serialized EXACTLY as the v2
/// training format (Scripts/laya/training/README.md, Dataset v2 spec):
///
///   <command>
///   cwd-inside-repo: yes|no
///   agent-touched: <comma-joined touched files, max 8, sorted>
///   git: untracked <n>, modified <m>, staged <n>
///
/// The agent-touched line is omitted when the list is empty; the git line is
/// omitted unless all three counts are known (training omits it when
/// gitStatus is absent). Rows without context are the bare command. Ticket 5b
/// feeds this from runtime state; the serializer here must not change without
/// retraining.
public struct JudgeContext: Sendable, Equatable {
    /// nil omits the cwd-inside-repo line (training: gitRemote key absent).
    public var cwdInsideRepo: Bool?
    public var agentTouched: [String]
    public var gitUntracked: Int?
    public var gitModified: Int?
    public var gitStaged: Int?

    public init(
        cwdInsideRepo: Bool? = nil,
        agentTouched: [String] = [],
        gitUntracked: Int? = nil,
        gitModified: Int? = nil,
        gitStaged: Int? = nil
    ) {
        self.cwdInsideRepo = cwdInsideRepo
        self.agentTouched = agentTouched
        self.gitUntracked = gitUntracked
        self.gitModified = gitModified
        self.gitStaged = gitStaged
    }

    /// Context lines only (without the command), in training order.
    public func lines() -> [String] {
        var out: [String] = []
        if let inside = cwdInsideRepo {
            out.append("cwd-inside-repo: \(inside ? "yes" : "no")")
        }
        // Scalar-value order == Python codepoint order (Swift's default
        // sort uses canonical equivalence, which misorders confusables).
        let touched = agentTouched.sorted {
            $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars)
        }.prefix(8)
        if !touched.isEmpty {
            out.append("agent-touched: \(touched.joined(separator: ","))")
        }
        if let u = gitUntracked, let m = gitModified, let s = gitStaged {
            out.append("git: untracked \(u), modified \(m), staged \(s)")
        }
        return out
    }

    /// Full model input text for a command. Empty context is the bare command.
    public func serialize(command: String) -> String {
        ([command] + lines()).joined(separator: "\n")
    }
}

#if canImport(CoreML)
/// Single-pass 3-class Laya judge from the Ticket 4b fine-tune.
/// Load once (compilation is slow), reuse. Unlike LayaCoreMLJudge (three
/// Korean questions over a frozen multilingual encoder), this runs one
/// forward pass: [BOS] + token ids (no specials) + [EOS] through the
/// fine-tuned encoder + Linear head, softmax over [allow, review, block].
public final class FineTunedJudge: @unchecked Sendable {
    let model: MLModel
    let tokenizer: LayaTokenizer
    public let checkpoint: String
    public let labels: [String]
    let maxLen: Int
    let lengths: [Int]
    let lock = NSLock()

    public init(bundleDir: URL) throws {
        let fm = FileManager.default
        let directTok = bundleDir.appendingPathComponent("tokenizer.json")
        let nestedTok = bundleDir.appendingPathComponent("tokenizer/tokenizer.json")
        let tokURL: URL
        if fm.fileExists(atPath: directTok.path) {
            tokURL = directTok
        } else if fm.fileExists(atPath: nestedTok.path) {
            tokURL = nestedTok
        } else {
            throw LayaError.badBundle("tokenizer.json missing in \(bundleDir.path)")
        }
        tokenizer = try LayaTokenizer(tokenizerJSON: tokURL)

        var labels = ["allow", "review", "block"]
        var maxLen = 512
        var lengths = [16, 32, 64, 96, 128, 192, 256, 384, 512]
        var checkpoint = "laya-ft-v2-fp16"
        let configURL = bundleDir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
           let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let l = cfg["logit_order"] as? [String], l.count == 3 { labels = l }
            else if let l = cfg["labels"] as? [String], l.count == 3 { labels = l }
            if let m = (cfg["max_len"] as? NSNumber)?.intValue { maxLen = m }
            if let ls = cfg["lengths"] as? [NSNumber] {
                let parsed = ls.map(\.intValue).filter { $0 > 0 }.sorted()
                if !parsed.isEmpty { lengths = parsed }
            }
            if let c = cfg["checkpoint"] as? String, !c.isEmpty { checkpoint = c }
        }
        // Unknown or permuted-to-wrong-meaning labels must never load:
        // probabilities are read by label name, so a label set without
        // exactly allow/review/block would silently score risk 0.
        guard labels.count == 3, Set(labels) == ["allow", "review", "block"] else {
            throw LayaError.badBundle("config labels are not exactly allow/review/block")
        }
        guard (16...8192).contains(maxLen) else {
            throw LayaError.badBundle("implausible max_len in config.json")
        }
        let validLengths = Array(Set(lengths.filter { (1...8192).contains($0) })).sorted()
        guard !validLengths.isEmpty else {
            throw LayaError.badBundle("no usable lengths in config.json")
        }
        self.labels = labels
        self.maxLen = maxLen
        self.lengths = validLengths
        self.checkpoint = checkpoint

        let package = bundleDir.appendingPathComponent("model.mlpackage")
        guard fm.fileExists(atPath: package.path) else {
            throw LayaError.badBundle("model.mlpackage missing in \(bundleDir.path)")
        }
        // Via CompiledModelCache (cpuAndGPU). (An earlier cpuOnly pin
        // here was a misdiagnosis: the per-process flips then were
        // mistokenization — String-keyed vocab tables resolving
        // homoglyph twins — fixed in LayaTokenizer by byte-exact keys,
        // verified 0/348 id mismatches vs HF.)
        model = try CompiledModelCache.load(package: package)
    }

    /// Judge one command with pre-rendered context lines (JudgeContext.lines()
    /// order). The model input is command + "\n" + context lines, tokenized
    /// with no specials, then [BOS] + ids.prefix(510) + [EOS].
    public func judge(_ command: String, contextLines: [String] = []) throws -> LayaVerdict {
        let start = Date()
        let text = ([command] + contextLines).joined(separator: "\n")
        // Bounded encode: detects truncation (token budget or symbol
        // cap) without paying the quadratic BPE cost of the whole
        // untrusted input.
        let budget = max(0, maxLen - 2)
        let encoded = tokenizer.encodeBounded(text, maxTokens: budget)
        let truncated = encoded.truncated
        let body = encoded.ids
        var ids = [tokenizer.clsID] + body + [tokenizer.sepID]
        let length = lengths.first { $0 >= ids.count } ?? maxLen
        if ids.count > length { ids = Array(ids.prefix(length)) }

        func array(_ shape: [Int], fill: Int32 = 0) throws -> MLMultiArray {
            let a = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .int32)
            for i in 0..<a.count { a[i] = NSNumber(value: fill) }
            return a
        }
        let inputIDs = try array([1, length], fill: tokenizer.padID)
        let attention = try array([1, length])
        for (i, id) in ids.enumerated() {
            inputIDs[i] = NSNumber(value: id)
            attention[i] = 1
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIDs),
            "attention_mask": MLFeatureValue(multiArray: attention),
        ])
        lock.lock()
        defer { lock.unlock() }
        let out = try model.prediction(from: provider)
        guard let logits = out.featureValue(for: "logits")?.multiArrayValue,
              logits.count == labels.count else {
            throw LayaError.predictionFailed("missing logits output")
        }
        let z: [Double] = (0..<labels.count).map { logits[$0].doubleValue }
        guard z.allSatisfy(\.isFinite) else {
            throw LayaError.predictionFailed("non-finite logits")
        }
        let peak = z.max() ?? 0
        let exps = z.map { exp($0 - peak) }
        let total = exps.reduce(0, +)
        let probs = exps.map { $0 / max(total, .leastNonzeroMagnitude) }

        var probabilities: [String: Double] = [:]
        for (label, p) in zip(labels, probs) { probabilities[label] = p }
        let choice = labels.enumerated().max { probs[$0.offset] < probs[$1.offset] }?.element ?? "review"

        // Single-pass head: no separate risk/malicious questions. Risk keeps
        // the laya-guard formula; malicious is P(block) by definition here.
        let risk = min(1.0, max(0.0,
            (probabilities["block"] ?? 0) + 0.5 * (probabilities["review"] ?? 0)))
        let malicious = probabilities["block"] ?? 0
        guard risk.isFinite, malicious.isFinite else {
            throw LayaError.predictionFailed("non-finite verdict")
        }
        return LayaVerdict(
            choice: choice,
            probabilities: probabilities,
            riskScore: risk,
            malicious: malicious,
            risk: risk,
            checkpoint: checkpoint,
            latencyMilliseconds: Date().timeIntervalSince(start) * 1000,
            truncated: truncated
        )
    }

    /// Judge one command with structured session context.
    public func judge(_ command: String, context: JudgeContext) throws -> LayaVerdict {
        try judge(command, contextLines: context.lines())
    }
}
#else
/// Linux seam: CoreML is unavailable, so the fine-tuned judge cannot run.
/// The gate treats this as unavailable; it never invents an allow.
public struct FineTunedJudge: Sendable {
    public init(bundleDir: URL) throws {
        throw LayaError.modelUnavailable("CoreML unavailable on this platform")
    }

    public func judge(_ command: String, contextLines: [String] = []) throws -> LayaVerdict {
        throw LayaError.modelUnavailable("CoreML unavailable on this platform")
    }

    public func judge(_ command: String, context: JudgeContext) throws -> LayaVerdict {
        throw LayaError.modelUnavailable("CoreML unavailable on this platform")
    }
}
#endif
