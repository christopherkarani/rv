import RVDomain
import RVIPC
import RVPacks

public enum DoctorSnapshotBuilder {
    public static func make(
        catalog: PackCatalog,
        corePacksReady: Bool,
        idleExitSeconds: Int,
        lastError: String? = nil
    ) -> DoctorSnapshotReply {
        var checks: [DoctorCheck] = [
            DoctorCheck(id: "xpc", status: .ok, message: "mach service \(RVService.machServiceName)"),
            DoctorCheck(id: "protocol", status: .ok, message: ProtocolVersion.name),
            DoctorCheck(
                id: "packs",
                status: corePacksReady ? .ok : .error,
                message: corePacksReady ? "core.git and core.filesystem loaded" : "core packs unavailable"
            ),
            DoctorCheck(
                id: "launchd",
                status: .ok,
                message: "template \(RVService.machServiceName) KeepAlive false idle-exit \(idleExitSeconds)s"
            ),
            DoctorCheck(id: "pi", status: .skipped, message: "T7"),
            DoctorCheck(id: "grok", status: .skipped, message: "T7"),
            DoctorCheck(id: "opencode", status: .skipped, message: "T7"),
        ]
        if lastError != nil {
            checks.append(DoctorCheck(id: "lastError", status: .warning, message: "see lastError"))
        }
        return DoctorSnapshotReply(
            state: .running,
            keepAlive: false,
            idleExitSeconds: idleExitSeconds,
            packsEnabled: catalog.enabledIDs,
            lastError: lastError,
            checks: checks
        )
    }
}
