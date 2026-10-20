import RVDomain
import RVIPC
import RVPacks
import RVPolicy

public enum DoctorSnapshotBuilder {
    public static func make(
        catalog: PackCatalog,
        corePacksReady: Bool,
        idleExitSeconds: Int,
        lastError: String? = nil,
        keepAlive: Bool = false
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
        checks.append(judgeCheck())
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
    /// Names the resolved engine plus the bundle dir actually in use, or
    /// the selected engine plus where its bundle should be installed.
    private static func judgeCheck() -> DoctorCheck {
        let home = HomeDirectory.process()
        let mode = JudgeRuntime.guardMode(home: home)
        if let resolved = JudgeRuntime.resolvedJudge(home: home) {
            return DoctorCheck(
                id: .judge, status: .ok,
                message: "laya-\(resolved.engine.rawValue) judge on (guard \(mode.rawValue)), bundle \(resolved.bundle.path)"
            )
        }
        let engine = JudgeRuntime.selectedEngine(home: home)
        let expected = JudgeRuntime.expectedBundleDir(engine: engine, home: home)?.path
            ?? engine.rawValue
        return DoctorCheck(
            id: .judge, status: .skipped,
            message: "no \(engine.rawValue) bundle installed at \(expected); packs only (guard \(mode.rawValue))"
        )
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
        return "template \(label) Restart=no idle-exit \(idleExitSeconds)s"
#else
        return "template \(label) KeepAlive false idle-exit \(idleExitSeconds)s"
#endif
    }
}
