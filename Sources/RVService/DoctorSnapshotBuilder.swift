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
    /// bundle should be installed.
    private static func judgeCheck(home: HomeDirectory?) -> DoctorCheck {
        let mode = GuardModeResolution.resolve(
            GuardConfig.read(home: home), host: nil, environment: ProcessInfo.processInfo.environment)
        switch JudgeRuntime.bundleHealth(home: home) {
        case .ok(let engine, let bundle):
            #if canImport(CoreML)
            let base = "laya-\(engine.rawValue) judge on (guard \(mode.rawValue)), bundle \(bundle.path)"
            let notes = coreMLNotes(JudgeRuntime.coreMLGuard.status)
            return DoctorCheck(
                id: .judge, status: notes.isEmpty ? .ok : .warning,
                message: ([base] + notes).joined(separator: "; ")
            )
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

    /// Degraded Core ML states doctor names: CPU-only after crashes, and a
    /// disk too full for the judge to load or predict (calls go to review).
    static func coreMLNotes(_ status: CoreMLGuard.Status) -> [String] {
        var notes: [String] = []
        if status.units == .cpuOnly {
            let until = status.cpuOnlyUntil.map { " until \($0.formatted(.iso8601))" } ?? ""
            notes.append("CPU only\(until) after repeated Core ML crashes")
        }
        if status.diskLow {
            notes.append("disk nearly full; judge disabled until space is freed")
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
