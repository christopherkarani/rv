import Foundation
import Testing
@testable import RVLaya

private func config(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

/// The v3 bundle calibration (`config.json` temperature + thresholds), parsed
/// without Core ML: the same parser the loader and `rv doctor` use.
@Suite("Fine-tuned bundle calibration")
struct FineTunedCalibrationTests {
    @Test("a v2 config (no calibration keys) is uncalibrated")
    func v2Uncalibrated() throws {
        let cfg = try config(#"{"labels":["allow","review","block"],"max_len":512,"lengths":[16,512]}"#)
        #expect(try FineTunedCalibration.parse(cfg) == .uncalibrated)
        #expect(try FineTunedCalibration.parse([:]).temperature == 1)
        #expect(try FineTunedCalibration.parse([:]).thresholds == nil)
    }

    @Test("a v3 config parses temperature and thresholds")
    func v3Parses() throws {
        let cal = try FineTunedCalibration.parse(
            config(#"{"temperature":1.7,"thresholds":{"block":0.97,"review":0.5}}"#))
        #expect(cal.temperature == 1.7)
        let expected = try LayaThresholds(block: 0.97, review: 0.5)
        #expect(cal.thresholds == expected)
        // Integer JSON numbers and the range ends are accepted.
        let edge = try FineTunedCalibration.parse(config(#"{"temperature":20,"thresholds":{"block":1,"review":0.05}}"#))
        #expect(edge.temperature == 20)
        #expect(edge.thresholds?.block == 1)
        #expect(try FineTunedCalibration.parse(config(#"{"temperature":0.05}"#)).temperature == 0.05)
    }

    @Test("an invalid calibration is a bad bundle", arguments: [
        #"{"temperature":0}"#,
        #"{"temperature":-1}"#,
        #"{"temperature":0.049}"#,
        #"{"temperature":20.5}"#,
        #"{"temperature":"1.5"}"#,
        #"{"temperature":null}"#,
        #"{"thresholds":{"block":0.5,"review":0.5}}"#,
        #"{"thresholds":{"block":0.4,"review":0.6}}"#,
        #"{"thresholds":{"block":1.01,"review":0.5}}"#,
        #"{"thresholds":{"block":0.9,"review":0}}"#,
        #"{"thresholds":{"block":0.9,"review":-0.2}}"#,
        #"{"thresholds":{"block":0.9}}"#,
        #"{"thresholds":{"block":"0.9","review":0.5}}"#,
        #"{"thresholds":[0.9,0.5]}"#,
        #"{"thresholds":null}"#,
    ])
    func invalidIsBadBundle(json: String) throws {
        let cfg = try config(json)
        #expect(throws: LayaError.self) { try FineTunedCalibration.parse(cfg) }
    }

    @Test("non-finite thresholds are refused")
    func nonFiniteRefused() {
        #expect(throws: LayaError.self) { try LayaThresholds(block: .nan, review: 0.3) }
        #expect(throws: LayaError.self) { try LayaThresholds(block: 0.8, review: .infinity) }
    }

    @Test("temperature 1 is the plain softmax, bit for bit")
    func temperatureOneIsPlainSoftmax() {
        let z = [1.25, -0.5, 3.0]
        let peak = z.max()!
        let exps = z.map { exp($0 - peak) }
        let total = exps.reduce(0, +)
        let plain = exps.map { $0 / total }
        #expect(FineTunedCalibration.uncalibrated.probabilities(logits: z) == plain)
    }

    @Test("temperature above 1 flattens, below 1 sharpens, argmax kept")
    func temperatureScales() throws {
        let z = [0.0, 1.0, 3.0]
        let plain = FineTunedCalibration.uncalibrated.probabilities(logits: z)
        let hot = try FineTunedCalibration.parse(config(#"{"temperature":2}"#)).probabilities(logits: z)
        let cold = try FineTunedCalibration.parse(config(#"{"temperature":0.5}"#)).probabilities(logits: z)
        #expect(hot[2] < plain[2] && plain[2] < cold[2])
        #expect(abs(hot.reduce(0, +) - 1) < 1e-12)
        #expect(abs(cold.reduce(0, +) - 1) < 1e-12)
        // softmax(z / 2) == softmax(z * 0.5)
        let halved = FineTunedCalibration.uncalibrated.probabilities(logits: z.map { $0 * 0.5 })
        for (a, b) in zip(hot, halved) { #expect(abs(a - b) < 1e-12) }
    }

    @Test("a verdict without bundle thresholds keeps its pinned wire bytes; with them it round-trips")
    func verdictWire() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(LayaVerdictTests.verdict), as: UTF8.self) == LayaVerdictTests.pinned)
        var calibrated = LayaVerdictTests.verdict
        calibrated.bundleThresholds = try LayaThresholds(block: 0.9, review: 0.4)
        let data = try encoder.encode(calibrated)
        #expect(String(decoding: data, as: UTF8.self).contains(#""bundleThresholds":{"#))
        #expect(try JSONDecoder().decode(LayaVerdict.self, from: data) == calibrated)
    }

    #if canImport(CoreML)
    /// The loader refuses an invalid calibration before touching the model.
    @Test(arguments: [
        #"{"temperature":0}"#,
        #"{"thresholds":{"block":0.3,"review":0.6}}"#,
    ])
    func fineTunedBundleWithBadCalibrationFailsLoading(config: String) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("laya-cal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model":{"vocab":{},"merges":[]}}"#.utf8)
            .write(to: dir.appendingPathComponent("tokenizer.json"))
        try Data(config.utf8).write(to: dir.appendingPathComponent("config.json"))
        #expect {
            _ = try FineTunedJudge(bundleDir: dir)
        } throws: { error in
            guard case LayaError.badBundle(let why) = error else { return false }
            return why.contains("temperature") || why.contains("thresholds")
        }
    }

    /// A valid v3 calibration gets past config parsing: the load fails only
    /// on the missing model package.
    @Test func fineTunedBundleWithValidCalibrationParses() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("laya-cal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"model":{"vocab":{},"merges":[]}}"#.utf8)
            .write(to: dir.appendingPathComponent("tokenizer.json"))
        try Data(#"{"temperature":1.7,"thresholds":{"block":0.97,"review":0.5}}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        #expect {
            _ = try FineTunedJudge(bundleDir: dir)
        } throws: { error in
            guard case LayaError.badBundle(let why) = error else { return false }
            return why.contains("model.mlpackage")
        }
    }
    #endif
}
