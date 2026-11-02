import Foundation
import RVDomain

// Input, host-event, size, and tick transitions.
extension WorkspaceTUIReducer {
    static func reduceSendDue(
        binding: PaneBindingKey,
        bytes: Data,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        // Re-gate on the terminal worker: the lease may have moved since
        // the key was pressed or the emulator replied.
        guard next.lifecycle == .connected, next.shouldExit == false,
              next.activeBindingKey == binding,
              let terminal = next.terminal,
              terminal.state.running else { return }
        guard next.panes[binding.pane]?.leaseClaim == binding else {
            // The attach is still in flight; hold the keystrokes as
            // typeahead instead of dropping them on the floor.
            if next.queuePendingInput(bytes, for: binding) {
                presentationChanged = true
            }
            return
        }
        effects = [.write(binding: binding, bytes: bytes)]
    }

    static func reduceEmulatorSendDue(
        binding: PaneBindingKey,
        bytes: Data,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .connected, next.shouldExit == false,
              next.bindingKey(for: binding.pane) == binding,
              next.terminal(for: binding.pane)?.state.running == true else { return }
        guard next.panes[binding.pane]?.leaseClaim == binding else {
            if next.queuePendingInput(bytes, for: binding) {
                presentationChanged = true
            }
            return
        }
        effects = [.write(binding: binding, bytes: bytes)]
    }

    static func reduceHostEvents(
        _ events: [WorkspaceTUIEvent],
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .connected else { return }
        for event in events {
            Self.applyHostEvent(event, to: &next, effects: &effects, presentationChanged: &presentationChanged)
        }
    }

    static func reduceEmulatorResponded(
        binding: PaneBindingKey,
        responses: [Data],
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .connected, responses.isEmpty == false else { return }
        guard next.panes[binding.pane]?.leaseClaim == binding,
              next.bindingKey(for: binding.pane) == binding,
              let terminal = next.terminal(for: binding.pane),
              terminal.state.lease == .owned else { return }
        effects = responses.map { response in
            next.activeBindingKey == binding
                ? .queueSend(binding: binding, bytes: response)
                : .queueEmulatorResponse(binding: binding, bytes: response)
        }
    }

    static func reduceSizeNoted(
        rows: Int,
        columns: Int,
        now: Date,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        // Called from the render pass: records geometry only, never an RPC.
        guard next.lifecycle == .connected, let pane = next.activePaneID,
              next.terminal(for: pane) != nil else { return }
        // Resize-only: the old spelling wrote back through the
        // terminal setter, which re-assigned the pane and wiped queued
        // typeahead on every render pass. Pane-scoped notes always
        // took this direct path; now both do.
        next.updateTerminal(pane) { $0.resize.record(rows: rows, columns: columns, now: now) }
        next.viewSize = .init(rows: rows + 2, columns: columns + 2)
    }

    static func reducePaneSizeNoted(
        pane: PaneID,
        rows: Int,
        columns: Int,
        now: Date,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle == .connected, next.terminal(for: pane) != nil else { return }
        next.updateTerminal(pane) { $0.resize.record(rows: rows, columns: columns, now: now) }
    }

    static func reduceTick(
        now: Date,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        guard next.lifecycle != .detached else { return }
        if next.feedbackTicks > 0 {
            next.feedbackTicks -= 1
            if next.feedbackTicks == 0 {
                next.feedback = nil
                presentationChanged = true
            }
        }
        if next.lifecycle == .disconnected {
            Self.tickReconnect(now: now, to: &next, effects: &effects, presentationChanged: &presentationChanged)
            return
        }
        guard next.lifecycle == .connected else { return }
        flushVisibleResizes(now: now, to: &next, effects: &effects, presentationChanged: &presentationChanged)
        retryPendingRecoveries(to: &next, effects: &effects)
        probeSubscriptions(now: now, to: &next, effects: &effects)
    }

    private static func flushVisibleResizes(
        now: Date,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        let visible = next.view.activeTab.map { tab in
            tab.zoomedPaneID.map { [$0] } ?? tab.tree.leafIDs
        } ?? []
        for pane in visible {
            // Ownership validation runs before the coalescer: an
            // observer must not promote a size it cannot send, and
            // its emulator keeps the runtime's actual dimensions
            // until this client holds the lease.
            guard next.terminal(for: pane)?.state.lease == .owned,
                  var slot = next.terminal(for: pane),
                  let size = slot.resize.flush(now: now),
                  let binding = next.bindingKey(for: pane) else { continue }
            // Only a flushed size writes back: a nil flush may still
            // have cleared a settled pending entry, which stays
            // discarded exactly as before.
            next.setTerminal(slot, for: pane)
            presentationChanged = true
            effects.append(.resizeEmulator(binding: binding, rows: size.rows, columns: size.columns))
            effects.append(.resize(binding: binding, rows: size.rows, columns: size.columns))
        }
    }

    private static func retryPendingRecoveries(
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect]
    ) {
        let acquirePanes = next.panes.keys.filter {
            next.panes[$0]?.retries.contains(.acquire) == true
        }
        for pane in acquirePanes {
            guard next.terminal(for: pane)?.state.lease == .readOnly,
                  let binding = next.bindingKey(for: pane) else { continue }
            effects.append(.acquire(binding: binding))
        }
        for pane in acquirePanes {
            next.panes[pane]?.retries.remove(.acquire)
        }
        let subscribePanes = next.panes.keys.filter {
            next.panes[$0]?.retries.contains(.subscribe) == true
        }
        for pane in subscribePanes {
            guard let binding = next.bindingKey(for: pane),
                  next.terminal(for: pane)?.state.running == true,
                  next.terminal(for: pane)?.state.subscribed == false else { continue }
            effects.append(.attach(binding: binding, context: .resubscribeRetry))
        }
        for pane in subscribePanes {
            next.panes[pane]?.retries.remove(.subscribe)
        }
    }

    private static func probeSubscriptions(
        now: Date,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect]
    ) {
        let probeDue: Bool
        if let lastProbe = next.lastSubscriptionProbeAt {
            probeDue = now.timeIntervalSince(lastProbe) >= WorkspaceTUIState.subscriptionProbeInterval
        } else {
            probeDue = true
        }
        if probeDue {
            next.lastSubscriptionProbeAt = now
            for paneID in next.view.panes.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                guard let binding = next.bindingKey(for: paneID),
                      next.terminal(for: paneID)?.state.running == true,
                      next.terminal(for: paneID)?.state.subscribed == true else { continue }
                effects.append(.observe(binding: binding, context: .probe))
            }
        }
    }

    private static func applyHostEvent(
        _ event: WorkspaceTUIEvent,
        to next: inout WorkspaceTUIState,
        effects: inout [TUIRuntimeEffect],
        presentationChanged: inout Bool
    ) {
        switch event {
        case .replayBegin(let runtime, let batch, let truncated, _):
            guard let pane = next.paneID(for: runtime),
                  let binding = next.bindingKey(for: pane),
                  let terminal = next.terminal(for: pane) else { return }
            next.panes[pane]?.replayBatch = batch
            next.panes[pane]?.recentOutputOnly = truncated
            let size = terminal.resize.effectiveSize
                ?? (rows: next.initialRows, columns: next.initialColumns)
            effects.append(.createEmulator(binding: binding, rows: size.rows, columns: size.columns))
            presentationChanged = true
        case .replayEnd(let runtime, let batch):
            guard let pane = next.paneID(for: runtime),
                  next.panes[pane]?.replayBatch == batch else { return }
            next.panes[pane]?.replayBatch = nil
            presentationChanged = true
        case .bytes(let runtime, let data):
            guard let pane = next.paneID(for: runtime),
                  let binding = next.bindingKey(for: pane) else { return }
            guard data.isEmpty == false else { return }
            effects.append(.feedEmulator(binding: binding, data: data))
            presentationChanged = true
        case .overflow(let runtime):
            guard let pane = next.paneID(for: runtime),
                  let binding = next.bindingKey(for: pane),
                  next.terminal(for: pane)?.state.running == true else { return }
            if next.terminal(for: pane)?.state.overflowed != true {
                next.updateTerminal(pane) { $0.state.overflowed = true }
            }
            // The host dropped this subscription; without a resubscribe the
            // pane goes dark and input acquire fails closed. The overflow
            // notice is already on the wire, so the same client id may
            // subscribe again immediately; a cross-connection race lands in
            // the tick retry set through the failure branch below.
            next.updateTerminal(pane) { $0.state.subscribed = false }
            next.panes[pane]?.retries.remove(.subscribe)
            effects.append(.attach(binding: binding, context: .resubscribe))
            presentationChanged = true
        case .window(let runtime, let rows, let columns):
            // Actual PTY dimensions, published by the owner's resize. Only
            // observers apply them: the owner drives its emulator from its
            // own coalescer and must not have it rewritten underneath.
            // The desired claim (not the observed lease) decides: a
            // contended claimant keeps its size while it re-acquires.
            guard let pane = next.paneID(for: runtime),
                  let binding = next.bindingKey(for: pane),
                  next.panes[pane]?.leaseClaim != binding,
                  next.terminal(for: pane)?.state.running == true else { return }
            effects.append(.resizeEmulator(binding: binding, rows: rows, columns: columns))
            presentationChanged = true
        case .exited(let runtime, let status):
            guard let pane = next.paneID(for: runtime) else { return }
            if next.terminal(for: pane)?.state.running != false
                || next.terminal(for: pane)?.state.exitStatus != status
                || next.terminal(for: pane)?.state.lease != .released {
                presentationChanged = true
            }
            next.markExited(pane, status: status)
            next.updatePane(pane) { $0.lastOutcome = .exited(status) }
            if let binding = next.bindingKey(for: pane) {
                next.dropLeaseClaim(binding)
            }
            // The final output stays on screen; the launcher offers a
            // replacement runtime and number keys select it directly.
            if next.activePaneID == pane, next.mode != .launcher {
                next.mode = .launcher
                presentationChanged = true
            }
        case .inputOwner(let runtime, let owned):
            guard let pane = next.paneID(for: runtime),
                  let binding = next.bindingKey(for: pane) else { return }
            if owned {
                // The host broadcasts only that an owner exists, not which
                // client owns it. Only our successful acquire RPC grants
                // local write authority.
                if next.panes[pane]?.leaseClaim != binding {
                    presentationChanged = presentationChanged
                        || next.terminal(for: pane)?.state.lease != .readOnly
                    next.updateTerminal(pane) { $0.state.lease = .readOnly }
                }
            } else {
                // Notifications do not carry a lease generation. A queued
                // release from an earlier epoch may arrive after a later
                // acquire succeeded, so the successful acquire is
                // authoritative while this client still claims ownership.
                guard next.panes[pane]?.leaseClaim != binding else { return }
                presentationChanged = presentationChanged
                    || next.terminal(for: pane)?.state.lease != .readOnly
                next.updateTerminal(pane) { $0.state.lease = .readOnly }
                if next.terminal(for: pane)?.state.running == true {
                    next.panes[pane, default: PaneRuntime(phase: .missing(stale: nil))]
                        .retries.insert(.acquire)
                }
            }
        }
    }
}
