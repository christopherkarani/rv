import Testing
@testable import RVIsolation

/// Characterization of the per-step mount decision table that
/// `WorkspaceRecovery` executed inline before the plan was extracted.
@Suite("Workspace recovery plan")
struct WorkspaceRecoveryPlanTests {
    typealias Step = WorkspaceSessionLifecycle.TeardownStep

    struct Row: Sendable, CustomTestStringConvertible {
        let step: Step
        let observation: WorkspaceMountObservation
        let expected: RecoveryDecision

        var testDescription: String { "\(step) × \(observation) → \(expected)" }
    }

    static let observations = WorkspaceMountObservation.allCases

    static let steps: [Step] = [.publish, .detach, .restore]

    /// Every `(step, observation)` pair, with no completion recorded for the step.
    static let table: [Row] = [
        Row(step: .publish, observation: .ownedMount, expected: .act(.publishOwnedMount)),
        Row(step: .publish, observation: .originalRestored, expected: .done),
        Row(step: .publish, observation: .missingMount, expected: .blocked(.missingVolume)),
        Row(step: .publish, observation: .unrelatedMount, expected: .blocked(.unrelatedMount)),
        Row(step: .publish, observation: .savedTreeMismatch, expected: .blocked(.ambiguousSavedTree)),
        Row(step: .publish, observation: .ambiguous, expected: .blocked(.ambiguousOwnership)),

        Row(step: .detach, observation: .ownedMount, expected: .act(.detachOwnedMount)),
        Row(step: .detach, observation: .originalRestored, expected: .markComplete),
        Row(step: .detach, observation: .missingMount, expected: .markComplete),
        Row(step: .detach, observation: .unrelatedMount, expected: .blocked(.unrelatedMount)),
        Row(step: .detach, observation: .savedTreeMismatch, expected: .blocked(.ambiguousSavedTree)),
        Row(step: .detach, observation: .ambiguous, expected: .blocked(.ambiguousOwnership)),

        Row(step: .restore, observation: .ownedMount, expected: .failed),
        Row(step: .restore, observation: .originalRestored, expected: .act(.removeOwnedImage)),
        Row(step: .restore, observation: .missingMount, expected: .act(.restoreHiddenOriginal)),
        Row(step: .restore, observation: .unrelatedMount, expected: .blocked(.unrelatedMount)),
        Row(step: .restore, observation: .savedTreeMismatch, expected: .blocked(.ambiguousSavedTree)),
        Row(step: .restore, observation: .ambiguous, expected: .blocked(.ambiguousOwnership)),
    ]

    /// Journal progress as it stands when `perform` reaches each step.
    static func progressBefore(_ step: Step) -> Set<WorkspaceLifecycleRecord.Kind> {
        switch step {
        case .publish:
            return [.created, .recoveryBegan, .childTeardownCompleted]
        case .detach:
            return [.created, .recoveryBegan, .childTeardownCompleted, .publicationCompleted]
        case .restore:
            return [.created, .recoveryBegan, .childTeardownCompleted, .publicationCompleted, .mountCleanupCompleted]
        }
    }

    @Test func tableCoversEveryStepAndObservationExactlyOnce() {
        for step in Self.steps {
            for observation in Self.observations {
                let matches = Self.table.filter { $0.step == step && $0.observation == observation }
                #expect(matches.count == 1, "\(step) × \(observation)")
            }
        }
        #expect(Self.table.count == Self.steps.count * Self.observations.count)
    }

    @Test(arguments: table)
    func incompleteStepDecidesFromObservation(_ row: Row) {
        let decision = WorkspaceRecoveryPlan.decide(
            step: row.step,
            progress: Self.progressBefore(row.step),
            observation: row.observation
        )
        #expect(decision == row.expected)
    }

    @Test(arguments: table)
    func emptyProgressDecidesTheSameAsResumedProgress(_ row: Row) {
        let decision = WorkspaceRecoveryPlan.decide(step: row.step, progress: [], observation: row.observation)
        #expect(decision == row.expected)
    }

    /// Progress sets that make each step complete, per the resumption table.
    static let completed: [(Step, Set<WorkspaceLifecycleRecord.Kind>)] = [
        (.publish, [.publicationCompleted]),
        (.publish, [.originalRestored]),
        (.detach, [.mountCleanupCompleted]),
        (.detach, [.originalRestored]),
        (.restore, [.originalRestored]),
    ]

    @Test(arguments: observations)
    func alreadyCompleteStepIsDoneWhateverTheObservation(_ observation: WorkspaceMountObservation) {
        for (step, progress) in Self.completed {
            #expect(
                WorkspaceSessionLifecycle.isComplete(step, progress: progress),
                "\(step) must be complete for \(progress)"
            )
            #expect(
                WorkspaceRecoveryPlan.decide(step: step, progress: progress, observation: observation) == .done,
                "\(step) with \(progress) observing \(observation)"
            )
        }
    }

    @Test func earlierStepCompletionDoesNotCompleteALaterStep() {
        #expect(
            WorkspaceRecoveryPlan.decide(step: .detach, progress: [.publicationCompleted], observation: .ownedMount)
                == .act(.detachOwnedMount)
        )
        #expect(
            WorkspaceRecoveryPlan.decide(step: .restore, progress: [.mountCleanupCompleted], observation: .missingMount)
                == .act(.restoreHiddenOriginal)
        )
    }

    @Test(arguments: [
        (Step.publish, WorkspaceLifecycleRecord.Kind.publicationCompleted),
        (Step.detach, WorkspaceLifecycleRecord.Kind.mountCleanupCompleted),
        (Step.restore, WorkspaceLifecycleRecord.Kind.originalRestored),
    ])
    func completionEventMarksTheStepComplete(_ step: Step, _ kind: WorkspaceLifecycleRecord.Kind) {
        #expect(WorkspaceRecoveryPlan.completion(of: step) == kind)
        #expect(WorkspaceSessionLifecycle.isComplete(step, progress: [kind]))
    }
}
