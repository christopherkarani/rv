import Foundation
import RVDomain
import RVEngine
import RVFileStore
import RVHistory
import RVLaya
import RVPolicy

/// Laya judge wiring for the gated evaluate door.
///
/// One config knob (~/.config/rv/config.json): `guard.mode`: `enforce`
/// (default) | `observe`. `RV_GUARD_MODE=enforce` may pin enforce; the
/// environment never loosens to observe.
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
    static let slot = JudgeSlot()

    static let ftBundleName = "laya-ft-v2-coreml"
    static let stockBundleName = "laya-multilingual-coreml"

    public static func thresholds(provenance: ActionProvenance) -> (block: Double, review: Double) {
        provenance.isUntrusted ? (0.6, 0.30) : (0.8, 0.45)
    }

    /// The mode one evaluation from `host` runs under: per-host resolution,
    /// then the organization pin (`ManagedGate.guardMode`). The file door
    /// reads it once per evaluation; the shell doors read it through
    /// `EvaluationInputs`.
    static func effectiveGuardMode(
        home: HomeDirectory?,
        host: LedgerHost,
        environment: [String: String],
        config: GuardConfig
    ) -> GuardMode {
        let hookHost: HookHost?
        switch host {
        case .tty: hookHost = nil
        case .hook(let hook): hookHost = hook
        }
        return ManagedGate.guardMode(
            GuardModeResolution.resolve(config, host: hookHost, environment: environment), home: home)
    }

    /// Testable engine resolution. `config` is injected (only
    /// `judge.engine` is read); `bundleExists` probes whether an engine's
    /// bundle validates on disk, so tests need no HOME.
    ///
    /// Precedence: `judge.engine` > FT-if-installed > stock. An explicit
    /// engine whose bundle is missing still wins (`bundlePresent` false):
    /// the gate goes packs-only with an `engine-missing` note rather than
    /// failing closed or silently switching engines.
    ///
    /// The launch environment is never read here (`RV_JUDGE_ENGINE`,
    /// `RV_FT_BUNDLE`, `RV_LAYA_BUNDLE`): rvd inherits it from
    /// launchd/systemd, which a same-user agent can edit, and picking a
    /// missing or foreign bundle disables or replaces the judge. Engine and
    /// bundle belong to the owner's config and install, like `guard.mode`.
    static func resolveEngine(
        config: GuardConfig,
        bundleExists: (JudgeEngine) -> Bool
    ) -> (engine: JudgeEngine, bundlePresent: Bool) {
        let resolved = resolveEngine(config: config) { bundleExists($0) ? () : nil }
        return (resolved.engine, resolved.bundle != nil)
    }

    /// The one precedence ladder. `bundle` probes each engine at most once.
    static func resolveEngine<Bundle>(
        config: GuardConfig,
        bundle: (JudgeEngine) -> Bundle?
    ) -> (engine: JudgeEngine, bundle: Bundle?) {
        if let explicit = config.judgeEngine {
            return (explicit, bundle(explicit))
        }
        if let ft = bundle(.ft) { return (.ft, ft) }
        return (.laya, bundle(.laya))
    }

    /// Engine and validated bundle from already-read config. Only the
    /// bundle directories are probed.
    static func selection(
        home: HomeDirectory?,
        config: GuardConfig
    ) -> JudgeSelection {
        let resolved = resolveEngine(config: config) { engine -> URL? in
            switch engine {
            case .ft: return ftBundleDir(home: home)
            case .laya: return bundleDir(home: home)
            }
        }
        return JudgeSelection(engine: resolved.engine, bundle: resolved.bundle)
    }

    /// The engine that will actually run, with its validated bundle dir.
    /// Nil when the selected engine's bundle is missing — the caller goes
    /// packs-only (never fail-closed; see `apply`).
    static func resolvedJudge(home: HomeDirectory?, config: GuardConfig) -> (engine: JudgeEngine, bundle: URL)? {
        let selected = selection(home: home, config: config)
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
        let config = GuardConfig.read(home: home)
        if let resolved = resolvedJudge(home: home, config: config) {
            let problems = bundleProblems(engine: resolved.engine, dir: resolved.bundle)
            return problems.isEmpty
                ? .ok(engine: resolved.engine, bundle: resolved.bundle)
                : .invalid(engine: resolved.engine, dir: resolved.bundle, problems: problems)
        }
        // No runnable bundle. If an install dir exists at all, it is a
        // broken install, not an absence. Check the explicit engine,
        // else FT (production default) before stock — the resolver
        // falls back to stock precisely because FT did not validate.
        for engine in config.judgeEngine.map { [$0] } ?? [JudgeEngine.ft, .laya] {
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
        let installEngine = config.judgeEngine ?? .ft
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
                    do { _ = try LayaVerdict.Action.configLabels(cfg) }
                    catch { problems.append("config labels are not allow/review/block") }
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

    /// Fine-tuned bundle: the installed `models/laya-ft-v2-coreml`. A
    /// directory only counts when `model.mlpackage` is in it.
    static func ftBundleDir(home: HomeDirectory?) -> URL? {
        func valid(_ dir: URL) -> URL? {
            let fm = FileManager.default
            let hasModel = fm.fileExists(atPath: dir.appendingPathComponent("model.mlpackage").path)
            let hasTokenizer = fm.fileExists(atPath: dir.appendingPathComponent("tokenizer.json").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("tokenizer/tokenizer.json").path)
            return hasModel && hasTokenizer ? dir : nil
        }
        guard let expected = expectedBundleDir(engine: .ft, home: home) else { return nil }
        return valid(expected)
    }

    /// A directory only counts as a bundle when a model artifact is in it;
    /// anything else (unset, empty, wrong path) means packs-only.
    static func bundleDir(home: HomeDirectory?) -> URL? {
        func valid(_ dir: URL) -> URL? {
            // Only the CoreML judge is wired; an ONNX-only directory is
            // not a runnable bundle and must not read as judge-on.
            let fm = FileManager.default
            let hasModel = fm.fileExists(atPath: dir.appendingPathComponent("model.mlpackage").path)
            let hasTokenizer = fm.fileExists(atPath: dir.appendingPathComponent("tokenizer/tokenizer.json").path)
            return hasModel && hasTokenizer ? dir : nil
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

    /// String seam over `judgeContext` for RVServiceTests.
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
    /// `allowSafeLane` is false when a package script the command runs is
    /// not itself safe-lane: the command then reaches the judge (or the
    /// packs-only floor). An unresolved script graph never gets here: the
    /// door floors it to indeterminate first. `isPeek` only tags the log row.
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
        isPeek: Bool,
        lateLog: (@Sendable (GatedEffect.JudgeLogRow) -> Void)? = nil
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
        // A bundle that is invalid or has no model is unavailable:
        // packs-only plus a note (doctor surfaces it), never an eternal Ask
        // loop. Core ML failing on a model that is there refuses
        // (`CoreMLLoadRefusal`, review): an agent can provoke that.
        guard let bundle = selection.bundle else {
            return (packsOnlyFloor(result, command: command), logRow(
                guardMode: inputs.guardMode, subject: .live(result),
                verdict: nil, action: nil, engine: selection.engine,
                note: noteFor("engine-missing", contextPartial: partial), now: now, isPeek: isPeek
            ))
        }
        let run = judge.judge(JudgeCall(
            command: command.rawValue, context: context,
            engine: selection.engine, bundle: bundle,
            onLateResult: lateLog.map { log in
                lateResultLogger(
                    over: result, observing: false, provenance: provenance, guardMode: inputs.guardMode,
                    engine: selection.engine, contextPartial: partial, isPeek: isPeek, log: log)
            }
        ))
        let reading = read(run, over: result, provenance: provenance)
        let row = logRow(
            guardMode: inputs.guardMode, subject: .live(reading.outcome),
            verdict: reading.verdict, action: reading.action, engine: selection.engine,
            note: noteFor(reading.note, contextPartial: partial), now: now, isPeek: isPeek
        )
        // Only enforce floors an unscored allow; the log keeps the pack
        // result, as for engine-missing above.
        if case .unavailable = run {
            return (packsOnlyFloor(reading.outcome, command: command), row)
        }
        return (reading.outcome, row)
    }

    /// Observe path: the would-be verdict as a log row, always allow.
    /// `wouldBe` is what enforcement would have returned before the Policy
    /// gate (the door records an observed denial row from it).
    static func observe(
        wouldBe result: EvaluationResult,
        command: ShellCommand,
        inputs: EvaluationInputs,
        judge: any JudgePort,
        provenance: ActionProvenance,
        now: Date,
        cwd: WorkingDirectory?,
        allowSafeLane: Bool,
        isPeek: Bool,
        lateLog: (@Sendable (GatedEffect.JudgeLogRow) -> Void)? = nil
    ) -> (result: EvaluationResult, wouldBe: EvaluationResult, floorsWouldBe: Bool, log: GatedEffect.JudgeLogRow) {
        let context = judgeContext(cwd: cwd)
        let partial = contextIsPartial(context)
        let selection = inputs.judge
        let safe = allowSafeLane && SafeCommandLane.isSafe(command.rawValue)
        var reading = JudgeReading(
            outcome: result, verdict: nil, action: nil, note: safe ? "safe-lane" : nil
        )
        // `floorsWouldBe` marks where `apply` would take the packs-only
        // floor (no bundle, or a judge that is unavailable). The callers
        // that consume the would-be (`peekVerdict` for `rv test` /
        // `rv explain`, `applyVerdict` for the SDK evaluate RPC) apply it;
        // a plain `apply` or peek discards the would-be, so it skips the
        // parse. The log row keeps the unfloored reading, as `apply`'s does.
        var floorsWouldBe = false
        if !safe, case .allow = result.decision {
            if let bundle = selection.bundle {
                let run = judge.judge(JudgeCall(
                    command: command.rawValue, context: context,
                    engine: selection.engine, bundle: bundle,
                    onLateResult: lateLog.map { log in
                        lateResultLogger(
                            over: result, observing: true, provenance: provenance, guardMode: inputs.guardMode,
                            engine: selection.engine, contextPartial: partial, isPeek: isPeek, log: log)
                    }
                ))
                reading = read(run, over: result, provenance: provenance)
                if case .unavailable = run { floorsWouldBe = true }
            } else {
                floorsWouldBe = true
            }
        }
        return (result.observedAllow, reading.outcome, floorsWouldBe, logRow(
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
        case .failed, .warming, .busy, .late, .circuitOpen, .refused:
            let (raised, note) = failClosed(run, over: result)
            return JudgeReading(outcome: raised, verdict: nil, action: .review, note: note)
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

    /// Logs a prediction that answered after its caller gave up (`late`),
    /// note `late-result`, so a judge outage shows its real latency in the
    /// judge log. The row describes what the caller got (`late` failed
    /// closed over `result`) and scores the late verdict with its own ms;
    /// a late run without a verdict names its outcome and run time in the
    /// note. Nothing here changes a verdict.
    static func lateResultLogger(
        over result: EvaluationResult,
        observing: Bool,
        provenance: ActionProvenance,
        guardMode: GuardMode,
        engine: JudgeEngine,
        contextPartial: Bool,
        isPeek: Bool,
        log: @escaping @Sendable (GatedEffect.JudgeLogRow) -> Void
    ) -> @Sendable (JudgeRun, Duration) -> Void {
        { run, ran in
            let returned = failClosed(.late, over: result).result
            let reading = read(run, over: result, provenance: provenance)
            let note: String
            if reading.verdict != nil {
                note = "late-result"
            } else {
                let ms = Int64((Double(ran.components.seconds) + Double(ran.components.attoseconds) / 1e18) * 1000)
                note = "late-result: \(reading.note ?? "no verdict") after \(ms) ms"
            }
            var row = logRow(
                guardMode: guardMode, subject: observing ? .wouldBe(returned) : .live(returned),
                verdict: reading.verdict, action: reading.action, engine: engine,
                note: noteFor(note, contextPartial: contextPartial), now: Date(), isPeek: isPeek
            )
            row.isLateResult = true
            log(row)
        }
    }

    /// Packs-only (no judge could score): an inline interpreter program the
    /// packs masked as data, carrying spawn/eval/delete/secret markers, is
    /// indeterminate rather than an unreviewed allow. (An unresolved
    /// package-script graph is floored earlier, by the door, judge or not.)
    static func packsOnlyFloor(_ result: EvaluationResult, command: ShellCommand) -> EvaluationResult {
        guard case .allow = result.decision else { return result }
        guard InlineProgramGuard.requiresJudge(command) else { return result }
        return EvaluationResult(
            outcome: .indeterminate(.inlineProgramNeedsJudge),
            matchingView: result.matchingView,
            analysis: result.analysis
        )
    }

    /// Load failure is distinct from prediction failure: the first is a
    /// broken install (packs-only, doctor-visible), the second is a
    /// loaded judge that cannot answer this input (fail-closed Ask).
    ///
    /// `warming` is a load still in progress past the bounded wait. It goes
    /// to a human (review), never packs-only: a same-user agent could
    /// otherwise kill rvd to buy an unjudged window.
    ///
    /// `busy` is a request `JudgeAdmission` turned away (queue full, or its
    /// hook deadline passed while waiting for the model). Review for the
    /// same reason: flooding the judge must not buy an unjudged allow.
    ///
    /// `late` is a prediction that did not answer before its caller's
    /// cutoff, or a request turned away behind a stalled one. `circuitOpen`
    /// is the judge skipped by `JudgeCircuit` after repeated failures. Both
    /// go to review like `busy`: a failing judge must never buy an allow.
    ///
    /// `refused` is a judge that would not touch Core ML (cache volume nearly
    /// full, or a compiled model it could not verify). Review, never
    /// packs-only: filling the disk must not buy one.
    enum JudgeRun: Sendable {
        case verdict(LayaVerdict)
        case unavailable(String)
        case failed
        case warming
        case busy
        case late
        case circuitOpen(retryIn: Duration)
        case refused(String)
    }

    static func runJudge(
        command: String,
        context: JudgeContext,
        engine: JudgeEngine,
        bundle: URL,
        wait: Duration? = loadWait,
        slot: JudgeSlot = slot,
        onLate: @escaping @Sendable (JudgeRun, Duration) -> Void = { _, _ in }
    ) -> JudgeRun {
        #if canImport(CoreML)
        return throughCircuit {
            // A cold load keeps its own bound (`loadWait`), cut to the hook
            // deadline less headroom; only the wait for the model slot after
            // it is held to `JudgeAdmission.waitBudget`.
            let deadline = JudgeAdmission.deadline
            let wait = JudgeAdmission.loadWait(
                wait, until: deadline.map { $0 - JudgeAdmission.inferenceHeadroom })
            do {
                switch engine {
                case .laya:
                    let judge = try HookTiming.measure(.judgeLoad) { try slot.stockJudge(bundleDir: bundle, wait: wait) }
                    return admitted(until: deadline, onLate: onLate) {
                        do { return .verdict(try judge.judge(command)) }
                        catch let refusal as any CoreMLRefusal { return .refused(refusal.reason) }
                        catch { return .failed }
                    }
                case .ft:
                    let judge = try HookTiming.measure(.judgeLoad) { try slot.ftJudge(bundleDir: bundle, wait: wait) }
                    return admitted(until: deadline, onLate: onLate) {
                        do { return .verdict(try judge.judge(command, context: context)) }
                        catch let refusal as any CoreMLRefusal { return .refused(refusal.reason) }
                        catch { return .failed }
                    }
                }
            } catch JudgeLoadError.warming {
                return .warming
            } catch let refusal as any CoreMLRefusal {
                return .refused(refusal.reason)
            } catch let error as LayaError {
                switch error {
                case .badBundle(let why), .modelUnavailable(let why): return .unavailable(why)
                case .predictionFailed: return .failed
                }
            } catch {
                return .unavailable("load failed")
            }
        }
        #else
        return .unavailable("CoreML unavailable on this platform")
        #endif
    }

    /// Inference through the live admission, bounded by this request's hook
    /// deadline. The model load is not admitted: it is single-flight and
    /// has its own bounded wait (`loadWait`). A turn-away behind a stalled
    /// prediction is `late`, not `busy`: the judge is failing, not full.
    static func admitted(
        through admission: JudgeAdmission = .live,
        until deadline: ContinuousClock.Instant? = JudgeAdmission.deadline,
        since: ContinuousClock.Instant = .now,
        onLate: @escaping @Sendable (JudgeRun, Duration) -> Void = { _, _ in },
        _ inference: @escaping @Sendable () -> JudgeRun
    ) -> JudgeRun {
        // Admission wait and inference are timed apart for `HookTiming`.
        // Inference runs on the admission's own thread, where the
        // task-local timing is not bound: capture it here.
        let timing = HookTiming.current
        let entered = ContinuousClock.now
        let outcome = admission.run(until: deadline, since: since, onLate: onLate) {
            let predicting = ContinuousClock.now
            timing?.add(.judgeAdmission, predicting - entered)
            defer { timing?.add(.judgePredict, ContinuousClock.now - predicting) }
            return inference()
        }
        switch outcome {
        case .answered(let run): return run
        case .turnedAway(let stalled):
            timing?.add(.judgeAdmission, ContinuousClock.now - entered)
            return stalled ? .late : .busy
        case .late: return .late
        }
    }

    /// Runs `attempt` unless the circuit is open, and feeds its outcome
    /// back. An open circuit answers `circuitOpen` without touching the
    /// model, its load or its admission.
    static func throughCircuit(
        _ circuit: JudgeCircuit = .live, _ attempt: () -> JudgeRun
    ) -> JudgeRun {
        switch circuit.admit() {
        case .skip(let retryIn):
            return .circuitOpen(retryIn: retryIn)
        case .proceed(let trial):
            let run = attempt()
            circuit.record(circuitOutcome(run), trial: trial)
            return run
        }
    }

    /// Which judge runs count against it (see `JudgeCircuitBreaker`).
    static func circuitOutcome(_ run: JudgeRun) -> JudgeCircuitBreaker.Outcome {
        switch run {
        case .verdict: .success
        case .late, .failed: .failure
        case .warming, .busy, .unavailable, .circuitOpen, .refused: .neutral
        }
    }

    /// Whole seconds until the circuit retries, rounded up, at least 1.
    static func retrySeconds(_ retryIn: Duration) -> Int64 {
        let (seconds, attoseconds) = retryIn.components
        return max(1, seconds + (attoseconds > 0 ? 1 : 0))
    }

    /// A judge that cannot answer this request (prediction failed, still
    /// warming past the bounded wait, or busy) fails closed to human review.
    static func failClosed(
        _ run: JudgeRun, over result: EvaluationResult
    ) -> (result: EvaluationResult, note: String) {
        let note: String
        let reason: String
        switch run {
        case .warming:
            note = "judge-warming"
            reason = "Laya judge is still loading on this device; retry in a few seconds."
        case .busy:
            note = "judge-busy"
            reason = "Laya judge queue is full; retry shortly."
        case .refused(let why):
            note = "judge-refused"
            reason = why
        case .late:
            note = "judge-late"
            reason = "rv degraded: judge late (no verdict in time); failing closed to review."
        case .circuitOpen(let retryIn):
            note = "judge-circuit-open"
            reason = "rv degraded: judge unavailable (circuit open, retrying in \(retrySeconds(retryIn))s); failing closed to review."
        case .failed, .unavailable, .verdict:
            note = "prediction-failed"
            reason = unavailableReason
        }
        return (raise(result, verdict: nil, action: .review, unavailable: reason), note)
    }

    /// User-visible reason when the judge could not score this request.
    static let unavailableReason = "Laya judge unavailable; failing closed. Run `rv doctor`."

    /// RVServiceTests seam: the warming outcome over `result`.
    static func warmingOutcomeSeam(over result: EvaluationResult) -> (EvaluationResult, String) {
        let raised = failClosed(.warming, over: result)
        return (raised.result, raised.note)
    }

    /// The daemon's bound on waiting for an in-progress judge load, cut to
    /// the hook deadline less `JudgeAdmission.inferenceHeadroom` when one is
    /// bound. Past it the request goes to review (`judge-warming`); the load
    /// keeps going. Not part of `JudgeAdmission.waitBudget`, which bounds
    /// only the wait for the model slot after the load.
    public static let daemonLoadWait: Duration = .seconds(5)

    private static let loadWaitBox = UnfairLock<Duration?>(nil)

    /// Current wait for an in-progress load; nil waits for completion (the
    /// short-lived CLI in-process path, which has no hook deadline to meet).
    static var loadWait: Duration? { loadWaitBox.withLock { $0 } }

    /// `rvd` binds `daemonLoadWait` at startup.
    public static func bindLoadWait(_ wait: Duration?) {
        loadWaitBox.withLock { $0 = wait }
    }

    /// Starts loading the judge this home would run, in the background, so
    /// the first judged request does not pay the model load. No-op when no
    /// bundle is installed or the platform has no CoreML. Cheap: resolves
    /// config and bundle paths, then hands the load to a utility queue.
    public static func prewarm(home: HomeDirectory?) {
        #if canImport(CoreML)
        guard let resolved = resolvedJudge(home: home, config: GuardConfig.read(home: home)) else { return }
        slot.prewarm(engine: resolved.engine, bundleDir: resolved.bundle)
        #endif
    }

    /// Judge block pins (boundReview .deny); review/abstain unlockable
    /// (Ask). `action` is the caller's threshold-resolved action — never
    /// re-derived here at default thresholds.
    static func raise(
        _ result: EvaluationResult,
        verdict: LayaVerdict?,
        action: LayaVerdict.Action,
        unavailable: String = unavailableReason
    ) -> EvaluationResult {
        let isBlock = action == .block
        let reason = verdict.map {
            "Laya judge: \($0.choice.rawValue) (risk \(String(format: "%.2f", $0.risk)))"
        } ?? unavailable
        let deny = Deny(
            ruleID: (isBlock ? JudgeRule.block : JudgeRule.review).ruleID,
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
                    choice: verdict.choice.rawValue,
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

    /// How long a judge-log append waits for another writer's lock.
    static let logLockTimeout: Duration = .milliseconds(200)

    /// Appends one row to `<config>/judge-log.jsonl`. Best effort: a row
    /// that does not land is reported through `dropLog`, and the verdict
    /// stands.
    static func appendLog(
        _ row: GatedEffect.JudgeLogRow,
        home: HomeDirectory,
        dropLog: AuditDropLog = .shared
    ) {
        let file = RVPolicyPaths.configDirectory(home: home).appendingPathComponent("judge-log.jsonl")
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
        if row.isLateResult { object["lateOf"] = true }
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
        // rvd and the hook-local evaluator both append here: a flocked
        // O_APPEND write keeps every row whole across processes, and never
        // replaces a file another writer just created. Best effort, so a
        // lock another process holds costs at most `logLockTimeout`.
        do {
            try JSONLAppendLog.append(data, to: file, sync: false, lockTimeout: logLockTimeout)
        } catch {
            dropLog.report(.judgeLog, file: file, consequence: "the verdict stood without its judge-log record")
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
    /// Called, off the caller, when a prediction answers after the caller
    /// stopped waiting (`late`): its run and how long it ran. Logging only;
    /// the verdict already returned stands.
    var onLateResult: (@Sendable (JudgeRuntime.JudgeRun, Duration) -> Void)? = nil
}

/// The one judge call the gated door makes. Production runs the CoreML
/// judge; tests substitute a fixed reading to drive thresholds and
/// observe/enforce without a model.
protocol JudgePort: Sendable {
    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun
}

/// Slot-cached CoreML judge (packs-only on platforms without CoreML). Waits
/// on an in-progress load for the live `loadWait` (rvd binds its bound).
struct LiveJudgePort: JudgePort {
    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        JudgeRuntime.runJudge(
            command: call.command, context: call.context,
            engine: call.engine, bundle: call.bundle, wait: JudgeRuntime.loadWait,
            onLate: call.onLateResult ?? { _, _ in }
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

/// The judge's load is still running past the caller's bounded wait.
enum JudgeLoadError: Error {
    case warming
}

#if canImport(CoreML)
/// One cached judge per engine: the stock three-question judge and the
/// fine-tuned single-pass judge load different bundles and must not share
/// a slot. Cache entries are keyed by bundle dir, so an upgraded bundle
/// is picked up; a load failure is cached only against the bundle's
/// model modification time, so repairing the bundle retries the load, and
/// for a minute at most, so a transient failure retries too.
/// Loads are single-flight (concurrent requests join one load) and run off
/// the caller, which waits at most `wait` (nil: until done).
final class JudgeSlot: Sendable {
    private let stock = SingleFlightLoader<LayaCoreMLJudge>()
    private let ft = SingleFlightLoader<FineTunedJudge>()
    private let coreML: @Sendable () -> CoreMLGuard

    init(coreML: @escaping @Sendable () -> CoreMLGuard = { JudgeRuntime.coreMLGuard }) {
        self.coreML = coreML
    }

    private static func stamp(_ bundleDir: URL) -> TimeInterval {
        let package = bundleDir.appendingPathComponent("model.mlpackage")
        let date = (try? FileManager.default.attributesOfItem(atPath: package.path))?[.modificationDate] as? Date
        return date?.timeIntervalSince1970 ?? 0
    }

    func stockJudge(bundleDir: URL, wait: Duration?) throws -> LayaCoreMLJudge {
        try Self.unwrap(stock.value(key: bundleDir, stamp: Self.stamp(bundleDir), wait: wait) {
            try LayaCoreMLJudge(bundleDir: bundleDir, coreML: self.coreML())
        })
    }

    func ftJudge(bundleDir: URL, wait: Duration?) throws -> FineTunedJudge {
        try Self.unwrap(ft.value(key: bundleDir, stamp: Self.stamp(bundleDir), wait: wait) {
            try FineTunedJudge(bundleDir: bundleDir, coreML: self.coreML())
        })
    }

    /// Starts the engine's load in the background; never blocks.
    func prewarm(engine: JudgeEngine, bundleDir: URL) {
        let stamp = Self.stamp(bundleDir)
        switch engine {
        case .laya:
            stock.prewarm(key: bundleDir, stamp: stamp) { try LayaCoreMLJudge(bundleDir: bundleDir, coreML: self.coreML()) }
        case .ft:
            ft.prewarm(key: bundleDir, stamp: stamp) { try FineTunedJudge(bundleDir: bundleDir, coreML: self.coreML()) }
        }
    }

    private static func unwrap<Judge>(_ outcome: SingleFlightLoader<Judge>.Outcome) throws -> Judge {
        switch outcome {
        case .ready(let judge): return judge
        case .failed(let error): throw error
        case .cachedFailure(let error): throw error
        case .warming: throw JudgeLoadError.warming
        }
    }
}
#else
/// Linux seam: no CoreML judge exists, every load is unavailable and
/// the gate runs packs-only. Referenced unconditionally above.
final class JudgeSlot: Sendable {}
#endif
