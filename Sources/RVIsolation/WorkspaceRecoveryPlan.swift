#if os(macOS)
import Foundation

/// The effect a recovery step performs once its mount observation admits it.
enum RecoveryAction: Equatable, Sendable {
    /// Reattach the boundary to the owned mount, preflight, then publish.
    case publishOwnedMount
    /// Reattach the boundary to the owned mount and detach it.
    case detachOwnedMount
    /// The original is back in place; remove the leftover owned image.
    case removeOwnedImage
    /// The mount is gone; move the hidden saved tree back to the original path.
    case restoreHiddenOriginal
}

/// What one recovery step does with the mount observation taken just before it.
enum RecoveryDecision: Equatable, Sendable {
    /// Nothing to do and nothing to record.
    case done
    /// Stop recovery for safety without touching either copy.
    case blocked(WorkspaceRecoveryBlock.Reason)
    /// The observation contradicts the step; retry later. Nothing recorded.
    case failed
    /// The step's goal already holds; record its completion without acting.
    case markComplete
    /// Perform the action, then record the step's completion.
    case act(RecoveryAction)
}

/// Pure decision table for the publish → detach → restore recovery steps.
///
/// The shell checks completeness, takes exactly one mount observation
/// immediately before the guarded action, asks `decide`, performs the action,
/// and records `completion(of:)`. The per-step rows differ on purpose: an
/// absent mount blocks publication but means detach and restore can proceed.
enum WorkspaceRecoveryPlan {
    static func decide(
        step: WorkspaceSessionLifecycle.TeardownStep,
        progress: Set<WorkspaceLifecycleRecord.Kind>,
        observation: WorkspaceMountObservation
    ) -> RecoveryDecision {
        if WorkspaceSessionLifecycle.isComplete(step, progress: progress) {
            return .done
        }
        switch (step, observation) {
        case (.publish, .ownedMount):
            return .act(.publishOwnedMount)
        case (.publish, .originalRestored):
            return .done
        case (.publish, .missingMount):
            return .blocked(.missingVolume)

        case (.detach, .ownedMount):
            return .act(.detachOwnedMount)
        case (.detach, .originalRestored), (.detach, .missingMount):
            return .markComplete

        case (.restore, .ownedMount):
            return .failed
        case (.restore, .originalRestored):
            return .act(.removeOwnedImage)
        case (.restore, .missingMount):
            return .act(.restoreHiddenOriginal)

        case (.publish, .unrelatedMount), (.detach, .unrelatedMount), (.restore, .unrelatedMount):
            return .blocked(.unrelatedMount)
        case (.publish, .savedTreeMismatch), (.detach, .savedTreeMismatch), (.restore, .savedTreeMismatch):
            return .blocked(.ambiguousSavedTree)
        case (.publish, .ambiguous), (.detach, .ambiguous), (.restore, .ambiguous):
            return .blocked(.ambiguousOwnership)
        }
    }

    /// The journal event that records a step as finished.
    static func completion(
        of step: WorkspaceSessionLifecycle.TeardownStep
    ) -> WorkspaceLifecycleRecord.Kind {
        switch step {
        case .publish:
            return .publicationCompleted
        case .detach:
            return .mountCleanupCompleted
        case .restore:
            return .originalRestored
        }
    }
}
#endif
