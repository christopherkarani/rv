import Foundation
import RVDomain

/// UAPI `LANDLOCK_ACCESS_FS_*` bit values. Stored so compile can be
/// syscall-free. The trampoline applies the write-class subset.
enum LandlockAccessFS {
    static let execute: UInt64 = 1 << 0
    static let writeFile: UInt64 = 1 << 1
    static let readFile: UInt64 = 1 << 2
    static let readDir: UInt64 = 1 << 3
    static let removeDir: UInt64 = 1 << 4
    static let removeFile: UInt64 = 1 << 5
    static let makeChar: UInt64 = 1 << 6
    static let makeDir: UInt64 = 1 << 7
    static let makeReg: UInt64 = 1 << 8
    static let makeSock: UInt64 = 1 << 9
    static let makeFifo: UInt64 = 1 << 10
    static let makeBlock: UInt64 = 1 << 11
    static let makeSym: UInt64 = 1 << 12
    static let refer: UInt64 = 1 << 13
    static let truncate: UInt64 = 1 << 14

    /// Write-class bits this slice handles. Not execute or net.
    /// `refer` (ABI 2) and `truncate` (ABI 3) are required so older ABIs
    /// cannot establish. The trampoline fail-closes when ABI < 3.
    static let writeClass: UInt64 =
        writeFile | removeDir | removeFile | makeChar | makeDir | makeReg
        | makeSock | makeFifo | makeBlock | makeSym | refer | truncate

    /// Read-class bits (ABI 1). Phase 6 compiles them and the shim grants
    /// them beneath the workspace alongside the write class. Reads of the
    /// system paths an inner program needs (`/usr`, `/lib`, loader) have
    /// no grant layer yet, so contained still refuses.
    static let readClass: UInt64 = readFile | readDir

    /// Every FS bit the contained slice handles once enforceable.
    /// Must stay in sync with `RV_LANDLOCK_HANDLED_FS` in landlock_apply.c.
    static let handledFS: UInt64 = writeClass | readClass
}

/// Host-side egress for a contained Linux runtime.
///
/// Landlock FS rules cannot express "deny direct net, allow one proxy
/// dial"; that needs net rules (ABI 4+) or a net namespace, neither of
/// which RV installs. Until then the only enforceable value is `.denied`,
/// and contained compilation refuses regardless of this field.
///
/// The `.hostProxy` case models the target shape, mirroring the OpenShell
/// supervisor-network pattern: the cage dials one supervisor-owned
/// loopback CONNECT proxy per runtime; policy evaluation and credentials
/// stay in the supervisor and only the proxy endpoint crosses the
/// boundary. The shape is structural: there is no address field, so a LAN
/// or public dial is unrepresentable, and there is no Unix-socket case
/// (Unix egress would expose every host socket; see SeatbeltProfile).
/// The port is per-ruleset so each runtime gets its own proxy instance.
public enum LandlockEgress: Sendable, Equatable {
    /// No network egress.
    case denied
    /// Dial the supervisor's per-runtime CONNECT proxy on 127.0.0.1.
    /// Not yet enforceable; present only to pin the target shape.
    case hostProxy(loopbackPort: UInt16)

    /// Validated host-proxy endpoint. Port 0 (kernel-assigned) and
    /// out-of-range ports are unrepresentable as a dial target.
    public static func validatedHostProxy(port: Int) -> LandlockEgress? {
        guard port >= 1, port <= 65535 else {
            return nil
        }
        return .hostProxy(loopbackPort: UInt16(port))
    }
}

/// Compiled first-slice Landlock ruleset. Production construction is
/// `compileLandlockRuleset` only. Not Seatbelt SBPL.
public struct LandlockRuleset: Sendable, Equatable {
    public let workspacePath: String
    public let handledWriteAccess: UInt64
    public let handledReadAccess: UInt64
    public let egress: LandlockEgress

    init(
        workspacePath: String,
        handledWriteAccess: UInt64,
        handledReadAccess: UInt64 = LandlockAccessFS.readClass,
        egress: LandlockEgress = .denied
    ) {
        self.workspacePath = workspacePath
        self.handledWriteAccess = handledWriteAccess
        self.handledReadAccess = handledReadAccess
        self.egress = egress
    }
}

/// Landlock cannot yet enforce a workspace-scoped contained plan.
/// Path checks still run. A valid workspace is `containedGuaranteesUnsupported`
/// rather than a read/write ruleset that would still leave system-read
/// layering, network, and process guarantees unenforced. Phase 6 compiles
/// read grants and models host-proxy egress, but every guarantee bit must
/// be enforceable before contained stops refusing.
/// Observed / mediated plans are not applicable.
public func compileLandlockRuleset(
    _ plan: IsolationPlan
) -> Result<LandlockRuleset, IsolationApplyError> {
    switch plan.mode {
    case .observed, .mediated:
        return .failure(.profileNotApplicable)
    case .contained(let guarantees):
        guard let workspace = plan.workspace else {
            return .failure(.containedGuaranteesUnsupported)
        }
        switch guarantees.filesystem {
        case .workspaceScoped(let limitedTo):
            guard limitedTo == workspace else {
                return .failure(.containedGuaranteesUnsupported)
            }
        case .unrestricted:
            return .failure(.containedGuaranteesUnsupported)
        }
        switch guarantees.network {
        case .denied:
            break
        case .unrestricted:
            return .failure(.containedGuaranteesUnsupported)
        }
        switch guarantees.process {
        case .hostSignalsDenied:
            break
        case .unrestricted:
            return .failure(.containedGuaranteesUnsupported)
        }
        switch guarantees.descent {
        case .inherited:
            break
        case .notInherited:
            return .failure(.containedGuaranteesUnsupported)
        }
        switch compileFirstSliceLandlock(workspace: workspace) {
        case .failure(let error):
            return .failure(error)
        case .success(let ruleset):
            switch existingResolvedWorkspacePath(workspace) {
            case .failure(let error):
                return .failure(error)
            case .success(let resolved):
                guard resolved == ruleset.workspacePath else {
                    return .failure(.workspacePathUnresolvable)
                }
                return .failure(.containedGuaranteesUnsupported)
            }
        }
    }
}

func compileFirstSliceLandlock(
    workspace: WorkingDirectory
) -> Result<LandlockRuleset, IsolationApplyError> {
    let raw = workspace.rawValue
    guard raw.hasPrefix("/") else {
        return .failure(.workspaceMustBeAbsolute)
    }
    if raw.contains("\n") || raw.contains("\0") {
        return .failure(.workspacePathUnsafe)
    }
    let resolved = resolvedWorkspacePath(workspace)
    if resolved.isEmpty {
        return .failure(.workspacePathUnresolvable)
    }
    if isUnsafeResolvedWorkspace(resolved) {
        return .failure(.workspacePathUnsafe)
    }
    return .success(
        LandlockRuleset(
            workspacePath: resolved,
            handledWriteAccess: LandlockAccessFS.writeClass,
            handledReadAccess: LandlockAccessFS.readClass,
            egress: .denied
        )
    )
}
