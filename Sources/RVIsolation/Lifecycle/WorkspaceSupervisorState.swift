import Foundation
import RVDomain

/// Per-runtime phase inside the pure lifecycle core.
///
/// Mirrors the Seatbelt watch in `SessionSupervisor.swift`: a runtime is
/// spawned suspended, recorded, resumed, and only then trusted once the
/// in-sandbox handshake arrives (`LiveSeatbeltChild.isEstablished`). The
/// workspace owns it until it exits or the workspace closes.
public enum WorkspaceRuntimePhase: Sendable, Equatable {
    /// Spawn accepted; the process is not yet recorded.
    case starting
    /// Spawned and recorded; awaiting the in-sandbox handshake.
    case handshaking
    /// Handshake proved; running under workspace ownership.
    case established
    /// Stop requested (`cancel`/`close`); the watch has not reaped it yet.
    case exiting
    /// Reaped; retained for reports until forgotten.
    case exited
    /// Never established; terminal, retained for reports until forgotten.
    case failed

    /// Counts toward the concurrent running-runtime cap, matching the
    /// supervisor's `watchFinished == false` count.
    public var isRunning: Bool {
        switch self {
        case .starting, .handshaking, .established, .exiting:
            true
        case .exited, .failed:
            false
        }
    }
}

/// Decision state for one protected workspace.
///
/// Every field the transition reads or writes lives here; the supervisor
/// owns the boundary, the processes, the locks, and the threads, and
/// executes the effects the transition returns. Follows the
/// `WorkspaceTUIReducer` precedent: `State + Event -> (State, Effects)`.
/// Whether the inode boundary still holds. One-way: the transition moves
/// `.established` to `.lost` and never back.
public enum WorkspaceBoundaryState: Sendable, Equatable {
    case established
    case lost
}

public struct WorkspaceSupervisorState: Sendable, Equatable {
    /// Reuses the domain phase (`creating`/`active`/`closing`/`closed`) so
    /// existing snapshots and wire encodings keep their meaning.
    public var phase: WorkspaceLifecycle
    /// Recovery/admission (`WorkspaceRecovery.admit`) has not reported yet.
    /// A second report drains to a no-op.
    public var admissionPending: Bool
    /// `WorkspaceInodeBoundary.remainsEstablished()`. While `.lost`, spawns
    /// are refused; the boundary never self-heals.
    public var boundary: WorkspaceBoundaryState
    /// Where this workspace's close stands; `.open` until a close leads.
    public var closeState: WorkspaceCloseState
    /// Successful `close(publish: .publish)` completions.
    public var publishCount: Int
    /// Concurrent running-runtime cap. Configuration: set at init, never
    /// mutated by the transition. Must be non-negative (`nil` means uncapped).
    public let runningLimit: Int?
    /// Tracked runtimes by id; finished entries stay until forgotten.
    public var runtimes: [RuntimeSessionID: WorkspaceRuntimePhase]

    public init(
        phase: WorkspaceLifecycle = .creating,
        admissionPending: Bool = true,
        boundary: WorkspaceBoundaryState = .established,
        closeState: WorkspaceCloseState = .open,
        publishCount: Int = 0,
        runningLimit: Int? = nil,
        runtimes: [RuntimeSessionID: WorkspaceRuntimePhase] = [:]
    ) {
        precondition((runningLimit ?? 0) >= 0, "runningLimit must be non-negative")
        self.phase = phase
        self.admissionPending = admissionPending
        self.boundary = boundary
        self.closeState = closeState
        self.publishCount = publishCount
        self.runningLimit = runningLimit
        self.runtimes = runtimes
    }

    /// Running runtimes in stable report order.
    public var runningRuntimeIDs: [RuntimeSessionID] {
        runtimes
            .filter { $0.value.isRunning }
            .map(\.key)
            .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    /// Live running-runtime count without sorting the report order.
    public var runningRuntimeCount: Int {
        runtimes.values.count(where: \.isRunning)
    }
}
