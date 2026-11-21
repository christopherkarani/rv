import Foundation
import RVDomain
import RVIPC
import RVLaya
import RVPacks
import RVPolicy

public enum DoctorSnapshotBuilder {
    public static func make(
        catalog: PackCatalog,
        corePacksReady: Bool,
        idleExitSeconds: Int,
        lastError: String? = nil,
        keepAlive: Bool = false,
        home: HomeDirectory? = nil
    ) -> DoctorSnapshotReply {
#if os(Linux)
        let reportedKeepAlive = false
#else
        let reportedKeepAlive = keepAlive
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
            let base = "laya-\(engine.rawValue) judge on (guard \(mode.rawValue)), bundle \(bundle.path)"
            let notes = coreMLNotes(JudgeRuntime.coreMLGuard.status)
            let on = ([base] + notes).joined(separator: "; ")
            let meanwhile = mode == .observe
                ? "judged calls run and are logged as a would-be review"
                : "judged calls go to review"
            switch circuit {
            case .closed:
                return DoctorCheck(id: .judge, status: notes.isEmpty ? .ok : .warning, message: on)
            case .open(let retryIn):
                return DoctorCheck(
                    id: .judge, status: .warning,
                    message: "\(on); rv degraded: judge unavailable (circuit open, retrying in \(JudgeRuntime.retrySeconds(retryIn))s), \(meanwhile)"
                )
            case .halfOpen(let trialInFlight):
                let trial = trialInFlight ? "a trial call is running" : "the next judged call is a trial"
                return DoctorCheck(
                    id: .judge, status: .warning,
                    message: "\(on); rv degraded: judge circuit half-open, \(trial); until it answers, other \(meanwhile)"
                )
            }
            #else
            return DoctorCheck(
                id: .judge, status: .warning,
                message: "laya-\(engine.rawValue) bundle at \(bundle.path) but CoreML is unavailable on this platform; packs only (guard \(mode.rawValue))"
            )
            #endif
        case .invalid(let engine, let dir, let problems):
            return DoctorCheck(
                id: .judge, status: .warning,
                message: "laya-\(engine.rawValue) bundle invalid at \(dir.path): \(problems.joined(separator: ", ")); packs only (guard \(mode.rawValue))"
            )
        case .missing(let engine, let expected):
            return DoctorCheck(
                id: .judge, status: .skipped,
                message: "no \(engine.rawValue) bundle installed at \(expected?.path ?? engine.rawValue); packs only (guard \(mode.rawValue))"
            )
        }
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
        if keepAlive {
            return "template \(label) KeepAlive true"
        }
#if os(Linux)
        return "template \(label) Restart=always idle-exit \(idleExitSeconds)s"
#else
        return "template \(label) KeepAlive false idle-exit \(idleExitSeconds)s"
#endif
    }
}
