import Foundation
import RVDomain
import RVIPC
import RVJudgePool
import RVLaya
import RVPacks
import RVPolicy

public enum DoctorSnapshotBuilder {
    public static func make(
        catalog: PackCatalog,
        corePacksReady: Bool,
        idleExitSeconds: Int,
        lastError: String? = nil,
        home: HomeDirectory? = nil,
        judgePool: JudgePoolProbe = .unbound
    ) -> DoctorSnapshotReply {
        // The installed template's supervisor: the LaunchAgent is KeepAlive
        // on macOS; Linux's systemd unit is Restart=always, not KeepAlive.
#if os(Linux)
        let reportedKeepAlive = false
#else
        let reportedKeepAlive = true
#endif
        var checks: [DoctorCheck] = [
            DoctorCheck(id: .xpc, status: .ok, message: "mach service \(RVService.machServiceName)"),
            DoctorCheck(id: .protocol, status: .ok, message: ProtocolVersion.name),
            DoctorCheck(
                id: .packs,
                status: corePacksReady ? .ok : .error,
                message: corePacksReady ? dayOnePacksLoadedMessage : "core packs unavailable"
            ),
            DoctorCheck(
                id: .launchd,
                status: .ok,
                message: launchdCheckMessage(
                    keepAlive: reportedKeepAlive,
                    idleExitSeconds: idleExitSeconds
                )
            ),
            DoctorCheck(id: .pi, status: .skipped, message: "T7"),
            DoctorCheck(id: .grok, status: .skipped, message: "T7"),
            DoctorCheck(id: .opencode, status: .skipped, message: "T7"),
        ]
        checks.append(judgeCheck(home: home))
        let bundleInstalled = if case .ok = JudgeRuntime.bundleHealth(home: home) { true } else { false }
        if let pool = judgePoolCheck(judgePool, bundleInstalled: bundleInstalled) { checks.append(pool) }
        if lastError != nil {
            checks.append(DoctorCheck(id: .lastError, status: .warning, message: "see lastError"))
        }
        return DoctorSnapshotReply(
            state: .running,
            keepAlive: reportedKeepAlive,
            idleExitSeconds: idleExitSeconds,
            packsEnabled: catalog.enabledIDs,
            lastError: lastError,
            checks: checks
        )
    }

    /// Degraded guard visibility: judge state is reported, never assumed.
    /// Names the resolved engine plus the bundle dir actually in use, a
    /// present-but-invalid bundle as a warning, or where the production
    /// bundle should be installed. A judge on behind an open circuit
    /// (`JudgeCircuit`) is a warning: judged calls go to review meanwhile.
    static func judgeCheck(
        home: HomeDirectory?, circuit: JudgeCircuit.Status = JudgeCircuit.live.status
    ) -> DoctorCheck {
        let mode = GuardModeResolution.resolve(
            GuardConfig.read(home: home), host: nil, environment: ProcessInfo.processInfo.environment)
        switch JudgeRuntime.bundleHealth(home: home) {
        case .ok(let engine, let bundle):
            #if canImport(CoreML)
            let on = "laya-\(engine.rawValue) judge on (guard \(mode.rawValue)), bundle \(bundle.path)"
            let meanwhile = mode == .observe
                ? "judged calls run and are logged as a would-be review"
                : "judged calls go to review"
            // rvd's own Core ML guard only matters when rvd loads the model
            // itself; with the pool bound, `judgePool` reports the workers.
            let notes = JudgeRuntime.boundClient == nil ? coreMLNotes(JudgeRuntime.coreMLGuard.status) : []
            let base = ([on] + notes).joined(separator: "; ")
            switch circuit {
            case .closed:
                return DoctorCheck(id: .judge, status: notes.isEmpty ? .ok : .warning, message: base)
            case .open(let retryIn):
                return DoctorCheck(
                    id: .judge, status: .warning,
                    message: "\(base); rv degraded: judge unavailable (circuit open, retrying in \(JudgeRuntime.retrySeconds(retryIn))s), \(meanwhile)"
                )
            case .halfOpen(let trialInFlight):
                let trial = trialInFlight ? "a trial call is running" : "the next judged call is a trial"
                return DoctorCheck(
                    id: .judge, status: .warning,
                    message: "\(base); rv degraded: judge circuit half-open, \(trial); until it answers, other \(meanwhile)"
                )
            }
            #else
            return DoctorCheck(
                id: .judge, status: .warning,
                message: "laya-\(engine.rawValue) bundle at \(bundle.path) but CoreML is unavailable on this platform; packs only (guard \(mode.rawValue))"
            )
            #endif
        case .invalid(let engine, let dir, let problems):
            // rvd still selects a bundle that is on disk but fails a check
            // (config labels): the pool cannot load it, and judged calls go
            // to review. One it does not select leaves it packs-only.
            #if canImport(CoreML)
            let effect = JudgeRuntime.selectsBundle(home: home) ? "judged calls go to review" : "packs only"
            #else
            let effect = "packs only"
            #endif
            return DoctorCheck(
                id: .judge, status: .warning,
                message: "laya-\(engine.rawValue) bundle invalid at \(dir.path): \(problems.joined(separator: ", ")); \(effect) (guard \(mode.rawValue))"
            )
        case .missing(let engine, let expected):
            return DoctorCheck(
                id: .judge, status: .skipped,
                message: "no \(engine.rawValue) bundle installed at \(expected?.path ?? engine.rawValue); packs only (guard \(mode.rawValue))"
            )
        }
    }

    /// The judge pool rvd routes through (macOS): unreachable is a warning,
    /// since every judged call then goes to review; a degraded or
    /// unloadable worker is a warning too. Nil when rvd runs the judge
    /// in-process (no pool to report).
    /// Nil when there is no pool to report: none bound (Linux, the CLI), or
    /// an unreachable pool while no bundle is installed (nothing is judged,
    /// so the pool is never asked).
    static func judgePoolCheck(_ probe: JudgePoolProbe, bundleInstalled: Bool = true) -> DoctorCheck? {
        guard probe.bound else { return nil }
        guard let status = probe.status else {
            guard bundleInstalled else { return nil }
            return DoctorCheck(
                id: .judgePool, status: .warning,
                message: "judge pool unreachable or unverified (\(JudgePoolWire.machServiceName)): judged calls go to review; run `rv setup` (a peer-trust manifest needs a `judge` entry)"
            )
        }
        let workers = status.workers.map { worker in
            var line = "\(worker.slot.rawValue) \(worker.compute) \(worker.phase), restarts \(worker.restarts)"
            if worker.degraded { line += ", degraded" }
            if let failure = worker.loadFailure { line += ", load failed: \(failure.message)" }
            return line
        }
        let unhealthy = status.workers.contains { $0.degraded || $0.loadFailure != nil }
        let message = "workers \(workers.joined(separator: "; ")); routing \(status.routing); "
            + "served \(status.served), hedged \(status.hedged), killed \(status.killed), late \(status.late), busy \(status.refusedBusy)"
        return DoctorCheck(id: .judgePool, status: unhealthy ? .warning : .ok, message: message)
    }

    /// Degraded Core ML states doctor names: CPU-only after crashes, a disk
    /// too full for the judge to load or predict (calls go to review), and
    /// rvd running without its crash marker.
    static func coreMLNotes(_ status: CoreMLGuard.Status) -> [String] {
        var notes: [String] = []
        if status.units == .cpuOnly {
            let until = status.cpuOnlyUntil.map { " until \($0.formatted(.iso8601))" } ?? ""
            notes.append("CPU only\(until) after repeated Core ML crashes")
        }
        if status.diskLow {
            notes.append("disk nearly full; judge disabled until space is freed")
        }
        if status.crashMarkerUnavailable {
            notes.append("Core ML crash marker held by another process or unwritable; no CPU-only fallback after a crash")
        }
        if let reason = status.lastRefusal {
            notes.append("last judge load refused: \(reason)")
        }
        return notes
    }

    private static var dayOnePacksLoadedMessage: String {
        let names = dayOnePackIDs.map(\.rawValue)
        guard let last = names.last else {
            return "core packs unavailable"
        }
        if names.count == 1 {
            return "\(last) loaded"
        }
        let head = names.dropLast().joined(separator: ", ")
        return "\(head), and \(last) loaded"
    }

    private static func launchdCheckMessage(
        keepAlive: Bool,
        idleExitSeconds: Int
    ) -> String {
        let label = RVService.machServiceName
        let idleExit = idleExitSeconds > 0 ? "idle-exit \(idleExitSeconds)s" : "idle-exit off"
        let supervisor = keepAlive ? "KeepAlive true" : "Restart=always"
        return "template \(label) \(supervisor) \(idleExit)"
    }
}
