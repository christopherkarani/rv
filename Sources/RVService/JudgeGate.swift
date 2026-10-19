import Foundation
import RVDomain
import RVHistory
import RVLaya
import RVPolicy

/// Guard posture for the whole evaluate door — packs and judge alike.
public enum GuardMode: String, Sendable {
    /// Normal operation: packs deny, judge (when on) may raise an allow.
    case enforce
    /// Everything is evaluated and logged, nothing blocks. The would-be
    /// verdict (packs, script check, judge) lands in judge-log.jsonl.
    case observe
}

/// Laya judge wiring for the gated evaluate door.
///
/// One config knob (~/.config/rv/config.json; env wins over file):
/// `guard.mode` / `RV_GUARD_MODE`: `enforce` (default) | `observe`.
///
/// The judge runs whenever a weights bundle is installed: it binds in
/// enforce mode and only logs in observe mode. No bundle means packs-only
/// operation (doctor reports it). In enforce mode the judge only sees
/// calls the packs allowed; a pack deny is a floor it cannot lower, and a
/// judge prediction failure fails closed to Ask. In observe mode the door
/// always allows and logs what enforcement would have done. Evidence:
/// docs/plans/laya-judge-decision-record.md.
public enum JudgeRuntime {
    private static let slot = JudgeSlot()

    public static func thresholds(provenance: ActionProvenance) -> (block: Double, review: Double) {
        provenance.isUntrusted ? (0.6, 0.30) : (0.8, 0.45)
    }

    public static func guardMode(home: HomeDirectory?) -> GuardMode {
        if let raw = ProcessInfo.processInfo.environment["RV_GUARD_MODE"],
           let mode = GuardMode(rawValue: raw) {
            return mode
        }
        if let raw = configValue("guard.mode", home: home), let mode = GuardMode(rawValue: raw) {
            return mode
        }
        return .enforce
    }

    static func configValue(_ key: String, home: HomeDirectory?) -> String? {
        guard let home else { return nil }
        let file = RVPolicyPaths.configDirectory(home: home).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root[key] as? String
    }

    /// A directory only counts as a bundle when a model artifact is in it;
    /// anything else (unset, empty, wrong path) means packs-only.
    public static func bundleDir(home: HomeDirectory?) -> URL? {
        func valid(_ dir: URL) -> URL? {
            let fm = FileManager.default
            let hasModel = fm.fileExists(atPath: dir.appendingPathComponent("model.mlpackage").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("laya.onnx").path)
            return hasModel ? dir : nil
        }
        if let raw = ProcessInfo.processInfo.environment["RV_LAYA_BUNDLE"], !raw.isEmpty {
            return valid(URL(fileURLWithPath: raw))
        }
        guard let home else { return nil }
        return valid(
            RVPolicyPaths.configDirectory(home: home)
                .appendingPathComponent("models/laya-multilingual-coreml", isDirectory: true)
        )
    }

    /// Enforce path: judge may raise a pack-allow. Deny untouched.
    public static func apply(
        to result: EvaluationResult,
        command: ShellCommand,
        home: HomeDirectory?,
        provenance: ActionProvenance = .unknown,
        now: Date = Date()
    ) -> EvaluationResult {
        guard case .allow = result.decision else { return result }
        if SafeCommandLane.isSafe(command.rawValue) {
            log(home: home, live: result, wouldBe: nil, verdict: nil, note: "safe-lane", now: now)
            return result
        }
        guard bundleDir(home: home) != nil else { return result }
        let verdict = runJudge(command: command, home: home)
        log(home: home, live: result, wouldBe: nil, verdict: verdict, now: now)
        guard let verdict else { return raise(result, verdict: nil) }
        let t = thresholds(provenance: provenance)
        switch verdict.action(blockThreshold: t.block, reviewThreshold: t.review) {
        case .allow:
            return result
        case .review, .block:
            return raise(result, verdict: verdict)
        }
    }

    /// Observe path: log the would-be verdict, always allow.
    public static func observe(
        wouldBe result: EvaluationResult,
        command: ShellCommand,
        home: HomeDirectory?,
        provenance: ActionProvenance = .unknown,
        now: Date = Date()
    ) -> EvaluationResult {
        var verdict: LayaVerdict?
        let safe = SafeCommandLane.isSafe(command.rawValue)
        if !safe, bundleDir(home: home) != nil, case .allow = result.decision {
            verdict = runJudge(command: command, home: home)
        }
        log(home: home, live: nil, wouldBe: result, verdict: verdict, note: safe ? "safe-lane" : nil, now: now)
        return EvaluationResult(
            outcome: .plain,
            matchingView: result.matchingView,
            analysis: result.analysis
        )
    }

    static func runJudge(command: ShellCommand, home: HomeDirectory?) -> LayaVerdict? {
        guard let bundle = bundleDir(home: home) else { return nil }
        #if canImport(CoreML)
        return try? slot.judge(bundleDir: bundle).judge(command.rawValue)
        #else
        return nil
        #endif
    }

    /// Judge block pins (boundReview .deny); review/abstain unlockable (Ask).
    static func raise(_ result: EvaluationResult, verdict: LayaVerdict?) -> EvaluationResult {
        let isBlock = verdict.map { $0.action() == .block } ?? false
        let reason = verdict.map {
            "Laya judge: \($0.choice) (risk \(String(format: "%.2f", $0.risk)))"
        } ?? "Laya judge unavailable; failing closed"
        let deny = Deny(
            ruleID: RuleID(pack: PackID(rawValue: "core.judge"), pattern: isBlock ? "laya-block" : "laya-review"),
            reason: reason
        )
        return EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: result.matchingView,
            analysis: result.analysis,
            boundReview: isBlock ? .deny(deny) : nil
        )
    }

    /// Hash-only log (never command text), laya-guard parity.
    static func log(
        home: HomeDirectory?,
        live: EvaluationResult?,
        wouldBe: EvaluationResult?,
        verdict: LayaVerdict?,
        note: String? = nil,
        now: Date
    ) {
        guard let home else { return }
        let subject = wouldBe ?? live
        guard let subject else { return }
        let dir = RVPolicyPaths.configDirectory(home: home)
        let file = dir.appendingPathComponent("judge-log.jsonl")
        var row: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: now),
            "guard": guardMode(home: home).rawValue,
            "hash": String(RVDigest.sha256Hex([UInt8](subject.matchingView.rawValue.utf8)).prefix(16)),
        ]
        if let wouldBe {
            switch wouldBe.decision {
            case .allow: row["wouldBe"] = "allow"
            case .deny: row["wouldBe"] = "deny"
            case .indeterminate: row["wouldBe"] = "indeterminate"
            }
            if case .deny(let deny) = wouldBe.decision { row["wouldBeRule"] = deny.ruleID.rawValue }
            row["live"] = "allow"
        } else if let live {
            switch live.decision {
            case .allow: row["live"] = "allow"
            case .deny: row["live"] = "deny"
            case .indeterminate: row["live"] = "indeterminate"
            }
        }
        if let note { row["note"] = note }
        if let verdict {
            row["choice"] = verdict.choice
            row["action"] = verdict.action().rawValue
            row["risk"] = (verdict.risk * 1000).rounded() / 1000
            row["malicious"] = (verdict.malicious * 10000).rounded() / 10000
            row["checkpoint"] = verdict.checkpoint
            row["ms"] = (verdict.latencyMilliseconds * 10).rounded() / 10
        }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file, options: .atomic)
        }
    }
}

#if canImport(CoreML)
final class JudgeSlot: @unchecked Sendable {
    private var cached: LayaCoreMLJudge?
    private var failedBundle: URL?
    private let lock = NSLock()

    func judge(bundleDir: URL) throws -> LayaCoreMLJudge {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if failedBundle == bundleDir { throw LayaError.modelUnavailable("cached load failure") }
        do {
            let judge = try LayaCoreMLJudge(bundleDir: bundleDir)
            cached = judge
            return judge
        } catch {
            failedBundle = bundleDir
            throw error
        }
    }
}
#endif
