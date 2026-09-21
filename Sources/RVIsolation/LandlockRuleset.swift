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

    /// Write-class bits this slice handles. Not read, execute, or net.
    /// `refer` (ABI 2) is required so ABI 1 cannot establish.
    /// `truncate` is intended; the trampoline applies it only when ABI ≥ 3.
    static let writeClass: UInt64 =
        writeFile | removeDir | removeFile | makeChar | makeDir | makeReg
        | makeSock | makeFifo | makeBlock | makeSym | refer | truncate
}

/// Compiled first-slice Landlock ruleset. Production construction is
/// `compileLandlockRuleset` only. Not Seatbelt SBPL.
public struct LandlockRuleset: Sendable, Equatable {
    public let workspacePath: String
    public let handledWriteAccess: UInt64

    init(workspacePath: String, handledWriteAccess: UInt64) {
        self.workspacePath = workspacePath
        self.handledWriteAccess = handledWriteAccess
    }
}

/// First-slice Landlock ruleset: write-class handled accesses under the
/// resolved workspace. Network stays unrestricted (no net handled bits).
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
        case .writesLimited(let limitedTo):
            guard limitedTo == workspace else {
                return .failure(.containedGuaranteesUnsupported)
            }
        case .unrestricted:
            return .failure(.containedGuaranteesUnsupported)
        }
        switch guarantees.descent {
        case .inherited:
            break
        case .notInherited:
            return .failure(.containedGuaranteesUnsupported)
        }
        switch guarantees.network {
        case .unrestricted:
            break
        }
        return compileFirstSliceLandlock(workspace: workspace)
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
    if resolved.contains("\n") || resolved.contains("\0") {
        return .failure(.workspacePathUnsafe)
    }
    return .success(
        LandlockRuleset(
            workspacePath: resolved,
            handledWriteAccess: LandlockAccessFS.writeClass
        )
    )
}
