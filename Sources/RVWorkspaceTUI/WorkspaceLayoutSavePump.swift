#if os(macOS)
import Foundation

/// Serializes layout commits and flushes once more when the TUI exits.
/// The layout session and its writer lock live for the entire pump
/// lifetime. Focus-only moves commit on the background worker; durable
/// changes (bindings, structure) commit synchronously on the reducing
/// thread through `saveSync`, so a binding visible on screen is already
/// on disk even if the process is SIGKILLed before the next frame.
public final class WorkspaceLayoutSavePump: @unchecked Sendable {
    private let model: WorkspaceTUIModel
    private let layout: WorkspaceLayoutSession
    private let onFailure: @Sendable (String) -> Void
    private let lock = NSLock()
    /// Serializes every commit: the worker thread, `saveSync`, and `stop`
    /// all funnel through it. Never held while calling into the model.
    private let saverLock = NSLock()
    private let finished = DispatchGroup()
    private let kicked = DispatchSemaphore(value: 0)
    private var started = false
    private var stopping = false
    private var lastError: String?
    private var lastSaved: WorkspaceView
    private var unusable = false

    public init(model: WorkspaceTUIModel, layout: WorkspaceLayoutSession,
                onFailure: @escaping @Sendable (String) -> Void) {
        self.model = model
        self.layout = layout
        self.onFailure = onFailure
        self.lastSaved = layout.view
    }

    public func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        finished.enter()
        lock.unlock()
        let worker = Thread { [self] in
            defer { finished.leave() }
            run()
        }
        worker.name = "rv-workspace-layout-save"
        worker.start()
    }

    /// Wakes the saver so a just-reduced view change commits without
    /// waiting for the next poll tick. Safe to call from any thread; each
    /// kick wakes one pass, and an unchanged view makes the pass a no-op.
    public func kick() {
        kicked.signal()
    }

    /// Commits one durable view on the calling thread. The model calls
    /// this synchronously from every reduce that changes bindings or
    /// structure, outside the model lock; it serializes against the
    /// worker through the saver lock and never calls back into the model.
    public func saveSync(_ view: WorkspaceView) {
        commitIfChanged(view)
    }

    /// Waits for the final commit. A returned error means the view may not be
    /// durable; callers must show it after SwiftTUI restores the local tty.
    @discardableResult
    public func stop() -> String? {
        lock.lock()
        stopping = true
        let didStart = started
        lock.unlock()
        kicked.signal()
        if didStart {
            finished.wait()
        } else {
            saveIfChanged()
        }
        saverLock.lock()
        defer { saverLock.unlock() }
        return lastError
    }

    private func run() {
        while true {
            lock.lock()
            let shouldStop = stopping
            lock.unlock()
            if shouldStop { break }
            saveIfChanged()
            // The 100ms tick stays as a backstop; kicks from the model
            // already woke every pass a view change needed.
            _ = kicked.wait(timeout: .now() + 0.1)
        }
        saveIfChanged()
    }

    private func saveIfChanged() {
        // Snapshot outside the saver lock: the model lock must never nest
        // inside it, and saveSync never takes the model lock at all.
        commitIfChanged(model.snapshotView())
    }

    /// Compares and commits under the saver lock. The failure notice fires
    /// outside the lock; the model re-reduces it without deadlocking.
    private func commitIfChanged(_ view: WorkspaceView) {
        saverLock.lock()
        guard !unusable else {
            saverLock.unlock()
            return
        }
        guard view != lastSaved || layout.revision == 0 else {
            saverLock.unlock()
            return
        }
        do {
            try layout.save(view)
            lastSaved = view
            lastError = nil
            saverLock.unlock()
        } catch {
            let message = "Workspace layout could not be saved: \(error)"
            let changed = lastError != message
            lastError = message
            if layout.requiresReopen { unusable = true }
            saverLock.unlock()
            if changed { onFailure(message) }
        }
    }
}
#endif
