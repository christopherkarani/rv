import Foundation

// Pure stage machine over the durable workspace lifecycle journal
// (`WorkspaceLifecycleRecord.Kind`). One owner for the facts that recovery
// admission, interruption recovery, and compaction drop decisions all
// consult, so the journal is interpreted one way instead of three:
//
// - `facts(of:)` is the single pass that names shape facts of a workspace's
//   record stream; compaction's drop predicate and `reconstruction(_:)`'s
//   corruption guard share it instead of hand-mirroring each other.
// - `reconstruct(_:)` is the phase walk: it regroups the flat journal into
//   per-workspace reconstructions and classifies each as recoverable,
//   closed, blocked, or corrupt. The journal is untrusted input: every
//   field is narrowed or defaulted, never assumed.
// - `isComplete(_:progress:)` is the recovery resumption table, stating
//   which recorded completions make each teardown step idempotent.
//
// Everything here is a value computation over records already decoded. No
// I/O, no clocks, no process knowledge: callers supply records, and facts
// come back. The imperative shells (`WorkspaceRecovery`, compaction under
// its file lock) perform the writes.

enum WorkspaceSessionLifecycle {
    /// Shape facts accumulated from one workspace's records. Consumed by
    /// compaction's drop predicate and by `reconstruction(_:)`'s final
    /// corruption guard, which are the same question ("provably dead?").
    struct ShapeFacts: Equatable {
        /// Count of `.created` lines. More than one creation, or none,
        /// makes the workspace unclassifiable.
        var createdCount = 0

        /// Whether a literal `.closed` line exists. Only the real close
        /// event counts: `.recoveryCompleted` implies closed for recovery,
        /// but a later `.closed` line for the same id is still possible,
        /// so treating it as terminal here would drop evidence early.
        var closedRecorded = false

        /// Distinct non-empty original paths across all records. Two or
        /// more mean the id spans workspaces (covetous id reuse) and the
        /// stream is corrupt regardless of phase.
        var paths: Set<String> = []

        /// Whether any record carried a non-empty protected path.
        var hasProtected = false

        mutating func absorb(_ record: WorkspaceLifecycleRecord) {
            if record.kind == .created {
                createdCount += 1
            }
            if record.kind == .closed {
                closedRecorded = true
            }
            if record.originalPath.isEmpty == false {
                paths.insert(record.originalPath)
            }
            if record.protectedPath.isEmpty == false {
                hasProtected = true
            }
        }

        /// Whether the shape is classifiable as one clean creation. The
        /// compaction drop predicate is this fact conjunction gated on
        /// `closedRecorded`; recovery's corruption guard is its negation.
        var wellFormed: Bool {
            createdCount == 1 && paths.count == 1 && hasProtected
        }

        /// The drop predicate's full condition: only lines recovery
        /// classifies as closed, and only when the shape admits exactly
        /// one created workspace. Blocked-but-shaped streams stay.
        var droppable: Bool {
            closedRecorded && wellFormed
        }
    }

    /// One pass over a workspace's records. Callers that already walk the
    /// records can `absorb` incrementally instead.
    static func facts(of records: [WorkspaceLifecycleRecord]) -> ShapeFacts {
        var accumulated = ShapeFacts()
        for record in records {
            accumulated.absorb(record)
        }
        return accumulated
    }

    /// Teardown steps that recovery resumptions re-enter after a crash.
    /// Child teardown is deliberately absent: its resumption re-proves
    /// process death from the runtime journal, so it has no recorded
    /// shortcut.
    enum TeardownStep: Equatable {
        case publish
        case detach
        case restore
    }

    /// The resumption table. Each step is idempotent once its own event,
    /// or any strictly later step's event, is recorded. Encoding this as
    /// data keeps a crash-recovery edit from silently diverging from the
    /// skip rules the interruption tests exercise.
    static func isComplete(
        _ step: TeardownStep,
        progress: Set<WorkspaceLifecycleRecord.Kind>
    ) -> Bool {
        switch step {
        case .publish:
            return progress.contains(.publicationCompleted)
                || progress.contains(.originalRestored)
        case .detach:
            return progress.contains(.mountCleanupCompleted)
                || progress.contains(.originalRestored)
        case .restore:
            return progress.contains(.originalRestored)
        }
    }

    /// Recovery's classify. Regroups the flat journal by workspace id in
    /// first-seen order and walks each id's stream once.
    static func reconstruct(
        _ records: [WorkspaceLifecycleRecord]
    ) -> [WorkspaceReconstruction] {
        var order: [UUID] = []
        var grouped: [UUID: [WorkspaceLifecycleRecord]] = [:]
        for record in records {
            if grouped[record.workspace] == nil {
                order.append(record.workspace)
            }
            grouped[record.workspace, default: []].append(record)
        }
        return order.compactMap { id in
            guard let events = grouped[id] else { return nil }
            return reconstruction(id: id, records: events)
        }
    }

    struct WorkspaceReconstruction: Equatable {
        var id: UUID
        var originalPath: String
        var protectedPath: String
        var records: [WorkspaceLifecycleRecord]
        var identity: WorkspaceDurableIdentity?
        var groups: [RecordedProcessGroup]
        var malformedGroup: Bool
        var phase: Phase

        enum Phase: Equatable {
            case recoverable
            case closed
            case blocked(WorkspaceRecoveryBlock.Reason)
            case corrupt
        }
    }

    private static func reconstruction(
        id: UUID,
        records: [WorkspaceLifecycleRecord]
    ) -> WorkspaceReconstruction {
        var original = ""
        var protected = ""
        var identity: WorkspaceDurableIdentity?
        var groups: [UUID: RecordedProcessGroup] = [:]
        var malformedGroup = false
        var shape = ShapeFacts()
        var phase = WorkspaceReconstruction.Phase.recoverable
        for record in records {
            shape.absorb(record)
            if record.originalPath.isEmpty == false, original.isEmpty {
                original = record.originalPath
            }
            if record.protectedPath.isEmpty == false, protected.isEmpty {
                protected = record.protectedPath
            }
            switch record.kind {
            case .created:
                if let next = record.identity {
                    if let identity, identity != next {
                        phase = .corrupt
                    } else {
                        identity = next
                    }
                }
            case .runtimeStarted:
                guard let runtime = record.runtime,
                    let rawGroup = record.processGroup,
                    let seconds = record.processStartSeconds,
                    let microseconds = record.processStartMicroseconds,
                    // Failable narrowing: the journal is untrusted input
                    // and `Int32(_:)` would trap below `Int32.min`.
                    let narrowed = Int32(exactly: rawGroup),
                    let pgid = ValidatedPGID(narrowed)
                else {
                    malformedGroup = true
                    continue
                }
                let group = RecordedProcessGroup(
                    runtime: runtime,
                    pgid: pgid,
                    startSeconds: seconds,
                    startMicroseconds: microseconds
                )
                if let existing = groups[runtime], existing != group {
                    malformedGroup = true
                } else {
                    groups[runtime] = group
                }
            case .recoveryBlocked:
                if phase != .closed, phase != .corrupt {
                    if let reason = record.blockReason.flatMap(WorkspaceRecoveryBlock.Reason.init(rawValue:)) {
                        phase = .blocked(reason)
                    } else {
                        phase = .corrupt
                    }
                }
            case .recoveryCompleted, .closed:
                phase = .closed
            case .runtimeEnded, .recoveryBegan, .childTeardownCompleted, .publicationCompleted,
                .mountCleanupCompleted, .originalRestored, .hostStarted:
                break
            }
        }
        if shape.wellFormed == false {
            phase = .corrupt
        }
        return WorkspaceReconstruction(
            id: id,
            originalPath: original,
            protectedPath: protected,
            records: records,
            identity: identity,
            groups: Array(groups.values),
            malformedGroup: malformedGroup,
            phase: phase
        )
    }
}
