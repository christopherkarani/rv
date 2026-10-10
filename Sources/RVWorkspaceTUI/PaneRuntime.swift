import Foundation

/// One pane's live runtime record.
///
/// The reducer used to track per-pane runtime state in eleven parallel
/// collections (`terminals`, `pendingLaunches`, `leasedBindings`,
/// `retryAcquirePanes`, `retrySubscribePanes`, `pendingInput`,
/// `replayBatches`, `recentOutputOnly`, `scrollAnchors`,
/// `scrollGenerations`, `preDisconnectLeases`), keyed independently by
/// `PaneID`. A pane could be launching and attached at once with no
/// relation between the entries, a scroll anchor could outlive its
/// generation, and a lease claim could name a binding no map could see.
/// One record per pane keeps every per-pane datum in a single place:
/// closing a pane drops its whole record, and a phase transition carries
/// the claim, scroll, retries, and typeahead along unless the transition
/// explicitly clears them.
///
/// What lives here vs elsewhere:
/// - `WorkspacePane` (in `WorkspaceView`) keeps presentation identity:
///   the persisted binding reference, the user title, and the last
///   outcome. Its `lifecycle` is a derived cache: every reducer
///   transition ends in `syncPaneLifecycles()`, the single function that
///   derives lifecycles from phases, so at rest a lifecycle can never
///   contradict its phase.
/// - The emulator objects stay in `WorkspaceTUIModel.emulatorSlots`
///   (live objects under the model lock, explicitly the runtime's).
/// - This record holds everything else the reducer decides on per pane.
struct PaneRuntime: Equatable, Sendable {
    /// Launching XOR attached, plus the resting phases that retain a
    /// stale terminal (failed, missing, disconnected). See `PanePhase`.
    var phase: PanePhase
    /// Typeahead held while the input lease is in flight. The binding
    /// pins the exact runtime generation the bytes belong to.
    var input: WorkspaceTUIState.PendingPaneInput? = nil
    /// Desired lease: the binding this client last acquired input for.
    /// A successful acquire RPC is authoritative over queued lease
    /// notifications. This is the desired half of the desired-vs-observed
    /// lease split; the observed half is the `InputLease` inside the
    /// phase's terminal. The split is load-bearing (a contended claimant
    /// holds a claim while rendering read-only) and is preserved: see
    /// `windowNoticeResizesObserverEmulatorOnly` and
    /// `contendedClaimantIgnoresWindowNotice`.
    var leaseClaim: PaneBindingKey? = nil
    /// Desired leases held when the host went away. Reconnect restores
    /// these (attach) or observes after reconciling against inventory.
    /// Only meaningful while disconnected.
    var preDisconnectLease: PaneBindingKey? = nil
    /// Viewport anchor (lines above live output) plus the binding
    /// generation captured when scroll mode opened. One struct so an
    /// anchor can never lack its generation. Nil when not scrolling;
    /// anchor 0 plus no generation is observably identical to nil.
    var scroll: ScrollPosition? = nil
    /// One-shot retries armed for the next tick. Both arms are reachable
    /// at once (an observer pane that overflowed and then heard a free
    /// notice), so this is a set, not an option: dropping either arm
    /// would change the tick's RPC sequence. See
    /// `overflowedObserverRetriesAcquireAndResubscribe`.
    var retries: Set<RetryKind> = []
    /// In-flight replay batch, set by replay-begin and cleared by the
    /// matching replay-end.
    var replayBatch: UUID? = nil
    /// The replay was truncated: only recent output is on screen.
    var recentOutputOnly: Bool = false
}

extension PaneRuntime {
    /// The terminal slot every read path touches: the displayed terminal
    /// while a replacement attaches, the candidate while a fresh launch
    /// attaches, or the live/stale terminal otherwise. Nil when the pane
    /// has no terminal in any phase (fresh intent, missing without a
    /// stale terminal). Writes route through
    /// `WorkspaceTUIState.updateTerminal` / `setTerminal`.
    var terminal: WorkspaceTUIState.AttachedTerminal? {
        switch phase {
        case .launching(let detail):
            detail.previous ?? detail.candidate?.terminal
        case .attached(let terminal),
             .failed(let terminal?),
             .missing(let terminal?),
             .disconnected(let terminal):
            terminal
        case .failed(nil), .missing(nil):
            nil
        }
    }
}

/// One pane's position in the launch/attach lifecycle.
///
/// A pane is never launching and attached at once: the replacement
/// candidate lives inside `.launching` next to the still-displayed
/// previous terminal, and the attach completion promotes exactly one of
/// them. The resting cases (`.failed`, `.missing`, `.disconnected`)
/// retain the stale terminal whose output stays on screen: input gating,
/// navigator retry, pane titles, and relaunch blocking all read it, so
/// dropping it would change observable behavior. For that reason the
/// phase has five cases rather than two; the launching/attached
/// exclusivity the ticket requires still holds.
enum PanePhase: Equatable, Sendable {
    /// A launch is intended or a replacement/fresh attach is in flight.
    /// Derives `.launching` before the launch RPC returns, `.attaching`
    /// while the candidate awaits its attach.
    case launching(LaunchDetail)
    /// A live terminal. Derives `.running` or `.exited` from the
    /// terminal's running flag.
    case attached(WorkspaceTUIState.AttachedTerminal)
    /// A launch or attach failed; the stale terminal (when one exists)
    /// keeps its output on screen. Derives `.launchFailed`.
    case failed(stale: WorkspaceTUIState.AttachedTerminal?)
    /// The host has no such runtime; the stale terminal (when one
    /// exists) stays for navigator retry. Derives `.missing`.
    case missing(stale: WorkspaceTUIState.AttachedTerminal?)
    /// The host went away; the stale terminal keeps its output until
    /// reconnect reconciles. Derives `.disconnected`. Only present while
    /// the global lifecycle is `.disconnected`.
    case disconnected(stale: WorkspaceTUIState.AttachedTerminal)
}

extension PanePhase {
    /// The replacement/fresh candidate awaiting attach, if any. The
    /// launch gate admits a submit unless a candidate is already in
    /// flight, which is the phase form of the old pending-launch check.
    var candidate: WorkspaceTUIState.PendingLaunch? {
        if case .launching(let detail) = self {
            detail.candidate
        } else {
            nil
        }
    }
}

/// A launch in flight: the still-displayed previous terminal plus the
/// candidate awaiting attach.
///
/// - Fresh intent (split, new tab, run command): both nil. The launch
///   gate admits exactly one query; the success path fills the
///   candidate.
/// - Relaunch intent on a pane with output: previous set, candidate
///   nil. The old output stays until the replacement lands.
/// - Attach in flight: candidate set (previous set for a replacement,
///   nil for a fresh launch). A duplicate submit is dropped.
struct LaunchDetail: Equatable, Sendable {
    /// Terminal displayed while the replacement attaches. Nil for fresh
    /// launches, which have no previous output.
    var previous: WorkspaceTUIState.AttachedTerminal?
    /// Candidate awaiting its attach, with the binding the completion
    /// must match. Nil until the launch RPC returns.
    var candidate: WorkspaceTUIState.PendingLaunch?
}

/// Scroll viewport: lines above live output plus the binding generation
/// captured when scroll mode opened, so a rebind cancels the mode
/// instead of scrolling a new runtime's history. Atomic by
/// construction: an anchor without its generation is unrepresentable.
struct ScrollPosition: Equatable, Sendable {
    /// Lines above live output, 0 when live. The top sentinel means
    /// oldest retained; views clamp it to the emulator's history depth.
    var anchor: Int
    /// Binding generation scroll mode opened under.
    var generation: UInt64
}

/// One-shot retry arms for the tick. See `PaneRuntime.retries`.
enum RetryKind: Hashable, Sendable {
    /// Re-acquire a read-only lease.
    case acquire
    /// Re-attach after a resubscribe raced the host-side drop.
    case subscribe
}
