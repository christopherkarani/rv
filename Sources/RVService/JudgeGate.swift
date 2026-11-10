import Foundation
import RVDomain
import RVEngine
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
    private static let slot = JudgeSlot()

    static let ftBundleName = "laya-ft-v2-coreml"
    static let stockBundleName = "laya-multilingual-coreml"

    public static func thresholds(provenance: ActionProvenance) -> (block: Double, review: Double) {
        provenance.isUntrusted ? (0.6, 0.30) : (0.8, 0.45)
    }

    /// Machine-wide guard mode, ignoring per-host entries and the
    /// organization pin (doctor, `rv host list`).
    public static func guardMode(home: HomeDirectory?) -> GuardMode {
        guardMode(environment: ProcessInfo.processInfo.environment, config: loadConfigDict(home: home))
    }

    /// The mode one evaluation from `host` runs under: per-host resolution,
    /// then the organization pin (`ManagedGate.guardMode`). The file door
    /// reads it once per evaluation; the shell doors read it through
    /// `EvaluationInputs`.
    static func effectiveGuardMode(
        home: HomeDirectory?,
        host: LedgerHost,
        environment: [String: String],
        config: [String: Any]?
    ) -> GuardMode {
        let hookHost: HookHost?
        switch host {
        case .tty: hookHost = nil
        case .hook(let hook): hookHost = hook
        }
        return ManagedGate.guardMode(
            guardMode(environment: environment, config: config, host: hookHost), home: home)
    }

    /// `RV_GUARD_MODE=enforce` > `guard.hosts.<host>` > `guard.mode` >
    /// enforce. An unknown value at any level falls through to the next. A
    /// host entry of `block` is enforce; `observe` and `off` are observe (an
    /// `off` host should be unwired, so a stale hook that still fires must
    /// never block).
    ///
    /// The environment can only tighten: `RV_GUARD_MODE=observe` is
    /// ignored. rvd inherits its environment from launchd/systemd, which a
    /// same-user agent can edit (`launchctl setenv`); loosening belongs to
    /// the owner's config (`rv host mode`, `guard.mode`), never to the
    /// launch environment. Tests inject `environment` and `config` directly.
    static func guardMode(
        environment: [String: String],
        config: [String: Any]?,
        host: HookHost? = nil
    ) -> GuardMode {
        if let raw = environment["RV_GUARD_MODE"],
           GuardMode(rawValue: raw.lowercased()) == .enforce {
            return .enforce
        }
        if let host, let hostMode = HostModeStore.modes(inConfig: config)[host] {
            return hostMode == .block ? .enforce : .observe
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
    static func explicitEngine(config: [String: Any]?) -> JudgeEngine? {
        configEngine(config).flatMap { JudgeEngine(rawValue: $0.lowercased()) }
    }

    static func resolveEngine(
        config: [String: Any]?,
        bundleExists: (JudgeEngine) -> Bool
    ) -> (engine: JudgeEngine, bundlePresent: Bool) {
        let resolved = resolveEngine(config: config) { bundleExists($0) ? () : nil }
        return (resolved.engine, resolved.bundle != nil)
    }

    /// The one precedence ladder. `bundle` probes each engine at most once.
    static func resolveEngine<Bundle>(
        config: [String: Any]?,
        bundle: (JudgeEngine) -> Bundle?
    ) -> (engine: JudgeEngine, bundle: Bundle?) {
        if let explicit = explicitEngine(config: config) {
            return (explicit, bundle(explicit))
        }
        if let ft = bundle(.ft) { return (.ft, ft) }
        return (.laya, bundle(.laya))
    }

    /// Engine and validated bundle from already-read config. Only the
    /// bundle directories are probed.
    static func selection(
        home: HomeDirectory?,
        config: [String: Any]?
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
    static func resolvedJudge(home: HomeDirectory?) -> (engine: JudgeEngine, bundle: URL)? {
        let selected = selection(home: home, config: loadConfigDict(home: home))
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
        let explicitChoice = explicitEngine(config: loadConfigDict(home: home))
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
        let explicit = explicitEngine(config: loadConfigDict(home: home))
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
            return (packsOnlyFloor(result, command: command), logRow(
                guardMode: inputs.guardMode, subject: .live(result),
                verdict: nil, action: nil, engine: selection.engine,
                note: noteFor("engine-missing", contextPartial: partial), now: now, isPeek: isPeek
            ))
        }
        let run = judge.judge(JudgeCall(
            command: command.rawValue, context: context,
            engine: selection.engine, bundle: bundle
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
        isPeek: Bool
    ) -> (result: EvaluationResult, wouldBe: EvaluationResult, log: GatedEffect.JudgeLogRow) {
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
        return (result.observedAllow, reading.outcome, logRow(
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
        case .failed, .warming, .busy:
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
    enum JudgeRun: Sendable {
        case verdict(LayaVerdict)
        case unavailable(String)
        case failed
        case warming
        case busy
    }

    static func runJudge(
        command: String,
        context: JudgeContext,
        engine: JudgeEngine,
        bundle: URL,
        wait: Duration? = loadWait
    ) -> JudgeRun {
        #if canImport(CoreML)
        let wait = JudgeAdmission.loadWait(wait, until: JudgeAdmission.deadline)
        do {
            switch engine {
            case .laya:
                let judge = try slot.stockJudge(bundleDir: bundle, wait: wait)
                return admitted {
                    do { return .verdict(try judge.judge(command)) }
                    catch { return .failed }
                }
            case .ft:
                let judge = try slot.ftJudge(bundleDir: bundle, wait: wait)
                return admitted {
                    do { return .verdict(try judge.judge(command, context: context)) }
                    catch { return .failed }
                }
            }
        } catch JudgeLoadError.warming {
            return .warming
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

    /// Inference through the live admission, bounded by this request's hook
    /// deadline. The model load is not admitted: it is single-flight and
    /// has its own bounded wait (`loadWait`).
    static func admitted(
        through admission: JudgeAdmission = .live,
        until deadline: ContinuousClock.Instant? = JudgeAdmission.deadline,
        _ inference: () -> JudgeRun
    ) -> JudgeRun {
        admission.run(until: deadline, inference) ?? .busy
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

    /// The daemon's bound on waiting for an in-progress judge load. Past it
    /// the request goes to review (`judge-warming`); the load keeps going.
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
        guard let resolved = resolvedJudge(home: home) else { return }
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

/// Slot-cached CoreML judge (packs-only on platforms without CoreML). Waits
/// on an in-progress load for the live `loadWait` (rvd binds its bound).
struct LiveJudgePort: JudgePort {
    func judge(_ call: JudgeCall) -> JudgeRuntime.JudgeRun {
        JudgeRuntime.runJudge(
            command: call.command, context: call.context,
            engine: call.engine, bundle: call.bundle, wait: JudgeRuntime.loadWait
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

    private static func stamp(_ bundleDir: URL) -> TimeInterval {
        let package = bundleDir.appendingPathComponent("model.mlpackage")
        let date = (try? FileManager.default.attributesOfItem(atPath: package.path))?[.modificationDate] as? Date
        return date?.timeIntervalSince1970 ?? 0
    }

    func stockJudge(bundleDir: URL, wait: Duration?) throws -> LayaCoreMLJudge {
        try Self.unwrap(stock.value(key: bundleDir, stamp: Self.stamp(bundleDir), wait: wait) {
            try LayaCoreMLJudge(bundleDir: bundleDir)
        })
    }

    func ftJudge(bundleDir: URL, wait: Duration?) throws -> FineTunedJudge {
        try Self.unwrap(ft.value(key: bundleDir, stamp: Self.stamp(bundleDir), wait: wait) {
            try FineTunedJudge(bundleDir: bundleDir)
        })
    }

    /// Starts the engine's load in the background; never blocks.
    func prewarm(engine: JudgeEngine, bundleDir: URL) {
        let stamp = Self.stamp(bundleDir)
        switch engine {
        case .laya:
            stock.prewarm(key: bundleDir, stamp: stamp) { try LayaCoreMLJudge(bundleDir: bundleDir) }
        case .ft:
            ft.prewarm(key: bundleDir, stamp: stamp) { try FineTunedJudge(bundleDir: bundleDir) }
        }
    }

    private static func unwrap<Judge>(_ outcome: SingleFlightLoader<Judge>.Outcome) throws -> Judge {
        switch outcome {
        case .ready(let judge): return judge
        case .failed(let error): throw error
        case .cachedFailure: throw LayaError.modelUnavailable("cached load failure")
        case .warming: throw JudgeLoadError.warming
        }
    }
}
#else
/// Linux seam: no CoreML judge exists, every load is unavailable and
/// the gate runs packs-only. Referenced unconditionally above.
final class JudgeSlot: Sendable {}
#endif
