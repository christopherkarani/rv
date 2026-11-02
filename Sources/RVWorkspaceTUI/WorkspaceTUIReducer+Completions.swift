import Foundation
import RVDomain

// RPC completion transitions: write, acquire, release, resize, attach.
extension WorkspaceTUIReducer {
    static func reduceWriteCompleted(
        binding: PaneBindingKey,
        bytes: Data,
        outcome: TUIRPCOutcome,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        // The terminal worker drains in-flight writes after detach; their
        // completions reduce here and must leave detached state alone.
        guard next.lifecycle != .detached,
              next.bindingKey(for: binding.pane) == binding else { return }
        switch outcome {
        case .busy:
            presentationChanged = presentationChanged
                || next.terminal(for: binding.pane)?.state.lease != .readOnly
            next.updateTerminal(binding.pane) { $0.state.lease = .readOnly }
            next.dropLeaseClaim(binding)
            // The bytes never reached the runtime. Hold them as
            // typeahead (bounded) instead of dropping the keystroke:
            // the next grant flushes them, so input across a wedge
            // (overflow drop, lost lease race) is delayed, not lost.
            if next.queuePendingInput(bytes, for: binding) {
                presentationChanged = true
            }
            // A refused write on a subscribed pane may mean the host
            // silently dropped the subscription (overflow) rather than
            // contention. One acquire distinguishes: unavailable
            // resubscribes, busy stays quiet. Contended observers never
            // reach here: without a lease their input queues as
            // typeahead instead of sending.
            if next.lifecycle == .connected,
               next.terminal(for: binding.pane)?.state.running == true,
               next.terminal(for: binding.pane)?.state.subscribed == true {
                next.panes[binding.pane, default: PaneRuntime(phase: .missing(stale: nil))]
                    .retries.insert(.acquire)
            }
        case .disconnected:
            Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
            if next.lifecycle == .connected {
                next.lifecycle = .disconnected
            }
        case .ok:
            break
        case .unavailable:
            // The runtime is gone; in-flight bytes died with it. The
            // pane exit covers that, so feedback only fires when the
            // pane still claims running (a genuinely surprising loss).
            if next.terminal(for: binding.pane)?.state.running == true {
                next.feedback = "Terminal unavailable; input dropped"
                next.feedbackTicks = 60
                presentationChanged = true
            }
        case .rejected:
            if bytes.count > TerminalInputChunks.maximumTotalBytes {
                next.feedback = "Input exceeds 1 MiB; rejected"
            } else {
                next.feedback = "Write rejected; input dropped"
            }
            next.feedbackTicks = 60
            presentationChanged = true
        }
    }

    static func reduceAcquireCompleted(
        binding: PaneBindingKey,
        outcome: TUIRPCOutcome,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        switch outcome {
        case .ok:
            // Release-after-acquire: a success that arrives after the
            // terminal moved on (or detached) must release the orphaned
            // lease instead of claiming it.
            let stillAvailable = next.lifecycle == .connected
                && next.bindingKey(for: binding.pane) == binding
                && next.terminal(for: binding.pane)?.state.running == true
            if stillAvailable {
                if next.terminal(for: binding.pane)?.state.lease != .owned {
                    presentationChanged = true
                }
                next.updateTerminal(binding.pane) { $0.state.lease = .owned }
                next.panes[binding.pane, default: PaneRuntime(phase: .missing(stale: nil))]
                    .leaseClaim = binding
                if let bytes = next.takePendingInput(for: binding) {
                    effects.append(.write(binding: binding, bytes: bytes))
                }
            } else if next.lifecycle != .connected
                || next.panes.values.contains(where: { $0.leaseClaim?.runtime == binding.runtime }) == false {
                effects = [.release(runtime: binding.runtime)]
            }
        case .busy:
            guard next.lifecycle != .detached else { break }
            if next.bindingKey(for: binding.pane) == binding {
                if next.terminal(for: binding.pane)?.state.lease != .readOnly {
                    presentationChanged = true
                }
                next.updateTerminal(binding.pane) { $0.state.lease = .readOnly }
            }
        case .unavailable, .rejected:
            guard next.lifecycle != .detached else { break }
            guard next.bindingKey(for: binding.pane) == binding else { break }
            if next.terminal(for: binding.pane)?.state.lease != .readOnly {
                presentationChanged = true
            }
            next.updateTerminal(binding.pane) { $0.state.lease = .readOnly }
            // Acquire fails unavailable only when the host has no
            // subscription for this client (a silent overflow drop) or
            // the runtime is gone. A pane that believes it is subscribed
            // re-attaches; behind a gone runtime the attach outcome (or
            // its exited notice) converges instead of looping.
            if next.lifecycle == .connected,
               next.terminal(for: binding.pane)?.state.running == true,
               next.terminal(for: binding.pane)?.state.subscribed == true {
                next.updateTerminal(binding.pane) { $0.state.subscribed = false }
                next.panes[binding.pane]?.retries.remove(.subscribe)
                effects.append(.attach(binding: binding, context: .resubscribe))
                presentationChanged = true
            }
        case .disconnected:
            guard next.lifecycle != .detached,
                  next.bindingKey(for: binding.pane) == binding else { break }
            Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
            if next.lifecycle == .connected {
                next.lifecycle = .disconnected
            }
        }
    }

    static func reduceReleaseInputCompleted(
        binding: PaneBindingKey,
        outcome: TUIRPCOutcome,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle != .detached,
              next.bindingKey(for: binding.pane) == binding else { return }
        switch outcome {
        case .disconnected:
            Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
            if next.lifecycle == .connected {
                next.lifecycle = .disconnected
            }
        case .ok, .busy, .unavailable, .rejected:
            // The host is the source of truth; any definitive reply
            // drops the local claim. Later `.inputOwner` events re-sync.
            presentationChanged = presentationChanged
                || next.terminal(for: binding.pane)?.state.lease != .readOnly
            next.updateTerminal(binding.pane) { $0.state.lease = .readOnly }
            next.dropLeaseClaim(binding)
        }
    }

    static func reduceResizeCompleted(
        binding: PaneBindingKey,
        rows: Int,
        columns: Int,
        outcome: TUIRPCOutcome,
        now: Date,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        // As with writes: a resize that races detach reduces after the
        // lifecycle committed and must not touch detached state.
        guard next.lifecycle != .detached,
              next.bindingKey(for: binding.pane) == binding else { return }
        switch outcome {
        case .busy:
            // The host rejected the resize: another client holds input.
            // Downgrade like a contended write, and un-apply the failed
            // size so a later tick retries it after the lease returns.
            presentationChanged = presentationChanged
                || next.terminal(for: binding.pane)?.state.lease != .readOnly
            next.updateTerminal(binding.pane) {
                $0.state.lease = .readOnly
                $0.resize.nack(rows: rows, columns: columns, now: now)
            }
            next.dropLeaseClaim(binding)
        case .disconnected:
            Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
            if next.lifecycle == .connected {
                next.lifecycle = .disconnected
            }
        case .unavailable:
            Self.applyRuntimeExited(runtime: binding.runtime, to: &next, presentationChanged: &presentationChanged)
        case .ok, .rejected:
            // A rejected resize carries an invalid request, never a lost
            // lease; retrying it would loop. It stays counted as sent.
            break
        }
    }

    static func reduceAttachCompleted(
        binding: PaneBindingKey,
        context: TUIAttachContext,
        outcome: SessionAttachOutcome,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        if context == .launch,
           case .launching(let detail)? = next.panes[binding.pane]?.phase,
           let candidate = detail.candidate, candidate.binding == binding,
           let previousTerminal = detail.previous {
            // Replacement only: a fresh launch (no previous terminal)
            // flows to the main branch below, exactly as before.
            completeReplacementAttach(
                binding: binding, outcome: outcome, candidate: candidate, previousTerminal: previousTerminal,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
            return
        }
        switch outcome {
        case .owned:
            landOwnedAttach(
                binding: binding, context: context,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .readOnly:
            landReadOnlyAttach(
                binding: binding, context: context,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        case .unavailable, .disconnected:
            failAttach(
                binding: binding, context: context, outcome: outcome,
                to: &next, effects: &effects, presentationChanged: &presentationChanged
            )
        }
    }

    private static func completeReplacementAttach(
        binding: PaneBindingKey,
        outcome: SessionAttachOutcome,
        candidate: WorkspaceTUIState.PendingLaunch,
        previousTerminal: WorkspaceTUIState.AttachedTerminal,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        switch outcome {
        case .owned, .readOnly:
            let previousKey = next.bindingKey(for: binding.pane)
            let wasSubscribed = previousTerminal.state.subscribed
            next.assignTerminal(candidate.terminal, to: binding.pane)
            next.updateTerminal(binding.pane) {
                $0.state.subscribed = true
                $0.state.lease = outcome == .owned ? .owned : .readOnly
            }
            next.updatePane(binding.pane) { $0.lastOutcome = nil }
            if outcome == .owned {
                next.panes[binding.pane, default: PaneRuntime(phase: .missing(stale: nil))]
                    .leaseClaim = binding
            }
            if let previousKey {
                // assignTerminal already dropped the old claim, so
                // the old post-assign membership check could never
                // fire: only a subscribed previous runtime is
                // released. (The navigator path checks before
                // assigning and differs; both keep their
                // historical behavior.)
                if wasSubscribed {
                    effects.append(.release(runtime: previousKey.runtime))
                }
                effects.append(.dropEmulator(binding: previousKey))
            }
            let size = candidate.terminal.resize.effectiveSize
                ?? (rows: next.initialRows, columns: next.initialColumns)
            effects.append(.createEmulator(
                binding: binding, rows: size.rows, columns: size.columns
            ))
        case .unavailable, .disconnected:
            next.panes[binding.pane]?.phase = .failed(stale: previousTerminal)
            next.updatePane(binding.pane) {
                $0.lastOutcome = .launchFailed("Terminal attach failed")
            }
            if outcome == .disconnected {
                Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
                next.lifecycle = .disconnected
            }
        }
        presentationChanged = true
    }

    private static func landOwnedAttach(
        binding: PaneBindingKey,
        context: TUIAttachContext,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        // Release-after-acquire: a grant that arrives after the
        // terminal moved on (or detached) must release the orphaned
        // lease instead of claiming it.
        let stillAvailable = next.lifecycle == .connected
            && next.bindingKey(for: binding.pane) == binding
            && next.terminal(for: binding.pane)?.state.running == true
        if stillAvailable {
            if next.terminal(for: binding.pane)?.state.lease != .owned {
                presentationChanged = true
            }
            next.updateTerminal(binding.pane) {
                $0.state.subscribed = true
                $0.state.lease = .owned
            }
            if context == .resubscribe || context == .resubscribeRetry {
                next.updateTerminal(binding.pane) { $0.state.overflowed = false }
                next.panes[binding.pane]?.retries.remove(.subscribe)
                presentationChanged = true
            }
            next.landAttach(for: binding)
            next.panes[binding.pane, default: PaneRuntime(phase: .missing(stale: nil))]
                .leaseClaim = binding
            if let bytes = next.takePendingInput(for: binding) {
                effects.append(.write(binding: binding, bytes: bytes))
            }
        } else if next.panes.values.contains(where: { $0.leaseClaim?.runtime == binding.runtime }) == false {
            effects = [.release(runtime: binding.runtime)]
        }
    }

    private static func landReadOnlyAttach(
        binding: PaneBindingKey,
        context: TUIAttachContext,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        // A contended attach still subscribes; the lease stays
        // read-only until the host reports it free. Stale grants
        // (or detached ones) claim nothing.
        guard next.lifecycle == .connected,
              next.bindingKey(for: binding.pane) == binding else { return }
        if context == .probe {
            // Probe success means the host had silently dropped us;
            // the subscription is live again. Lease claimants keep
            // their claim and reclaim on tick (confirming rather
            // than flopping the lease); observers are already home.
            if next.panes[binding.pane]?.leaseClaim == binding {
                next.panes[binding.pane, default: PaneRuntime(phase: .missing(stale: nil))]
                    .retries.insert(.acquire)
            }
            presentationChanged = true
            return
        }
        if next.terminal(for: binding.pane)?.state.lease != .readOnly {
            presentationChanged = true
        }
        next.updateTerminal(binding.pane) {
            $0.state.subscribed = true
            $0.state.lease = .readOnly
        }
        if context == .resubscribe || context == .resubscribeRetry {
            next.updateTerminal(binding.pane) { $0.state.overflowed = false }
            next.panes[binding.pane]?.retries.remove(.subscribe)
            presentationChanged = true
        }
        next.landAttach(for: binding)
    }

    private static func failAttach(
        binding: PaneBindingKey,
        context: TUIAttachContext,
        outcome: SessionAttachOutcome,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        // Failure handling mutates the terminal (unavailable titles,
        // launcher fallback, emulator drops); detached state is final.
        guard next.lifecycle != .detached,
              next.bindingKey(for: binding.pane) == binding else { return }
        if outcome == .disconnected {
            Self.applyDisconnect(to: &next, presentationChanged: &presentationChanged)
            if next.lifecycle == .connected {
                next.lifecycle = .disconnected
            }
        }
        switch context {
        case .connect:
            if outcome == .unavailable {
                if next.terminal(for: binding.pane)?.state.lease != .readOnly {
                    presentationChanged = true
                }
                next.updateTerminal(binding.pane) {
                    $0.state.subscribed = false
                    $0.state.lease = .readOnly
                }
            }
        case .ensure:
            presentationChanged = presentationChanged
                || next.terminal(for: binding.pane)?.state.lease != .readOnly
            next.updateTerminal(binding.pane) {
                $0.state.title += " (unavailable)"
                $0.state.lease = .readOnly
                $0.state.subscribed = false
            }
        case .launch:
            failLaunchAttach(binding: binding, to: &next, presentationChanged: &presentationChanged)
        case .reconnect:
            if let slot = next.terminal(for: binding.pane) {
                next.panes[binding.pane]?.phase = .missing(stale: slot)
            }
            presentationChanged = true
        case .resubscribe:
            // The drop races this RPC across connections; the tick
            // retries until the subscribe lands. The lease is left
            // alone: a stale owned claim renders behind the
            // skipped-output indicator and self-heals on send, while
            // read-only would spam acquires that fail closed without
            // a subscription.
            if outcome == .unavailable {
                next.panes[binding.pane, default: PaneRuntime(phase: .missing(stale: nil))]
                    .retries.insert(.subscribe)
                presentationChanged = true
            }
        case .resubscribeRetry:
            // One-shot spent. A repeat failure means the runtime is
            // gone; staying quiet instead of RPC-spamming the tick.
            break
        case .probe:
            // Probe failure means the existing subscription is
            // healthy (subscribe refused a duplicate). No-op.
            break
        }
    }

    private static func failLaunchAttach(
        binding: PaneBindingKey,
        to next: inout WorkspaceTUIState,
        presentationChanged: inout Bool
    ) {
        // A stale launch failure (for an older binding while a
        // newer candidate is in flight) must not clobber the
        // candidate: the in-flight attach still decides. Only
        // failures for the live candidate, or with no
        // candidate, fail the pane.
        switch next.panes[binding.pane]?.phase {
        case .launching(let detail) where detail.candidate != nil
            && detail.candidate?.binding != binding:
            break
        default:
            next.updatePane(binding.pane) {
                $0.lastOutcome = .launchFailed("Terminal attach failed")
            }
            if case .launching(let detail)? = next.panes[binding.pane]?.phase,
               detail.previous == nil, detail.candidate?.binding == binding {
                next.panes[binding.pane]?.phase = .failed(stale: detail.candidate?.terminal)
            } else if let slot = next.terminal(for: binding.pane) {
                next.panes[binding.pane]?.phase = .failed(stale: slot)
            } else {
                next.panes[binding.pane]?.phase = .failed(stale: nil)
            }
        }
        if next.activePaneID == binding.pane, next.lifecycle == .connected {
            next.mode = .launcher
        }
        presentationChanged = true
    }

    private static func applyRuntimeExited(
        runtime: UUID,
        to next: inout WorkspaceTUIState,
        presentationChanged: inout Bool
    ) {
        guard let pane = next.paneID(for: runtime) else { return }
        var changed = next.terminal(for: pane)?.state.running != false
            || next.terminal(for: pane)?.state.exitStatus != nil
            || next.terminal(for: pane)?.state.lease != .released
        next.markExited(pane, status: nil)
        if let binding = next.bindingKey(for: pane) {
            next.dropLeaseClaim(binding)
        }
        if next.activePaneID == pane, next.mode != .launcher {
            next.mode = .launcher
            changed = true
        }
        presentationChanged = presentationChanged || changed
    }
}
