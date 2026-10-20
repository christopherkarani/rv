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

/// Which judge scores a pack-allowed command.
///
/// `ft` is the Ticket 5a single-pass fine-tune (bundle
/// `models/laya-ft-v2-coreml`); `laya` is the stock three-question CoreML
/// judge (bundle `models/laya-multilingual-coreml`).
public enum JudgeEngine: String, Sendable {
    case ft
    case laya
}

/// Laya judge wiring for the gated evaluate door.
///
/// One config knob (~/.config/rv/config.json; env wins over file):
/// `guard.mode` / `RV_GUARD_MODE`: `enforce` (default) | `observe`.
/// Engine knob: `judge.engine` / `RV_JUDGE_ENGINE`: `ft` | `laya`.
///
/// Engine resolution: an explicit engine (env, then config) always wins,
/// even when its bundle is missing — a missing bundle for the SELECTED
/// engine is packs-only with an `engine-missing` log note, never
/// fail-closed. With no explicit engine the fine-tuned judge is the
/// default whenever its bundle validates (`model.mlpackage` present);
/// otherwise the gate falls back to the stock Laya bundle. Each engine is
/// slot-cached separately.
///
/// The judge runs whenever the selected engine's bundle is installed: it
/// binds in enforce mode and only logs in observe mode. No bundle means
/// packs-only (doctor reports it). In enforce mode the judge only sees
/// calls the packs allowed; a pack deny is a floor it cannot lower, and a
/// judge prediction failure fails closed to Ask. In observe mode the door
/// always allows and logs what enforcement would have done. Evidence:
/// docs/plans/laya-judge-decision-record.md.
public enum JudgeRuntime {
    private static let slot = JudgeSlot()

    static let ftBundleName = "laya-ft-v2-coreml"
    static let stockBundleName = "laya-multilingual-coreml"

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
        guard let root = loadConfigDict(home: home) else { return nil }
        return root[key] as? String
    }

    static func loadConfigDict(home: HomeDirectory?) -> [String: Any]? {
        guard let home else { return nil }
        let file = RVPolicyPaths.configDirectory(home: home).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root
    }

    /// Reads `judge.engine` from a parsed config object. Accepts the nested
    /// form (`{"judge": {"engine": "ft"}}`) and the flat dotted form
    /// (`{"judge.engine": "ft"}`). Returns nil when unset or not a string;
    /// unknown values are ignored by the resolver below.
    static func configEngine(_ config: [String: Any]?) -> String? {
        guard let config else { return nil }
        if let nested = config["judge"] as? [String: Any],
           let engine = nested["engine"] as? String, !engine.isEmpty {
            return engine
        }
        if let flat = config["judge.engine"] as? String, !flat.isEmpty {
            return flat
        }
        return nil
    }

    /// Testable engine resolution. `env` and `config` are injected (only
    /// `RV_JUDGE_ENGINE` / `judge.engine` are read); `bundleExists` probes
    /// whether an engine's bundle validates on disk, so tests need no HOME.
    ///
    /// Precedence: `RV_JUDGE_ENGINE` > `judge.engine` > FT-if-installed >
    /// stock. An explicit engine whose bundle is missing still wins
    /// (`bundlePresent` false): the gate goes packs-only with an
    /// `engine-missing` note rather than failing closed or silently
    /// switching engines.
    static func resolveEngine(
        env: [String: String],
        config: [String: Any]?,
        bundleExists: (JudgeEngine) -> Bool
    ) -> (engine: JudgeEngine, bundlePresent: Bool) {
        let explicit: JudgeEngine? =
            env["RV_JUDGE_ENGINE"].flatMap { JudgeEngine(rawValue: $0.lowercased()) }
            ?? configEngine(config).flatMap { JudgeEngine(rawValue: $0.lowercased()) }
        if let explicit {
            return (explicit, bundleExists(explicit))
        }
        if bundleExists(.ft) { return (.ft, true) }
        return (.laya, bundleExists(.laya))
    }

    /// Live engine choice: real env, real config file, real bundle probes.
    static func selectedEngine(home: HomeDirectory?) -> JudgeEngine {
        let env = ProcessInfo.processInfo.environment
        let config = loadConfigDict(home: home)
        return resolveEngine(
            env: env,
            config: config,
            bundleExists: {
                switch $0 {
                case .ft: return ftBundleDir(home: home) != nil
                case .laya: return bundleDir(home: home) != nil
                }
            }
        ).engine
    }

    /// The engine that will actually run, with its validated bundle dir.
    /// Nil when the selected engine's bundle is missing — the caller goes
    /// packs-only (never fail-closed; see `apply`).
    static func resolvedJudge(home: HomeDirectory?) -> (engine: JudgeEngine, bundle: URL)? {
        let engine = selectedEngine(home: home)
        let bundle: URL?
        switch engine {
        case .ft: bundle = ftBundleDir(home: home)
        case .laya: bundle = bundleDir(home: home)
        }
        guard let bundle else { return nil }
        return (engine, bundle)
    }

    /// Expected install dir for an engine (valid or not). Used by doctor
    /// to name where the missing bundle should go.
    static func expectedBundleDir(engine: JudgeEngine, home: HomeDirectory?) -> URL? {
        guard let home else { return nil }
        let name = engine == .ft ? ftBundleName : stockBundleName
        return RVPolicyPaths.configDirectory(home: home)
            .appendingPathComponent("models/\(name)", isDirectory: true)
    }

    /// Fine-tuned bundle: `RV_FT_BUNDLE` when set and valid, else the
    /// installed `models/laya-ft-v2-coreml`. A directory only counts when
    /// `model.mlpackage` is in it.
    public static func ftBundleDir(home: HomeDirectory?) -> URL? {
        func valid(_ dir: URL) -> URL? {
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("model.mlpackage").path
            ) ? dir : nil
        }
        if let raw = ProcessInfo.processInfo.environment["RV_FT_BUNDLE"], !raw.isEmpty {
            return valid(URL(fileURLWithPath: raw))
        }
        guard let expected = expectedBundleDir(engine: .ft, home: home) else { return nil }
        return valid(expected)
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

    /// v1 runtime context. Only signals already available at this layer:
    /// cwd plus workspace containment (`cwd-inside-repo` via the same
    /// repository-root probe the filesystem analyzer uses). Git counts stay
    /// nil — no cheap counts probe exists on this path (GitLiveProbe
    /// resolves the branch only; EvaluateSession computes no file counts).
    /// `agentTouched` stays empty — no session file-tracking exists yet,
    /// and v1 must not invent touched files from command text.
    static func judgeContext(cwd: WorkingDirectory?) -> JudgeContext {
        guard let raw = cwd?.rawValue, resolveExistingDirectory(raw) != nil else {
            return JudgeContext()
        }
        let inside = FilesystemLiveProbe.discoverRepositoryRoot(from: raw) != nil
        return JudgeContext(cwdInsideRepo: inside)
    }

    /// String/bool seam over `judgeContext` for RVServiceTests, which has
    /// no RVLaya dependency edge and must not name `JudgeContext`.
    static func judgeContextLines(cwd: WorkingDirectory?) -> [String] {
        judgeContext(cwd: cwd).lines()
    }

    /// String/bool seam over `contextIsPartial` (same reason as above).
    static func judgeContextPartial(cwd: WorkingDirectory?) -> Bool {
        contextIsPartial(judgeContext(cwd: cwd))
    }

    /// True while any context field is unknown. Always true in v1 (git
    /// counts are never probed), so judge-log rows carry it until v2 wires
    /// more signals.
    static func contextIsPartial(_ context: JudgeContext) -> Bool {
        context.cwdInsideRepo == nil || context.gitUntracked == nil
            || context.gitModified == nil || context.gitStaged == nil
    }

    static func noteFor(_ base: String?, contextPartial: Bool) -> String? {
        switch (base, contextPartial) {
        case (nil, false): return nil
        case (nil, true): return "context: partial"
        case (let b?, false): return b
        case (let b?, true): return b + "; context: partial"
        }
    }

    /// Enforce path: judge may raise a pack-allow. Deny untouched.
    public static func apply(
        to result: EvaluationResult,
        command: ShellCommand,
        home: HomeDirectory?,
        provenance: ActionProvenance = .unknown,
        now: Date = Date(),
        cwd: WorkingDirectory? = nil
    ) -> EvaluationResult {
        guard case .allow = result.decision else { return result }
        let context = judgeContext(cwd: cwd)
        let partial = contextIsPartial(context)
        if SafeCommandLane.isSafe(command.rawValue) {
            log(
                home: home, live: result, wouldBe: nil, verdict: nil,
                engine: selectedEngine(home: home),
                note: noteFor("safe-lane", contextPartial: partial), now: now
            )
            return result
        }
        // Bundle-missing for the SELECTED engine is packs-only with an
        // engine-missing note — NOT fail-closed. Fail-closed Ask applies
        // only when a loaded judge errors mid-prediction (nil verdict
        // below).
        guard let resolved = resolvedJudge(home: home) else {
            log(
                home: home, live: result, wouldBe: nil, verdict: nil,
                engine: selectedEngine(home: home),
                note: noteFor("engine-missing", contextPartial: partial), now: now
            )
            return result
        }
        let verdict = runJudge(
            command: command.rawValue, context: context,
            engine: resolved.engine, bundle: resolved.bundle
        )
        log(
            home: home, live: result, wouldBe: nil, verdict: verdict,
            engine: resolved.engine,
            note: noteFor(nil, contextPartial: partial), now: now
        )
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
        now: Date = Date(),
        cwd: WorkingDirectory? = nil
    ) -> EvaluationResult {
        let context = judgeContext(cwd: cwd)
        let partial = contextIsPartial(context)
        let safe = SafeCommandLane.isSafe(command.rawValue)
        var verdict: LayaVerdict?
        var engine = selectedEngine(home: home)
        if !safe, let resolved = resolvedJudge(home: home), case .allow = result.decision {
            engine = resolved.engine
            verdict = runJudge(
                command: command.rawValue, context: context,
                engine: resolved.engine, bundle: resolved.bundle
            )
        }
        log(
            home: home, live: nil, wouldBe: result, verdict: verdict,
            engine: engine,
            note: noteFor(safe ? "safe-lane" : nil, contextPartial: partial), now: now
        )
        return EvaluationResult(
            outcome: .plain,
            matchingView: result.matchingView,
            analysis: result.analysis
        )
    }

    static func runJudge(
        command: String,
        context: JudgeContext,
        engine: JudgeEngine,
        bundle: URL
    ) -> LayaVerdict? {
        #if canImport(CoreML)
        switch engine {
        case .laya:
            return try? slot.stockJudge(bundleDir: bundle).judge(command)
        case .ft:
            return try? slot.ftJudge(bundleDir: bundle).judge(command, context: context)
        }
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
        engine: JudgeEngine,
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
            "engine": engine.rawValue,
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
/// One cached judge per engine: the stock three-question judge and the
/// fine-tuned single-pass judge load different bundles and must not share
/// a slot.
final class JudgeSlot: @unchecked Sendable {
    private var stock: LayaCoreMLJudge?
    private var ft: FineTunedJudge?
    private var failedStock: URL?
    private var failedFT: URL?
    private let lock = NSLock()

    func stockJudge(bundleDir: URL) throws -> LayaCoreMLJudge {
        lock.lock()
        defer { lock.unlock() }
        if let stock { return stock }
        if failedStock == bundleDir { throw LayaError.modelUnavailable("cached load failure") }
        do {
            let judge = try LayaCoreMLJudge(bundleDir: bundleDir)
            stock = judge
            return judge
        } catch {
            failedStock = bundleDir
            throw error
        }
    }

    func ftJudge(bundleDir: URL) throws -> FineTunedJudge {
        lock.lock()
        defer { lock.unlock() }
        if let ft { return ft }
        if failedFT == bundleDir { throw LayaError.modelUnavailable("cached load failure") }
        do {
            let judge = try FineTunedJudge(bundleDir: bundleDir)
            ft = judge
            return judge
        } catch {
            failedFT = bundleDir
            throw error
        }
    }
}
#endif
