import Foundation
import Testing
@testable import RVIsolation

@Suite
struct WorkspaceSessionLifecycleTests {
    private let workspace = UUID()

    private var sampleIdentity: WorkspaceDurableIdentity {
        WorkspaceDurableIdentity(
            savedPath: "/tmp/.rv-saved-proj",
            savedDevice: 1,
            savedInode: 2,
            quarantinePath: "/tmp/.rv-quarantine-proj",
            volumeDevice: 3,
            disk: "/dev/disk9s1",
            mountSource: "/dev/disk9s1",
            imagePath: "/tmp/.rv-image-proj",
            imageDevice: 4,
            imageInode: 5,
            lockPath: "/tmp/.rv-lock-proj",
            lockDevice: 6,
            lockInode: 7,
            ownerToken: UUID(),
            snapshotPath: "/tmp/.rv-snapshot-proj",
            snapshotDevice: 8,
            snapshotInode: 9
        )
    }

    private func line(
        _ kind: WorkspaceLifecycleRecord.Kind,
        original: String = "/tmp/proj",
        protected: String = "/private/tmp/rv-saved/proj",
        identity: WorkspaceDurableIdentity? = nil,
        blockReason: String? = nil
    ) -> WorkspaceLifecycleRecord {
        WorkspaceLifecycleRecord(
            kind: kind,
            workspace: workspace,
            originalPath: original,
            protectedPath: protected,
            volumeDevice: 1,
            disk: "/dev/disk9",
            runtime: nil,
            recordedAt: .distantPast,
            identity: identity,
            blockReason: blockReason
        )
    }

    private func started(pgid: Int64) -> WorkspaceLifecycleRecord {
        WorkspaceLifecycleRecord(
            kind: .runtimeStarted,
            workspace: workspace,
            originalPath: "/tmp/proj",
            protectedPath: "/private/tmp/rv-saved/proj",
            volumeDevice: 1,
            disk: "/dev/disk9",
            runtime: workspace,
            recordedAt: .distantPast,
            processGroup: pgid,
            processStartSeconds: 1_000,
            processStartMicroseconds: 5
        )
    }

    private func phase(
        of records: [WorkspaceLifecycleRecord]
    ) -> WorkspaceSessionLifecycle.WorkspaceReconstruction.Phase {
        WorkspaceSessionLifecycle.reconstruct(records).first?.phase
            ?? WorkspaceSessionLifecycle.WorkspaceReconstruction.Phase.corrupt
    }

    // MARK: Well-formed shape

    @Test func createdClosedStreamIsClosedAndDroppable() {
        let records = [line(.created), line(.closed)]
        let facts = WorkspaceSessionLifecycle.facts(of: records)
        #expect(facts.wellFormed)
        #expect(facts.droppable)
        #expect(phase(of: records) == .closed)
    }

    @Test func recoveryCompletedOnlyIsClosedButNotDroppable() {
        let records = [line(.created), line(.recoveryCompleted)]
        let facts = WorkspaceSessionLifecycle.facts(of: records)
        #expect(facts.wellFormed)
        #expect(facts.droppable == false)
        #expect(phase(of: records) == .closed)
    }

    @Test func blockedWithoutClosedStaysBlocked() {
        let records = [
            line(.created),
            line(.recoveryBlocked, blockReason: WorkspaceRecoveryBlock.Reason.ambiguousOwnership.rawValue),
        ]
        let facts = WorkspaceSessionLifecycle.facts(of: records)
        #expect(facts.wellFormed)
        #expect(facts.droppable == false)
        #expect(phase(of: records) == .blocked(.ambiguousOwnership))
    }

    @Test func closedFlipsBlockedBackToClosed() {
        let records = [
            line(.created),
            line(.recoveryBlocked, blockReason: WorkspaceRecoveryBlock.Reason.ambiguousOwnership.rawValue),
            line(.closed),
        ]
        #expect(WorkspaceSessionLifecycle.facts(of: records).droppable)
        #expect(phase(of: records) == .closed)
    }

    // MARK: Corruption guard

    @Test func missingCreationIsCorrupt() {
        let records = [line(.closed)]
        #expect(WorkspaceSessionLifecycle.facts(of: records).wellFormed == false)
        #expect(phase(of: records) == .corrupt)
    }

    @Test func duplicateCreationIsCorrupt() {
        let records = [line(.created), line(.created), line(.closed)]
        #expect(WorkspaceSessionLifecycle.facts(of: records).droppable == false)
        #expect(phase(of: records) == .corrupt)
    }

    @Test func splitPathsAreCorrupt() {
        let records = [
            line(.created, original: "/tmp/proj"),
            line(.created, original: "/tmp/other"),
            line(.closed),
        ]
        #expect(phase(of: records) == .corrupt)
    }

    @Test func emptyOriginalStreamIsCorrupt() {
        let records = [
            line(.created, original: ""),
            line(.closed, original: ""),
        ]
        #expect(phase(of: records) == .corrupt)
    }

    @Test func missingProtectedPathStreamIsCorrupt() {
        let records = [
            line(.created, protected: ""),
            line(.closed, protected: ""),
        ]
        #expect(phase(of: records) == .corrupt)
    }

    @Test func conflictingIdentityIsCorrupt() {
        let first = sampleIdentity
        var second = first
        second.disk = "/dev/disk0"
        let records = [
            line(.created, identity: first),
            line(.created, identity: second),
        ]
        #expect(phase(of: records) == .corrupt)
    }

    @Test func unknownBlockReasonIsCorrupt() {
        let records = [
            line(.created),
            line(.recoveryBlocked, blockReason: "nonsense"),
        ]
        #expect(phase(of: records) == .corrupt)
    }

    // MARK: Group narrowing (journal is untrusted input)

    @Test func validProcessGroupIsRecovered() {
        let records = [line(.created), started(pgid: 4242)]
        let reconstruction = WorkspaceSessionLifecycle.reconstruct(records).first
        #expect(reconstruction?.malformedGroup == false)
        #expect(reconstruction?.groups.count == 1)
        #expect(reconstruction?.groups.first?.pgid.rawValue == 4242)
    }

    @Test func pgidBelowTwoIsMalformed() {
        let records = [line(.created), started(pgid: 1)]
        #expect(
            WorkspaceSessionLifecycle.reconstruct(records).first?.malformedGroup
                == true
        )
    }

    @Test func pgidOutOfRangeIsMalformedNotTrapping() {
        let records = [line(.created), started(pgid: Int64(Int32.max) + 1)]
        #expect(
            WorkspaceSessionLifecycle.reconstruct(records).first?.malformedGroup
                == true
        )
    }

    @Test func conflictingProcessGroupIsMalformed() {
        let records = [line(.created), started(pgid: 7), started(pgid: 8)]
        #expect(
            WorkspaceSessionLifecycle.reconstruct(records).first?.malformedGroup
                == true
        )
    }

    @Test func malformedGroupDoesNotBlockDrop() {
        let records = [
            line(.created),
            started(pgid: Int64(Int32.max) + 1),
            line(.closed),
        ]
        #expect(WorkspaceSessionLifecycle.facts(of: records).droppable)
    }

    // MARK: Regrouping

    @Test func regroupsInFirstSeenOrder() {
        let other = UUID()
        func otherLine(_ kind: WorkspaceLifecycleRecord.Kind) -> WorkspaceLifecycleRecord {
            WorkspaceLifecycleRecord(
                kind: kind,
                workspace: other,
                originalPath: "/tmp/other",
                protectedPath: "/private/tmp/rv-saved/other",
                volumeDevice: 1,
                disk: "/dev/disk9",
                runtime: nil,
                recordedAt: .distantPast
            )
        }
        let reconstructions = WorkspaceSessionLifecycle.reconstruct(
            [otherLine(.created), line(.created), line(.closed)]
        )
        #expect(reconstructions.count == 2)
        #expect(reconstructions[0].id == other)
        #expect(reconstructions[0].phase == .recoverable)
        #expect(reconstructions[1].id == workspace)
        #expect(reconstructions[1].phase == .closed)
    }

    // MARK: Recovery resumption table

    @Test func publishResumesOnPublicationCompletedOrOriginalRestored() {
        for progress in [
            Set<WorkspaceLifecycleRecord.Kind>([.publicationCompleted]),
            Set<WorkspaceLifecycleRecord.Kind>([.originalRestored]),
        ] {
            #expect(WorkspaceSessionLifecycle.isComplete(.publish, progress: progress))
        }
        for progress in [
            Set<WorkspaceLifecycleRecord.Kind>(),
            Set<WorkspaceLifecycleRecord.Kind>([.mountCleanupCompleted]),
            Set<WorkspaceLifecycleRecord.Kind>([.childTeardownCompleted]),
        ] {
            #expect(WorkspaceSessionLifecycle.isComplete(.publish, progress: progress) == false)
        }
    }

    @Test func detachResumesOnMountCleanupCompletedOrOriginalRestored() {
        for progress in [
            Set<WorkspaceLifecycleRecord.Kind>([.mountCleanupCompleted]),
            Set<WorkspaceLifecycleRecord.Kind>([.originalRestored]),
        ] {
            #expect(WorkspaceSessionLifecycle.isComplete(.detach, progress: progress))
        }
        #expect(
            WorkspaceSessionLifecycle.isComplete(
                .detach,
                progress: [.publicationCompleted]
            ) == false
        )
    }

    @Test func restoreResumesOnlyOnOriginalRestored() {
        #expect(
            WorkspaceSessionLifecycle.isComplete(.restore, progress: [.originalRestored])
        )
        #expect(
            WorkspaceSessionLifecycle.isComplete(.restore, progress: []) == false
        )
        #expect(
            WorkspaceSessionLifecycle.isComplete(
                .restore,
                progress: [.mountCleanupCompleted]
            ) == false
        )
    }

    // MARK: Incremental absorption used by compaction

    @Test func absorbMirrorsTheFactsPass() {
        let records = [line(.created), line(.created), line(.closed)]
        var absorbed = WorkspaceSessionLifecycle.ShapeFacts()
        for record in records {
            absorbed.absorb(record)
        }
        #expect(absorbed == WorkspaceSessionLifecycle.facts(of: records))
        #expect(absorbed.droppable == false)
    }
}
