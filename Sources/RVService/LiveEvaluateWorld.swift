import Foundation
import RVDomain
import RVHistory
import RVPolicy

/// Owns Policy-gate inputs for a live evaluate: session door, allow-once
/// store, home, clock, and the T13 lazy allowlist.
package struct LiveEvaluateWorld: Sendable {
    package let store: AllowOnceStore
    package let home: HomeDirectory?

    private let gated: GatedEvaluate
    private let clock: @Sendable () -> Date
    private let allowlist: @Sendable (WorkingDirectory?, Date) -> AllowlistSnapshot

    /// Creates a live world. Nil home is day-one walk. Missing store uses
    /// `$HOME/.config/rv` when home is present, else a unique ephemeral directory.
    ///
    /// `allowlist` is a test seam (counting loader). Production constructs
    /// `AllowlistStore(baseDirectory: store.baseDirectory)` here; T13 skip stays
    /// in `GatedEvaluate.gated`.
    package init(
        home: HomeDirectory?,
        store: AllowOnceStore? = nil,
        gated: GatedEvaluate? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        allowlist: (@Sendable (WorkingDirectory?, Date) -> AllowlistSnapshot)? = nil
    ) {
        let resolvedStore = store ?? Self.defaultStore(home: home)
        let baseDirectory = resolvedStore.baseDirectory
        self.home = home
        self.store = resolvedStore
        self.gated = gated ?? EvaluationWorld.assemble(
            home: home,
            snapshots: nil,
            catalog: nil
        )
        self.clock = clock
        self.allowlist = allowlist ?? { cwd, now in
            AllowlistStore(baseDirectory: baseDirectory)
                .loadUserSnapshot(workspacePath: cwd.map(\.rawValue), now: now)
        }
    }

    /// Peek shows a matching grant without consuming it.
    package func peek(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        host: LedgerHost = .tty
    ) async -> EvaluationResult {
        await run(.peek, command: command, cwd: cwd, host: host)
    }

    /// Apply spends a matching grant.
    package func apply(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        host: LedgerHost = .tty
    ) async -> EvaluationResult {
        await run(.apply, command: command, cwd: cwd, host: host)
    }

    /// Host Ask plant+spend this turn.
    package func spend(
        command: ShellCommand,
        cwd: WorkingDirectory?,
        host: LedgerHost = .tty
    ) async -> EvaluationResult {
        let now = clock()
        let load = allowlist
        return await gated.spendHostAsk(
            command: command,
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: { load(cwd, now) },
            host: host
        )
    }

    /// Catalog-only file-tool door. Packs and Policy gate never see the path.
    package func runFile(
        action: FileToolAction,
        cwd: WorkingDirectory?,
        host: LedgerHost = .tty
    ) -> EvaluationResult {
        gated.runFile(
            action,
            home: home,
            cwd: cwd,
            host: host,
            now: clock()
        )
    }

    /// Wire-path peek for an already-built request.
    package func peek(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        host: LedgerHost = .tty
    ) async -> EvaluationResult {
        let now = clock()
        let load = allowlist
        return await gated.peek(
            request,
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: { load(cwd, now) },
            host: host
        )
    }

    /// Wire-path apply for an already-built request.
    package func apply(
        _ request: EvaluationRequest,
        cwd: WorkingDirectory?,
        host: LedgerHost = .tty
    ) async -> EvaluationResult {
        let now = clock()
        let load = allowlist
        return await gated.apply(
            request,
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: { load(cwd, now) },
            host: host
        )
    }

    package func mintUnlockCode(
        for result: EvaluationResult,
        cwd: WorkingDirectory?
    ) async -> String? {
        await GatedEvaluate.mintUnlockCode(
            for: result,
            cwd: cwd,
            store: store,
            now: clock(),
            home: home
        )
    }

    private func run(
        _ intent: EvaluationIntent,
        command: ShellCommand,
        cwd: WorkingDirectory?,
        host: LedgerHost
    ) async -> EvaluationResult {
        let now = clock()
        let load = allowlist
        return await gated.run(
            intent,
            command: command,
            cwd: cwd,
            home: home,
            store: store,
            now: now,
            allowlist: { load(cwd, now) },
            host: host
        )
    }

    private static func defaultStore(home: HomeDirectory?) -> AllowOnceStore {
        if let home {
            return AllowOnceStore.live(home: home)
        }
        return AllowOnceStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "rv-allow-once-\(UUID().uuidString)",
                    isDirectory: true
                )
        )
    }
}
