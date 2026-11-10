import Foundation
import RVAnalytics
import RVDomain
import RVPacks
import RVPolicy
@testable import RVService

/// Hook budget for test runtimes that assert on what a hook call commits
/// (pending rows, unlock codes, spent grants, ledger rows). This suite runs
/// hundreds of tests on a few cores, so a dispatch can wait in the
/// cooperative pool past the real `HookDeadline.budget`, and the deadline
/// then correctly commits nothing. `HookDeadlineTests` pins the real budget
/// and its timeout path; everything else gets this one generous value.
let testHookBudget: Duration = .seconds(120)

/// `ServiceRuntime`'s public init, with `testHookBudget` (or `hookBudget`)
/// for hook dispatch.
func hookTestRuntime(
    snapshots: [PackSnapshot]? = nil,
    catalog: PackCatalog? = nil,
    home: HomeDirectory? = nil,
    allowOnce: AllowOnceStore? = nil,
    allowOnceDirectory: URL? = nil,
    grants: EphemeralAllowOnceTable? = nil,
    log: (any ServiceLog)? = nil,
    analytics: AnalyticsCoordinator? = nil,
    clock: @escaping @Sendable () -> Date = { Date() },
    pendingApprovals: PendingApprovalsBinding = .automatic,
    ownerPresence: OwnerPresence = OwnerPresence(),
    hookBudget: Duration = testHookBudget
) -> ServiceRuntime {
    ServiceRuntime(
        snapshots: snapshots,
        catalog: catalog,
        home: home,
        allowOnce: allowOnce,
        allowOnceDirectory: allowOnceDirectory,
        grants: grants,
        idleExitSeconds: IdleWatchdog.defaultSeconds,
        log: log,
        analytics: analytics,
        clock: clock,
        pendingApprovals: pendingApprovals,
        ceremonies: WorkspaceOperatorCeremonyService(),
        ownerPresence: ownerPresence,
        hookBudget: hookBudget
    )
}
