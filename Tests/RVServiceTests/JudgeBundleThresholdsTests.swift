import Foundation
import RVDomain
import RVJudgePool
import RVLaya
import RVPolicy
import Testing
@testable import RVService

/// A verdict as the judge pool sends it, optionally carrying a v3 bundle's
/// calibrated thresholds.
private func calibratedVerdict(
    choice: String = "allow",
    risk: Double,
    thresholds: String? = nil
) -> Data {
    let extra = thresholds.map { #","bundleThresholds":\#($0)"# } ?? ""
    return Data("""
    {"choice":"\(choice)","probabilities":{"allow":0.5,"review":0.25,"block":0.25},\
    "riskScore":\(risk),"malicious":0.25,"risk":\(risk),"checkpoint":"laya-ft-v3-fp16",\
    "latencyMilliseconds":1,"truncated":false\(extra)}
    """.utf8)
}

private func decoded(_ data: Data) throws -> LayaVerdict {
    try JSONDecoder().decode(LayaVerdict.self, from: data)
}

private let trustedProvenance: [ActionProvenance] = [.unknown, .userTyped, .agentPlan]
private let untrustedProvenance: [ActionProvenance] = [.toolOutput, .web, .email]

@Suite("Judge bundle thresholds (v3 calibration)")
struct JudgeBundleThresholdsTests {
    static let allow = EvaluationResult(outcome: .plain, matchingView: "make deploy", analysis: .unknown)

    @Test("v2 bundle (no thresholds): the fixed operating point, unchanged",
          arguments: trustedProvenance + untrustedProvenance)
    func v2Unchanged(provenance: ActionProvenance) throws {
        #expect(JudgeRuntime.thresholds(provenance: provenance, bundle: nil)
            == JudgeRuntime.thresholds(provenance: provenance))
        for risk in [0.1, 0.29, 0.3, 0.45, 0.5, 0.6, 0.79, 0.8, 0.95] {
            let verdict = try decoded(calibratedVerdict(risk: risk))
            #expect(verdict.bundleThresholds == nil)
            let fixed = JudgeRuntime.thresholds(provenance: provenance)
            let reading = JudgeRuntime.read(.verdict(verdict), over: Self.allow, provenance: provenance)
            #expect(reading.action == verdict.action(blockThreshold: fixed.block, reviewThreshold: fixed.review))
            #expect(reading.operatingPoint == nil)
        }
    }

    @Test("v3 trusted provenance reads at the bundle's thresholds", arguments: trustedProvenance)
    func v3Trusted(provenance: ActionProvenance) throws {
        let bundle = try LayaThresholds(block: 0.9, review: 0.5)
        #expect(JudgeRuntime.thresholds(provenance: provenance, bundle: bundle) == (0.9, 0.5))
        let looser = try LayaThresholds(block: 0.95, review: 0.6)
        #expect(JudgeRuntime.thresholds(provenance: provenance, bundle: looser) == (0.95, 0.6))

        // risk 0.85 blocks at the fixed 0.8 but only reviews at the bundle's 0.9.
        let verdict = try decoded(calibratedVerdict(risk: 0.85, thresholds: #"{"block":0.9,"review":0.5}"#))
        #expect(verdict.bundleThresholds == bundle)
        let reading = JudgeRuntime.read(.verdict(verdict), over: Self.allow, provenance: provenance)
        #expect(reading.action == .review)
        #expect(reading.operatingPoint == bundle)
        // risk 0.47 reviews at the fixed 0.45 but allows at the bundle's 0.5.
        let low = try decoded(calibratedVerdict(risk: 0.47, thresholds: #"{"block":0.9,"review":0.5}"#))
        #expect(JudgeRuntime.read(.verdict(low), over: Self.allow, provenance: provenance).action == .allow)
    }

    @Test("v3 untrusted provenance takes the stricter of bundle and fixed, per threshold",
          arguments: untrustedProvenance)
    func v3Untrusted(provenance: ActionProvenance) throws {
        let loose = try LayaThresholds(block: 0.9, review: 0.5)
        #expect(JudgeRuntime.thresholds(provenance: provenance, bundle: loose) == (0.6, 0.30))
        let strict = try LayaThresholds(block: 0.5, review: 0.2)
        #expect(JudgeRuntime.thresholds(provenance: provenance, bundle: strict) == (0.5, 0.2))
        let mixed = try LayaThresholds(block: 0.7, review: 0.25)
        #expect(JudgeRuntime.thresholds(provenance: provenance, bundle: mixed) == (0.6, 0.25))

        // A loose calibration never loosens untrusted input: 0.65 still blocks.
        let verdict = try decoded(calibratedVerdict(risk: 0.65, thresholds: #"{"block":0.9,"review":0.5}"#))
        let reading = JudgeRuntime.read(.verdict(verdict), over: Self.allow, provenance: provenance)
        let used = try LayaThresholds(block: 0.6, review: 0.30)
        #expect(reading.action == .block)
        #expect(reading.operatingPoint == used)
    }

    @Test("invalid bundle thresholds are refused", arguments: [
        (0.5, 0.5), (0.4, 0.5), (1.2, 0.5), (0.8, 0.0), (0.8, -0.1),
        (Double.nan, 0.3), (0.8, Double.infinity),
    ])
    func invalidThresholdsRefused(block: Double, review: Double) {
        #expect(throws: LayaError.self) { try LayaThresholds(block: block, review: review) }
    }

    @Test("a pool verdict carrying invalid thresholds is a prediction failure, never an allow", arguments: [
        #"{"block":0.3,"review":0.5}"#,
        #"{"block":1.5,"review":0.5}"#,
        #"{"block":0.8}"#,
        #""high""#,
    ])
    func invalidWireThresholdsFail(thresholds: String) {
        let data = calibratedVerdict(risk: 0.1, thresholds: thresholds)
        guard case .failed = JudgeRuntime.read(.verdict(data, slot: .primary)) else {
            Issue.record("invalid bundle thresholds must map to failed")
            return
        }
    }

    @Test("the judge log carries the operating point only when it came from the bundle")
    func logRowOperatingPoint() throws {
        let root = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: root.path))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bundle = try LayaThresholds(block: 0.9, review: 0.5)
        let cases: [(String?, LayaThresholds?)] = [(nil, nil), (#"{"block":0.9,"review":0.5}"#, bundle)]
        for (thresholds, expected) in cases {
            let verdict = try decoded(calibratedVerdict(risk: 0.2, thresholds: thresholds))
            let reading = JudgeRuntime.read(.verdict(verdict), over: Self.allow, provenance: .userTyped)
            let row = JudgeRuntime.logRow(
                guardMode: .observe, subject: .wouldBe(reading.outcome),
                verdict: reading.verdict, action: reading.action, engine: .ft,
                note: nil, now: now, isPeek: false, operatingPoint: reading.operatingPoint
            )
            #expect(row.score?.thresholds == expected)
            JudgeRuntime.appendLog(row, home: home)
        }
        let lines = try judgeLogText(home).split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(lines.count == 2)
        #expect(lines[0].keys.contains("thresholds") == false)
        let logged = try #require(lines[1]["thresholds"] as? [String: Double])
        #expect(logged == ["block": 0.9, "review": 0.5])
    }
}

@Suite("Doctor bundle calibration (FT config)")
struct BundleCalibrationDoctorTests {
    private func bundle(config: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-doctor-cal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: dir.appendingPathComponent("config.json"))
        return dir
    }

    @Test("an invalid calibration is a bundle problem", arguments: [
        #"{"temperature":0}"#,
        #"{"temperature":"1.5"}"#,
        #"{"temperature":40}"#,
        #"{"thresholds":{"block":0.4,"review":0.6}}"#,
        #"{"thresholds":{"block":0.9}}"#,
        #"{"thresholds":[0.9,0.5]}"#,
    ])
    func invalidCalibrationIsReported(config: String) throws {
        let dir = try bundle(config: config)
        defer { try? FileManager.default.removeItem(at: dir) }
        let problems = JudgeRuntime.bundleProblems(engine: .ft, dir: dir)
        #expect(problems.contains("config calibration invalid (temperature or thresholds)"))
        #expect(JudgeRuntime.calibrationNote(bundle: dir) == nil)
    }

    @Test("a v3 calibration passes and doctor shows the bundle's thresholds")
    func v3CalibrationShown() throws {
        let dir = try bundle(config: #"{"temperature":1.7,"thresholds":{"block":0.97,"review":0.5}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!JudgeRuntime.bundleProblems(engine: .ft, dir: dir).contains(where: { $0.contains("calibration") }))
        let note = try #require(JudgeRuntime.calibrationNote(bundle: dir))
        #expect(note.contains("block 0.97"))
        #expect(note.contains("review 0.5"))
        #expect(note.contains("temperature 1.7"))
    }

    @Test("a v2 config has no calibration note and no calibration problem")
    func v2NoNote() throws {
        let dir = try bundle(config: #"{"labels":["allow","review","block"],"max_len":512}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!JudgeRuntime.bundleProblems(engine: .ft, dir: dir).contains(where: { $0.contains("calibration") }))
        #expect(JudgeRuntime.calibrationNote(bundle: dir) == nil)
    }
}
