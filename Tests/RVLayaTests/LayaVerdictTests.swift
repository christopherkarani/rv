import Foundation
import Testing
@testable import RVLaya

@Suite("LayaVerdict wire format and labels")
struct LayaVerdictTests {
    /// Bytes produced by the pre-refactor String-keyed LayaVerdict.
    static let pinned = #"{"checkpoint":"ck","choice":"review","latencyMilliseconds":12.5,"malicious":0.25,"probabilities":{"allow":0.25,"block":0.25,"review":0.5},"risk":0.5,"riskScore":0.5,"truncated":true}"#

    static let verdict = LayaVerdict(
        choice: .review,
        probabilities: [.allow: 0.25, .review: 0.5, .block: 0.25],
        riskScore: 0.5, malicious: 0.25, risk: 0.5,
        checkpoint: "ck", latencyMilliseconds: 12.5, truncated: true
    )

    @Test func encodesToPinnedBytes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(Self.verdict), as: UTF8.self) == Self.pinned)
    }

    @Test func decodesPinnedLiteral() throws {
        let decoded = try JSONDecoder().decode(LayaVerdict.self, from: Data(Self.pinned.utf8))
        #expect(decoded == Self.verdict)
    }

    @Test func decodesLegacyLiteralWithoutTruncated() throws {
        let legacy = #"{"checkpoint":"ck","choice":"block","latencyMilliseconds":1,"malicious":0,"probabilities":{"allow":0.1,"block":0.8,"review":0.1},"risk":0.85,"riskScore":0.5}"#
        let decoded = try JSONDecoder().decode(LayaVerdict.self, from: Data(legacy.utf8))
        #expect(decoded.choice == .block)
        #expect(decoded.probabilities[.block] == 0.8)
        #expect(decoded.truncated == false)
    }

    @Test func unknownChoiceInPersistedVerdictFailsDecode() {
        let bad = Self.pinned.replacingOccurrences(of: #""choice":"review""#, with: #""choice":"revue""#)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LayaVerdict.self, from: Data(bad.utf8))
        }
    }

    @Test func guardQuestionsLabelsParse() throws {
        #expect(try LayaQuestions.guardQuestions.actionLabels() == [.allow, .review, .block])
    }

    @Test func respelledGuardQuestionLabelFailsLoading() {
        var questions = LayaQuestions.guardQuestions
        questions.action.options[2].label = "blok"
        #expect(throws: LayaError.self) { try questions.actionLabels() }
    }

    @Test func unknownConfigLabelFailsLoading() {
        #expect(throws: LayaError.self) {
            try LayaVerdict.Action.parse(labels: ["allow", "review", "deny"])
        }
    }

    /// A label set without `block` would score P(block) as 0: fail-open.
    @Test(arguments: [["allow", "review"], ["allow", "allow", "block"], ["allow", "review", "block", "block"]])
    func incompleteOrDuplicatedLabelsFailLoading(labels: [String]) {
        #expect(throws: LayaError.self) { try LayaVerdict.Action.parse(labels: labels) }
    }

    @Test func guardQuestionsWithoutBlockFailLoading() {
        var questions = LayaQuestions.guardQuestions
        questions.action.options.removeLast()
        #expect(throws: LayaError.self) { try questions.actionLabels() }
    }

    @Test func configLabelsValidPermutationAndPrecedence() throws {
        let order = try LayaVerdict.Action.configLabels(
            ["logit_order": ["block", "review", "allow"], "labels": ["allow", "review", "block"]])
        #expect(order == [.block, .review, .allow])
        #expect(try LayaVerdict.Action.configLabels(["labels": ["review", "allow", "block"]]) == [.review, .allow, .block])
        #expect(try LayaVerdict.Action.configLabels(["max_len": 64]) == nil)
    }

    @Test(arguments: [
        #"{"logit_order":"allow,review,block"}"#,
        #"{"logit_order":null}"#,
        #"{"logit_order":["allow","review","block","block"]}"#,
        #"{"labels":["allow","review"]}"#,
        #"{"logit_order":["allow","bogus","block"],"labels":["allow","review","block"]}"#,
    ])
    func configLabelsInvalidThrows(json: String) throws {
        let cfg = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(throws: LayaError.self) { try LayaVerdict.Action.configLabels(cfg) }
    }

    #if canImport(CoreML)
    /// Each compute-unit configuration has its own compiled-model entry, and
    /// a given root (the judge pool's private directory) is the only place
    /// an entry is looked for.
    @Test func compiledCacheEntryIsPerComputeUnitsUnderTheGivenRoot() {
        let package = URL(fileURLWithPath: "/models/laya-ft-v2-coreml/model.mlpackage")
        let root = URL(fileURLWithPath: "/Users/u/.config/rv/cache/judge/rv-judge-0123", isDirectory: true)
        let cpu = CompiledModelCache.entry(package: package, computeUnits: .cpu, root: root)
        let accelerated = CompiledModelCache.entry(package: package, computeUnits: .accelerated, root: root)
        #expect(cpu != accelerated)
        #expect(cpu.deletingLastPathComponent().path == root.path)
        #expect(accelerated.deletingLastPathComponent().path == root.path)
    }

    /// The pool's private root must already be an owner-only directory: a
    /// missing, widened or linked root fails the load (the pool answers
    /// review) and is never created or repaired.
    @Test func privateCompiledCacheRootIsNeverCreatedOrRepaired() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("laya-root-\(UUID().uuidString)")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        let package = parent.appendingPathComponent("model.mlpackage")
        let shared = parent.appendingPathComponent("shared", isDirectory: true)

        let missing = parent.appendingPathComponent("missing", isDirectory: true)
        let widened = parent.appendingPathComponent("widened", isDirectory: true)
        try fm.createDirectory(at: widened, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let target = parent.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let linked = parent.appendingPathComponent("linked", isDirectory: true)
        try fm.createSymbolicLink(at: linked, withDestinationURL: target)

        for root in [missing, widened, linked] {
            #expect {
                _ = try CompiledModelCache.load(package: package, computeUnits: .cpu, root: root, sharedRoot: shared)
            } throws: { error in
                guard case LayaError.modelUnavailable(let why) = error else { return false }
                return why.contains("owner-only")
            }
        }
        #expect(!fm.fileExists(atPath: missing.path))
        #expect((try fm.attributesOfItem(atPath: widened.path)[.posixPermissions] as? Int) == 0o755)
        #expect(!fm.fileExists(atPath: shared.path), "the shared cache is never touched")
    }

    /// With a real bundle (RV_FT_BUNDLE): the pool's load compiles into the
    /// private root and never reads or writes the shared cache.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RV_FT_BUNDLE"] != nil))
    func privateLoadNeverTouchesTheSharedCache() throws {
        let bundle = try #require(ProcessInfo.processInfo.environment["RV_FT_BUNDLE"])
        let package = URL(fileURLWithPath: bundle).appendingPathComponent("model.mlpackage")
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("laya-private-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("root", isDirectory: true)
        let shared = parent.appendingPathComponent("shared", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: parent) }
        _ = try CompiledModelCache.load(package: package, computeUnits: .cpu, root: root, sharedRoot: shared)
        let entry = CompiledModelCache.entry(package: package, computeUnits: .cpu, root: root)
        #expect(fm.fileExists(atPath: entry.path))
        #expect(!fm.fileExists(atPath: shared.path))
    }

    /// AC-004 end to end: the bundle's config labels are checked at load,
    /// before any model file is touched.
    @Test func fineTunedBundleWithUnknownLabelFailsLoading() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("laya-labels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model":{"vocab":{},"merges":[]}}"#.utf8)
            .write(to: dir.appendingPathComponent("tokenizer.json"))
        try Data(#"{"labels":["allow","review","deny"]}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        #expect {
            _ = try FineTunedJudge(bundleDir: dir)
        } throws: { error in
            guard case LayaError.badBundle(let why) = error else { return false }
            return why.contains("deny")
        }
    }

    private func ftBundle(config: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("laya-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"model":{"vocab":{},"merges":[]}}"#.utf8)
            .write(to: dir.appendingPathComponent("tokenizer.json"))
        if let config { try Data(config.utf8).write(to: dir.appendingPathComponent("config.json")) }
        return dir
    }

    /// Absent config keeps the default order: the load proceeds past config
    /// parsing and fails only on the missing model package.
    @Test func absentConfigKeepsDefaultOrder() throws {
        let dir = try ftBundle(config: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect {
            _ = try FineTunedJudge(bundleDir: dir)
        } throws: { error in
            guard case LayaError.badBundle(let why) = error else { return false }
            return why.contains("model.mlpackage")
        }
    }

    @Test func unparseableConfigFailsLoading() throws {
        let dir = try ftBundle(config: "{not json")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect {
            _ = try FineTunedJudge(bundleDir: dir)
        } throws: { error in
            guard case LayaError.badBundle(let why) = error else { return false }
            return why.contains("config.json")
        }
    }

    @Test(arguments: [
        #"{"logit_order":["allow","review"]}"#,
        #"{"logit_order":["allow","allow","block"]}"#,
        #"{"logit_order":"allow,review,block"}"#,
        #"{"labels":["block","review"]}"#,
    ])
    func invalidLabelOrderFailsLoading(config: String) throws {
        let dir = try ftBundle(config: config)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect {
            _ = try FineTunedJudge(bundleDir: dir)
        } throws: { error in
            guard case LayaError.badBundle(let why) = error else { return false }
            return !why.contains("model.mlpackage")
        }
    }

    @Test func stockJudgeRejectsBadLabelsAtBuild() throws {
        var questions = LayaQuestions.guardQuestions
        questions.action.options[2].label = "blok"
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-bundle-\(UUID().uuidString)")
        #expect {
            _ = try LayaCoreMLJudge(bundleDir: missing, questions: questions)
        } throws: { error in
            guard case LayaError.badBundle(let why) = error else { return false }
            return why.contains("blok")
        }
    }
    #endif
}
