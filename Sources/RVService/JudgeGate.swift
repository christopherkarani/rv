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

    /// Live guard mode (doctor, and the file door once per evaluation). The
    /// shell doors read it once per evaluation through `EvaluationInputs`.
    public static func guardMode(home: HomeDirectory?) -> GuardMode {
        guardMode(environment: ProcessInfo.processInfo.environment, config: loadConfigDict(home: home))
    }

    /// `RV_GUARD_MODE` > `guard.mode` > enforce. An unknown value at either
    /// level falls through to the next.
    static func guardMode(environment: [String: String], config: [String: Any]?) -> GuardMode {
        if let raw = environment["RV_GUARD_MODE"],
           let mode = GuardMode(rawValue: raw.lowercased()) {
            return mode
        }
        if let raw = configGuardMode(config),
           let mode = GuardMode(rawValue: raw.lowercased()) {
            return mode
        }
        return .enforce
    }

    /// Reads `guard.mode` from a parsed config object, nested
    /// (`{"guard": {"mode": "observe"}}`) or flat dotted form.
    static func configGuardMode(_ config: [String: Any]?) -> String? {
        guard let config else { return nil }
        if let nested = config["guard"] as? [String: Any],
           let mode = nested["mode"] as? String, !mode.isEmpty {
            return mode
        }
        if let flat = config["guard.mode"] as? String, !flat.isEmpty {
            return flat
        }
        return nil
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
    static func explicitEngine(env: [String: String], config: [String: Any]?) -> JudgeEngine? {
        env["RV_JUDGE_ENGINE"].flatMap { JudgeEngine(rawValue: $0.lowercased()) }
            ?? configEngine(config).flatMap { JudgeEngine(rawValue: $0.lowercased()) }
    }

    static func resolveEngine(
        env: [String: String],
        config: [String: Any]?,
        bundleExists: (JudgeEngine) -> Bool
    ) -> (engine: JudgeEngine, bundlePresent: Bool) {
        let resolved = resolveEngine(env: env, config: config) { bundleExists($0) ? () : nil }
        return (resolved.engine, resolved.bundle != nil)
    }

    /// The one precedence ladder. `bundle` probes each engine at most once.
    static func resolveEngine<Bundle>(
        env: [String: String],
        config: [String: Any]?,
        bundle: (JudgeEngine) -> Bundle?
    ) -> (engine: JudgeEngine, bundle: Bundle?) {
        if let explicit = explicitEngine(env: env, config: config) {
            return (explicit, bundle(explicit))
        }
        if let ft = bundle(.ft) { return (.ft, ft) }
        return (.laya, bundle(.laya))
    }

    /// Engine and validated bundle from already-read env and config. Only
    /// the bundle directories are probed.
    static func selection(
        home: HomeDirectory?,
        environment: [String: String],
        config: [String: Any]?
    ) -> JudgeSelection {
        let resolved = resolveEngine(env: environment, config: config) { engine -> URL? in
            switch engine {
            case .ft: return ftBundleDir(home: home, environment: environment)
            case .laya: return bundleDir(home: home, environment: environment)
            }
        }
        return JudgeSelection(engine: resolved.engine, bundle: resolved.bundle)
    }

    /// The engine that will actually run, with its validated bundle dir.
    /// Nil when the selected engine's bundle is missing — the caller goes
    /// packs-only (never fail-closed; see `apply`).
    static func resolvedJudge(home: HomeDirectory?) -> (engine: JudgeEngine, bundle: URL)? {
        let selected = selection(
            home: home,
            environment: ProcessInfo.processInfo.environment,
            config: loadConfigDict(home: home)
        )
        guard let bundle = selected.bundle else { return nil }
        return (selected.engine, bundle)
    }

    /// Bundle state for doctor: distinguishes absent (packs-only is a
    /// choice) from present-but-invalid (a broken install that would
    /// silently run packs-only).
    public enum BundleHealth: Sendable {
        case ok(engine: JudgeEngine, bundle: URL)
        case invalid(engine: JudgeEngine, dir: URL, problems: [String])
        case missing(engine: JudgeEngine, expected: URL?)
    }

    public static func bundleHealth(home: HomeDirectory?) -> BundleHealth {
        if let resolved = resolvedJudge(home: home) {
            let problems = bundleProblems(engine: resolved.engine, dir: resolved.bundle)
            return problems.isEmpty
                ? .ok(engine: resolved.engine, bundle: resolved.bundle)
                : .invalid(engine: resolved.engine, dir: resolved.bundle, problems: problems)
        }
        // No runnable bundle. If an install dir exists at all, it is a
        // broken install, not an absence. Check the explicit engine,
        // else FT (production default) before stock — the resolver
        // falls back to stock precisely because FT did not validate.
        let explicitChoice = explicitEngine(
            env: ProcessInfo.processInfo.environment, config: loadConfigDict(home: home)
        )
        for engine in explicitChoice.map { [$0] } ?? [JudgeEngine.ft, .laya] {
            if let expected = expectedBundleDir(engine: engine, home: home),
               FileManager.default.fileExists(atPath: expected.path) {
                return .invalid(
                    engine: engine, dir: expected,
                    problems: bundleProblems(engine: engine, dir: expected)
                )
            }
        }
        // Nothing installed: point at the production (FT) bundle unless
        // another engine was explicitly selected.
        let explicit = explicitEngine(
            env: ProcessInfo.processInfo.environment, config: loadConfigDict(home: home)
        )
        let installEngine = explicit ?? .ft
        return .missing(
            engine: installEngine,
            expected: expectedBundleDir(engine: installEngine, home: home)
        )
    }

    static func bundleProblems(engine: JudgeEngine, dir: URL) -> [String] {
        let fm = FileManager.default
        var problems: [String] = []
        if !fm.fileExists(atPath: dir.appendingPathComponent("model.mlpackage").path) {
            problems.append("model.mlpackage missing")
        }
        switch engine {
        case .ft:
            let tok = fm.fileExists(atPath: dir.appendingPathComponent("tokenizer.json").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("tokenizer/tokenizer.json").path)
            if !tok { problems.append("tokenizer.json missing") }
            let configURL = dir.appendingPathComponent("config.json")
            if fm.fileExists(atPath: configURL.path) {
                if let data = try? Data(contentsOf: configURL),
                   let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let labels = (cfg["logit_order"] as? [String]) ?? (cfg["labels"] as? [String])
                    if let labels, Set(labels) != ["allow", "review", "block"] {
                        problems.append("config labels are not allow/review/block")
                    }
                } else {
                    problems.append("config.json unparseable")
                }
            }
        case .laya:
            if !fm.fileExists(atPath: dir.appendingPathComponent("tokenizer/tokenizer.json").path) {
                problems.append("tokenizer/tokenizer.json missing")
            }
        }
        return problems
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
    static func ftBundleDir(home: HomeDirectory?, environment: [String: String]) -> URL? {
        func valid(_ dir: URL) -> URL? {
            let fm = FileManager.default
            let hasModel = fm.fileExists(atPath: dir.appendingPathComponent("model.mlpackage").path)
            let hasTokenizer = fm.fileExists(atPath: dir.appendingPathComponent("tokenizer.json").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("tokenizer/tokenizer.json").path)
            return hasModel && hasTokenizer ? dir : nil
        }
        if let raw = environment["RV_FT_BUNDLE"], !raw.isEmpty {
            return valid(URL(fileURLWithPath: raw))
        }
        guard let expected = expectedBundleDir(engine: .ft, home: home) else { return nil }
        return valid(expected)
    }

    /// A directory only counts as a bundle when a model artifact is in it;
    /// anything else (unset, empty, wrong path) means packs-only.
    static func bundleDir(home: HomeDirectory?, environment: [String: String]) -> URL? {
        func valid(_ dir: URL) -> URL? {
            // Only the CoreML judge is wired; an ONNX-only directory is
            // not a runnable bundle and must not read as judge-on.
            let fm = FileManager.default
            let hasModel = fm.fileExists(atPath: dir.appendingPathComponent("model.mlpackage").path)
            let hasTokenizer = fm.fileExists(atPath: dir.appendingPathComponent("tokenizer/tokenizer.json").path)
            return hasModel && hasTokenizer ? dir : nil
        }
        if let raw = environment["RV_LAYA_BUNDLE"], !raw.isEmpty {
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
    ///
    /// `allowSafeLane` is false when the package-script graph could not
    /// be resolved: such a command must reach the judge (or a human),
    /// never the judge-skipping lane. `isPeek` only tags the log row.
    /// The log row is returned, not written; nil when the judge is not
    /// consulted (a pack deny).
    static func apply(
        to result: EvaluationResult,
        command: ShellCommand,
        inputs: EvaluationInputs,
        judge: any JudgePort,
        provenance: ActionProvenance,
        now: Date,
        cwd: WorkingDirectory?,
        allowSafeLane: Bool,
        isPeek: Bool
    ) -> (result: EvaluationResult, log: GatedEffect.JudgeLogRow?) {
        guard case .allow = result.decision else { return (result, nil) }
        let context = judgeContext(cwd: cwd)
        let partial = contextIsPartial(context)
        let selection = inputs.judge
        if allowSafeLane, SafeCommandLane.isSafe(command.rawValue) {
            return (result, logRow(
                guardMode: inputs.guardMode, subject: .live(result),
                verdict: nil, action: nil, engine: selection.engine,
                note: noteFor("safe-lane", contextPartial: partial), now: now, isPeek: isPeek
            ))
        }
        // Bundle-missing for the SELECTED engine is packs-only with an
        // engine-missing note — NOT fail-closed. Fail-closed Ask applies
        // only when a loaded judge errors mid-prediction (`.failed`).
        // A bundle that cannot LOAD is unavailable: packs-only plus a
        // note (doctor surfaces it), never an eternal Ask loop.
        guard let bundle = selection.bundle else {
            return (result, logRow(
                guardMode: inputs.guardMode, subject: .live(result),
                verdict: nil, action: nil, engine: selection.engine,
                note: noteFor("engine-missing", contextPartial: partial), now: now, isPeek: isPeek
            ))
        }
        let reading = read(
            judge.judge(JudgeCall(
                command: command.rawValue, context: context,
                engine: selection.engine, bundle: bundle
            )),
            over: result,
            provenance: provenance
        )
        return (reading.outcome, logRow(
            guardMode: inputs.guardMode, subject: .live(reading.outcome),
            verdict: reading.verdict, action: reading.action, engine: selection.engine,
            note: noteFor(reading.note, contextPartial: partial), now: now, isPeek: isPeek
        ))
    }

    /// Observe path: the would-be verdict as a log row, always allow.
    static func observe(
        wouldBe result: EvaluationResult,
        command: ShellCommand,
        inputs: EvaluationInputs,
        judge: any JudgePort,
        provenance: ActionProvenance,
        now: Date,
        cwd: WorkingDirectory?,
        allowSafeLane: Bool,
        isPeek: Bool
    ) -> (result: EvaluationResult, log: GatedEffect.JudgeLogRow) {
        let context = judgeContext(cwd: cwd)
        let partial = contextIsPartial(context)
        let selection = inputs.judge
        let safe = allowSafeLane && SafeCommandLane.isSafe(command.rawValue)
        var reading = JudgeReading(
            outcome: result, verdict: nil, action: nil, note: safe ? "safe-lane" : nil
        )
        if !safe, let bundle = selection.bundle, case .allow = result.decision {
            reading = read(
                judge.judge(JudgeCall(
                    command: command.rawValue, context: context,
                    engine: selection.engine, bundle: bundle
                )),
                over: result,
                provenance: provenance
            )
        }
        return (result.observedAllow, logRow(
            guardMode: inputs.guardMode, subject: .wouldBe(reading.outcome),
            verdict: reading.verdict, action: reading.action, engine: selection.engine,
            note: noteFor(reading.note, contextPartial: partial), now: now, isPeek: isPeek
        ))
    }

    /// What one judge run means for a pack-allow: the threshold-resolved
    /// action, the raised result, and the log note.
    struct JudgeReading {
        let outcome: EvaluationResult
        let verdict: LayaVerdict?
        let action: LayaVerdict.Action?
        let note: String?
    }

    /// Verdict → provenance thresholds → truncation guard → raise. Shared by
    /// `apply` and `observe`; neither re-derives it.
    static func read(
        _ run: JudgeRun,
        over result: EvaluationResult,
        provenance: ActionProvenance
    ) -> JudgeReading {
        switch run {
        case .unavailable(let note):
            return JudgeReading(
                outcome: result, verdict: nil, action: nil, note: "judge-unavailable: \(note)"
            )
        case .failed:
            return JudgeReading(
                outcome: raise(result, verdict: nil, action: .review),
                verdict: nil, action: .review, note: "prediction-failed"
            )
        case .verdict(let verdict):
            let t = thresholds(provenance: provenance)
            var action = verdict.action(blockThreshold: t.block, reviewThreshold: t.review)
            // The model never saw the truncated tail; an allow on a
            // partial view goes to a human instead of binding.
            if verdict.truncated, action == .allow { action = .review }
            return JudgeReading(
                outcome: action == .allow ? result : raise(result, verdict: verdict, action: action),
                verdict: verdict, action: action, note: verdict.truncated ? "truncated" : nil
            )
        }
    }

    /// Load failure is distinct from prediction failure: the first is a
    /// broken install (packs-only, doctor-visible), the second is a
    /// loaded judge that cannot answer this input (fail-closed Ask).
    enum JudgeRun: Sendable {
        case verdict(LayaVerdict)
        case unavailable(String)
        case failed
    }

    static func runJudge(
        command: String,
        context: JudgeContext,
        engine: JudgeEngine,
        bundle: URL
    ) -> JudgeRun {
        #if canImport(CoreML)
        do {
            switch engine {
            case .laya:
                let judge = try slot.stockJudge(bundleDir: bundle)
                do { return .verdict(try judge.judge(command)) }
                catch { return .failed }
            case .ft:
                let judge = try slot.ftJudge(bundleDir: bundle)
                do { return .verdict(try judge.judge(command, context: context)) }
                catch { return .failed }
            }
        } catch let error as LayaError {
            switch error {
            case .badBundle(let why), .modelUnavailable(let why): return .unavailable(why)
            case .predictionFailed: return .failed
            }
        } catch {
            return .unavailable("load failed")
        }
        #else
        return .unavailable("CoreML unavailable on this platform")
        #endif
    }

    /// Judge block pins (boundReview .deny); review/abstain unlockable
    /// (Ask). `action` is the caller's threshold-resolved action — never
    /// re-derived here at default thresholds.
    static func raise(
        _ result: EvaluationResult, verdict: LayaVerdict?, action: LayaVerdict.Action
    ) -> EvaluationResult {
        let isBlock = action == .block
        let reason = verdict.map {
            "Laya judge: \($0.choice) (risk \(String(format: "%.2f", $0.risk)))"
        } ?? "Laya judge unavailable; failing closed"
        let deny = Deny(
            ruleID: RuleID(pack: .coreJudge, pattern: isBlock ? "laya-block" : "laya-review"),
            reason: reason
        )
        return EvaluationResult(
            outcome: .deny(deny, matched: nil),
            matchingView: result.matchingView,
            analysis: result.analysis,
            boundReview: isBlock ? .deny(deny) : nil
        )
    }

    /// Which result a judge-log row describes: the enforced verdict, or the
    /// observe-mode would-be verdict.
    enum LogSubject {
        case live(EvaluationResult)
        case wouldBe(EvaluationResult)
    }

    /// Hash-only row (never command text), laya-guard parity. The subject
    /// is the post-judge result and `action` is the threshold-resolved
    /// action, so would-block rates read correctly.
    static func logRow(
        guardMode: GuardMode,
        subject: LogSubject,
        verdict: LayaVerdict?,
        action: LayaVerdict.Action?,
        engine: JudgeEngine,
        note: String?,
        now: Date,
        isPeek: Bool
    ) -> GatedEffect.JudgeLogRow {
        func kind(_ decision: Decision) -> GatedEffect.JudgeLogRow.Verdict {
            switch decision {
            case .allow: .allow
            case .deny: .deny
            case .indeterminate: .indeterminate
            }
        }
        let described: EvaluationResult
        let rowSubject: GatedEffect.JudgeLogRow.Subject
        switch subject {
        case .live(let live):
            described = live
            rowSubject = .live(kind(live.decision))
        case .wouldBe(let wouldBe):
            described = wouldBe
            let rule: String?
            if case .deny(let deny) = wouldBe.decision { rule = deny.ruleID.rawValue } else { rule = nil }
            rowSubject = .wouldBe(kind(wouldBe.decision), rule: rule)
        }
        return GatedEffect.JudgeLogRow(
            at: now,
            guardMode: guardMode,
            engine: engine,
            hash: String(RVDigest.sha256Hex([UInt8](described.matchingView.rawValue.utf8)).prefix(16)),
            subject: rowSubject,
            note: note,
            isPeek: isPeek,
            score: verdict.map { verdict in
                GatedEffect.JudgeLogRow.Score(
                    choice: verdict.choice,
                    action: (action ?? verdict.action()).rawValue,
                    risk: (verdict.risk * 1000).rounded() / 1000,
                    malicious: (verdict.malicious * 10000).rounded() / 10000,
                    checkpoint: verdict.checkpoint,
                    milliseconds: (verdict.latencyMilliseconds * 10).rounded() / 10,
                    truncated: verdict.truncated
                )
            }
        )
    }

    private static let logLock = UnfairLock<Bool>(true)

    /// Appends one row to `<config>/judge-log.jsonl`. Best effort.
    static func appendLog(_ row: GatedEffect.JudgeLogRow, home: HomeDirectory) {
        let dir = RVPolicyPaths.configDirectory(home: home)
        let file = dir.appendingPathComponent("judge-log.jsonl")
        var object: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: row.at),
            "guard": row.guardMode.rawValue,
            "engine": row.engine.rawValue,
            "hash": row.hash,
        ]
        switch row.subject {
        case .wouldBe(let verdict, let rule):
            object["wouldBe"] = verdict.rawValue
            if let rule { object["wouldBeRule"] = rule }
            object["live"] = "allow"
        case .live(let verdict):
            object["live"] = verdict.rawValue
        }
        if let note = row.note { object["note"] = note }
        if row.isPeek { object["peek"] = true }
        if let score = row.score {
            object["choice"] = score.choice
            object["action"] = score.action
            object["risk"] = score.risk
            object["malicious"] = score.malicious
            object["checkpoint"] = score.checkpoint
            object["ms"] = score.milliseconds
            if score.truncated { object["truncated"] = true }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A)
        // Serialized in-process; seek-to-end + single write keeps rows
        // whole against other daemon writers on the same file.
        logLock.withLock { _ in
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
}

/// One judge call: the command, its runtime context, and the engine and
/// bundle selected for this evaluation.
struct JudgeCall: Sendable {
    let command: String
    let context: JudgeContext
    let engine: JudgeEngine
    let bundle: URL
}

/// The one judge call the gated door makes. Production runs the CoreML
/// judge; tests substitute a fixed reading to drive thresholds and
/// observe/enforce without a model.
protocol JudgePort: Sendable {
    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun
}

/// Slot-cached CoreML judge (packs-only on platforms without CoreML).
struct LiveJudgePort: JudgePort {
    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        JudgeRuntime.runJudge(
            command: call.command, context: call.context,
            engine: call.engine, bundle: call.bundle
        )
    }
}

extension EvaluationResult {
    /// Observe posture: the door allows, keeping the view and analysis.
    /// Whole-guard: the same projection on every door.
    var observedAllow: EvaluationResult {
        EvaluationResult(outcome: .plain, matchingView: matchingView, analysis: analysis)
    }
}

#if canImport(CoreML)
/// One cached judge per engine: the stock three-question judge and the
/// fine-tuned single-pass judge load different bundles and must not share
/// a slot. Cache entries are keyed by bundle dir, so an upgraded bundle
/// is picked up; a load failure is cached only against the bundle's
/// model modification time, so repairing the bundle retries the load.
/// Compilation runs outside the lock (a racing duplicate load is wasted
/// work, not a stalled evaluate door).
final class JudgeSlot: @unchecked Sendable {
    private var stock: (dir: URL, judge: LayaCoreMLJudge)?
    private var ft: (dir: URL, judge: FineTunedJudge)?
    private var failedStock: (dir: URL, stamp: TimeInterval)?
    private var failedFT: (dir: URL, stamp: TimeInterval)?
    private let lock = NSLock()

    private static func stamp(_ bundleDir: URL) -> TimeInterval {
        let package = bundleDir.appendingPathComponent("model.mlpackage")
        let date = (try? FileManager.default.attributesOfItem(atPath: package.path))?[.modificationDate] as? Date
        return date?.timeIntervalSince1970 ?? 0
    }

    func stockJudge(bundleDir: URL) throws -> LayaCoreMLJudge {
        let stamp = Self.stamp(bundleDir)
        lock.lock()
        if let stock, stock.dir == bundleDir { lock.unlock(); return stock.judge }
        if let failedStock, failedStock.dir == bundleDir, failedStock.stamp == stamp {
            lock.unlock()
            throw LayaError.modelUnavailable("cached load failure")
        }
        lock.unlock()
        do {
            let judge = try LayaCoreMLJudge(bundleDir: bundleDir)
            lock.lock()
            if let stock, stock.dir == bundleDir { lock.unlock(); return stock.judge }
            stock = (bundleDir, judge)
            failedStock = nil
            lock.unlock()
            return judge
        } catch {
            lock.lock()
            failedStock = (bundleDir, stamp)
            lock.unlock()
            throw error
        }
    }

    func ftJudge(bundleDir: URL) throws -> FineTunedJudge {
        let stamp = Self.stamp(bundleDir)
        lock.lock()
        if let ft, ft.dir == bundleDir { lock.unlock(); return ft.judge }
        if let failedFT, failedFT.dir == bundleDir, failedFT.stamp == stamp {
            lock.unlock()
            throw LayaError.modelUnavailable("cached load failure")
        }
        lock.unlock()
        do {
            let judge = try FineTunedJudge(bundleDir: bundleDir)
            lock.lock()
            if let ft, ft.dir == bundleDir { lock.unlock(); return ft.judge }
            ft = (bundleDir, judge)
            failedFT = nil
            lock.unlock()
            return judge
        } catch {
            lock.lock()
            failedFT = (bundleDir, stamp)
            lock.unlock()
            throw error
        }
    }
}
#else
/// Linux seam: no CoreML judge exists, every load is unavailable and
/// the gate runs packs-only. Referenced unconditionally above.
final class JudgeSlot: @unchecked Sendable {}
#endif
