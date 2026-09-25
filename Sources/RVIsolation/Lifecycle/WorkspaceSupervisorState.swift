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
public struct WorkspaceSupervisorState: Sendable, Equatable {
    /// Reuses the domain phase (`creating`/`active`/`closing`/`closed`) so
    /// existing snapshots and wire encodings keep their meaning.
    public var phase: WorkspaceLifecycle
    /// Recovery/admission (`WorkspaceRecovery.admit`) has not reported yet.
    /// A second report drains to a no-op.
    public var admissionPending: Bool
    /// `WorkspaceInodeBoundary.remainsEstablished()`. While false, spawns
    /// are refused; the flag never self-heals.
    public var boundaryEstablished: Bool
    /// Close was accepted; no new runtime may start.
    public var closeAccepted: Bool
    /// Publish flag of the close that currently owns teardown.
    public var closePublish: Bool?
    /// A `finishTeardown` effect is outstanding; a second close waits.
    public var teardownInFlight: Bool
    /// Terminal teardown failure; later closes replay it without new work.
    public var terminalCloseFailure: WorkspaceCloseFailure?
    /// Successful `close(publish: true)` completions.
    public var publishCount: Int
    /// Concurrent running-runtime cap. Configuration: set at init, never
    /// mutated by the transition.
    public var runningLimit: Int?
    public var runtimes: [RuntimeSessionID: WorkspaceRuntimePhase]

    public init(
        phase: WorkspaceLifecycle = .creating,
        admissionPending: Bool = true,
        boundaryEstablished: Bool = true,
        closeAccepted: Bool = false,
        closePublish: Bool? = nil,
        teardownInFlight: Bool = false,
        terminalCloseFailure: WorkspaceCloseFailure? = nil,
        publishCount: Int = 0,
        runningLimit: Int? = nil,
        runtimes: [RuntimeSessionID: WorkspaceRuntimePhase] = [:]
    ) {
        self.phase = phase
        self.admissionPending = admissionPending
        self.boundaryEstablished = boundaryEstablished
        self.closeAccepted = closeAccepted
        self.closePublish = closePublish
        self.teardownInFlight = teardownInFlight
        self.terminalCloseFailure = terminalCloseFailure
        self.publishCount = publishCount
        self.runningLimit = runningLimit
        self.runtimes = runtimes
    }

    /// Fresh supervisor state for one open attempt.
    public static func initial(runningLimit: Int? = nil) -> Self {
        Self(runningLimit: runningLimit)
    }

    /// Running runtimes in stable report order.
    public var runningRuntimeIDs: [RuntimeSessionID] {
        runtimes
            .filter { $0.value.isRunning }
            .map(\.key)
            .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }
}
