import Foundation
import RVDomain

/// Why automatic recovery stopped without destroying either copy of the work.
public struct WorkspaceRecoveryBlock: Equatable, Sendable {
    public var workspace: UUID?
    public var reason: Reason

    public enum Reason: String, Equatable, Sendable {
        case publicationConflict
        case missingVolume
        case ambiguousOwnership
        case ambiguousSavedTree
        case unprovenProcess
        case unrelatedMount
        case tornLog
        case corrupt
    }

    public init(workspace: UUID?, reason: Reason) {
        self.workspace = workspace
        self.reason = reason
    }
}

/// Where a test stops recovery after the corresponding event is durable.
public struct WorkspaceRecoveryFault: Equatable, Sendable {
    public enum Boundary: Equatable, Sendable {
        case afterChildTeardown
        case afterPublish
        case afterUnmount
        case afterOriginalRestoration
        case beforeTerminalAppend
    }

    public var boundary: Boundary

    public init(boundary: Boundary) {
        self.boundary = boundary
    }
}

public enum WorkspaceRecoveryAssessment: Equatable, Sendable {
    case clean
    case liveOwner(UUID?)
    case recoveryInProgress(UUID)
    case orphaned(UUID)
    case blocked(WorkspaceRecoveryBlock)
}

public enum WorkspaceRecoveryOutcome: Equatable, Sendable {
    case clean
    case recovered(UUID)
    case liveOwner(UUID?)
    case recoveryInProgress(UUID)
    case blocked(WorkspaceRecoveryBlock)
    case interrupted(WorkspaceRecoveryFault.Boundary)
    /// Filesystem or log IO failed. Another attempt may proceed. Nothing was marked finished.
    case failed
}

/// Reconstructs an incomplete protected workspace and reclaims it before a new one is created.
enum WorkspaceRecovery {
    static func snapshotURL(directory: URL, id: UUID) -> URL {
        directory
            .appendingPathComponent("workspace-snapshots", isDirectory: true)
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")
    }
}

#if os(macOS)
import Darwin

extension WorkspaceRecovery {
    /// Read-only classification. Does not kill, unmount, or create a workspace.
    public static func assess(
        _ workspace: WorkingDirectory,
        lifecycleLog: URL,
        runtimeLog: URL
    ) -> WorkspaceRecoveryAssessment {
        _ = runtimeLog
        guard let canonical = canonicalProject(workspace) else {
            return .blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .corrupt))
        }
        if let claim = WorkspaceOwnerRegistry.current(canonical) {
            return assessment(for: claim, path: canonical, log: lifecycleLog)
        }
        switch history(canonicalPath: canonical, log: lifecycleLog) {
        case .unreadable, .corrupt:
            return .blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .corrupt))
        case .torn:
            return .blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .tornLog))
        case .clean:
            return .clean
        case .workspace(let workspace):
            return assessWorkspace(workspace)
        }
    }

    /// Reclaim one incomplete workspace. Does not open a replacement.
    public static func recover(
        _ workspace: WorkingDirectory,
        lifecycleLog: URL,
        runtimeLog: URL,
        fault: WorkspaceRecoveryFault? = nil
    ) -> WorkspaceRecoveryOutcome {
        guard let canonical = canonicalProject(workspace) else {
            return .blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .corrupt))
        }
        if let claim = WorkspaceOwnerRegistry.current(canonical) {
            return outcome(for: claim, path: canonical, log: lifecycleLog)
        }
        switch history(canonicalPath: canonical, log: lifecycleLog) {
        case .unreadable, .corrupt:
            return .blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .corrupt))
        case .torn:
            return .blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .tornLog))
        case .clean:
            return .clean
        case .workspace:
            break
        }
        guard WorkspaceOwnerRegistry.beginOpening(canonical) else {
            return .liveOwner(nil)
        }
        defer { WorkspaceOwnerRegistry.cancelOpening(canonical) }
        switch reclaim(
            canonicalPath: canonical,
            lifecycleLog: lifecycleLog,
            runtimeLog: runtimeLog,
            fault: fault?.boundary,
            rotateWhenFinished: false
        ) {
        case .ready(let lock):
            lock.release()
            return .failed
        case .finished(let outcome):
            return outcome
        }
    }

    /// Serialize creation for `canonicalPath` and recover an orphan first.
    ///
    /// On success the caller holds the project lock and the in-process opening
    /// claim, and must either adopt them or cancel them.
    static func admit(
        canonicalPath: String,
        lifecycleLog: URL,
        runtimeLog: URL
    ) -> Result<WorkspaceOwnerLock, WorkspaceSessionError> {
        if let claim = WorkspaceOwnerRegistry.current(canonicalPath) {
            return .failure(sessionError(outcome(for: claim, path: canonicalPath, log: lifecycleLog)))
        }
        guard WorkspaceOwnerRegistry.beginOpening(canonicalPath) else {
            return .failure(.ownedByLiveProcess(nil))
        }
        switch reclaim(
            canonicalPath: canonicalPath,
            lifecycleLog: lifecycleLog,
            runtimeLog: runtimeLog,
            fault: nil,
            rotateWhenFinished: true
        ) {
        case .ready(let lock):
            return .success(lock)
        case .finished(let outcome):
            WorkspaceOwnerRegistry.cancelOpening(canonicalPath)
            return .failure(sessionError(outcome))
        }
    }

    private enum Admission {
        case ready(WorkspaceOwnerLock)
        case finished(WorkspaceRecoveryOutcome)
    }

    private static func reclaim(
        canonicalPath: String,
        lifecycleLog: URL,
        runtimeLog: URL,
        fault: WorkspaceRecoveryFault.Boundary?,
        rotateWhenFinished: Bool
    ) -> Admission {
        switch history(canonicalPath: canonicalPath, log: lifecycleLog) {
        case .unreadable, .corrupt:
            return .finished(.blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .corrupt)))
        case .torn:
            return .finished(.blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .tornLog)))
        case .clean:
            return prepareFreshLock(
                canonicalPath: canonicalPath,
                directory: lifecycleLog.deletingLastPathComponent(),
                lifecycleLog: lifecycleLog,
                runtimeLog: runtimeLog
            )
        case .workspace(let workspace):
            return reclaimWorkspace(
                workspace,
                canonicalPath: canonicalPath,
                lifecycleLog: lifecycleLog,
                runtimeLog: runtimeLog,
                fault: fault,
                rotateWhenFinished: rotateWhenFinished
            )
        }
    }

    private static func prepareFreshLock(
        canonicalPath: String,
        directory: URL,
        lifecycleLog: URL,
        runtimeLog: URL
    ) -> Admission {
        let path = WorkspaceOwnerLock.gatePath(directory: directory, canonicalProject: canonicalPath)
        switch WorkspaceOwnerLock.acquire(path: path, create: true) {
        case .busy:
            return .finished(.liveOwner(nil))
        case .missing, .mismatched, .unavailable:
            return .finished(.failed)
        case .acquired(let lock):
            switch history(canonicalPath: canonicalPath, log: lifecycleLog) {
            case .clean:
                guard lock.replaceToken(UUID()) else {
                    lock.release()
                    return .finished(.failed)
                }
                return .ready(lock)
            case .workspace(let workspace):
                lock.release()
                return reclaimWorkspace(
                    workspace,
                    canonicalPath: canonicalPath,
                    lifecycleLog: lifecycleLog,
                    runtimeLog: runtimeLog,
                    fault: nil,
                    rotateWhenFinished: true
                )
            case .unreadable, .corrupt:
                lock.release()
                return .finished(.blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .corrupt)))
            case .torn:
                lock.release()
                return .finished(.blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .tornLog)))
            }
        }
    }

    private static func reclaimWorkspace(
        _ workspace: WorkspaceReconstruction,
        canonicalPath: String,
        lifecycleLog: URL,
        runtimeLog: URL,
        fault: WorkspaceRecoveryFault.Boundary?,
        rotateWhenFinished: Bool
    ) -> Admission {
        guard let identity = workspace.identity else {
            let outcome = block(workspace, reason: .ambiguousOwnership, log: lifecycleLog, write: true)
            return .finished(outcome)
        }
        guard identity.lockPath.isEmpty == false else {
            return .finished(block(workspace, reason: .ambiguousOwnership, log: lifecycleLog, write: true))
        }
        switch WorkspaceOwnerLock.acquire(path: identity.lockPath, create: false) {
        case .busy:
            return .finished(busyOutcome(workspace))
        case .missing, .mismatched, .unavailable:
            return .finished(block(workspace, reason: .ambiguousOwnership, log: lifecycleLog, write: true))
        case .acquired(let lock):
            guard lock.matches(
                device: identity.lockDevice,
                inode: identity.lockInode,
                token: identity.ownerToken
            ) else {
                lock.release()
                return .finished(block(workspace, reason: .ambiguousOwnership, log: lifecycleLog, write: true))
            }
            let outcome = perform(
                workspace,
                lifecycleLog: lifecycleLog,
                runtimeLog: runtimeLog,
                fault: fault
            )
            switch outcome {
            case .recovered where rotateWhenFinished:
                guard lock.replaceToken(UUID()) else {
                    lock.release()
                    return .finished(.failed)
                }
                return .ready(lock)
            case .recovered:
                lock.release()
                return .finished(outcome)
            default:
                lock.release()
                return .finished(outcome)
            }
        }
    }

    private static func perform(
        _ workspace: WorkspaceReconstruction,
        lifecycleLog: URL,
        runtimeLog: URL,
        fault: WorkspaceRecoveryFault.Boundary?
    ) -> WorkspaceRecoveryOutcome {
        switch workspace.phase {
        case .corrupt:
            return .blocked(WorkspaceRecoveryBlock(workspace: workspace.id, reason: .corrupt))
        case .blocked(let reason):
            return .blocked(WorkspaceRecoveryBlock(workspace: workspace.id, reason: reason))
        case .closed:
            if has(.closed, workspace) == false {
                guard append(.closed, workspace, to: lifecycleLog) else { return .failed }
            }
            return .recovered(workspace.id)
        case .recoverable:
            break
        }
        guard let identity = workspace.identity else {
            return block(workspace, reason: .ambiguousOwnership, log: lifecycleLog, write: true)
        }
        guard savedTreeRelationship(original: workspace.originalPath, identity: identity),
            workspace.protectedPath == workspace.originalPath
        else {
            return block(workspace, reason: .ambiguousSavedTree, log: lifecycleLog, write: true)
        }
        guard identityUsable(identity) else {
            return block(workspace, reason: .ambiguousOwnership, log: lifecycleLog, write: true)
        }
        var progress = Set(workspace.records.map(\.kind))
        guard mark(.recoveryBegan, workspace, log: lifecycleLog, progress: &progress) else { return .failed }

        switch teardownChildren(workspace, runtimeLog: runtimeLog, log: lifecycleLog, progress: &progress) {
        case .done:
            break
        case .blocked(let reason):
            return block(workspace, reason: reason, log: lifecycleLog, write: true)
        case .failed:
            return .failed
        }
        if fault == .afterChildTeardown { return .interrupted(.afterChildTeardown) }

        switch publish(workspace, identity: identity, log: lifecycleLog, progress: &progress) {
        case .done:
            break
        case .blocked(let reason):
            return block(workspace, reason: reason, log: lifecycleLog, write: true)
        case .failed:
            return .failed
        }
        if fault == .afterPublish { return .interrupted(.afterPublish) }

        switch detach(workspace, identity: identity, log: lifecycleLog, progress: &progress) {
        case .done:
            break
        case .blocked(let reason):
            return block(workspace, reason: reason, log: lifecycleLog, write: true)
        case .failed:
            return .failed
        }
        if fault == .afterUnmount { return .interrupted(.afterUnmount) }

        switch restore(workspace, identity: identity, log: lifecycleLog, progress: &progress) {
        case .done:
            break
        case .blocked(let reason):
            return block(workspace, reason: reason, log: lifecycleLog, write: true)
        case .failed:
            return .failed
        }
        if fault == .afterOriginalRestoration { return .interrupted(.afterOriginalRestoration) }
        guard cleanupOwnedFiles(identity) else { return .failed }
        if fault == .beforeTerminalAppend { return .interrupted(.beforeTerminalAppend) }
        guard mark(.recoveryCompleted, workspace, log: lifecycleLog, progress: &progress) else { return .failed }
        guard mark(.closed, workspace, log: lifecycleLog, progress: &progress) else { return .failed }
        return .recovered(workspace.id)
    }

    private enum Step {
        case done
        case blocked(WorkspaceRecoveryBlock.Reason)
        case failed
    }

    private static func teardownChildren(
        _ workspace: WorkspaceReconstruction,
        runtimeLog: URL,
        log: URL,
        progress: inout Set<WorkspaceLifecycleRecord.Kind>
    ) -> Step {
        if workspace.malformedGroup {
            return .blocked(.unprovenProcess)
        }
        let accounted = Set(
            workspace.records.compactMap { record -> UUID? in
                switch record.kind {
                case .runtimeStarted, .runtimeEnded:
                    return record.runtime
                default:
                    return nil
                }
            }
        )
        let sessions = RuntimeSessionLog.records(at: runtimeLog).filter { $0.workspaceSession == workspace.id }
        if sessions.contains(where: { accounted.contains($0.id) == false }) {
            return .blocked(.unprovenProcess)
        }
        for group in workspace.groups {
            switch ProcessGroupRecovery.terminate(group) {
            case .success:
                break
            case .failure(.queryFailed):
                return .failed
            case .failure(.refusedIdentity):
                return .blocked(.unprovenProcess)
            }
        }
        guard mark(.childTeardownCompleted, workspace, log: log, progress: &progress) else { return .failed }
        return .done
    }

    private static func publish(
        _ workspace: WorkspaceReconstruction,
        identity: WorkspaceDurableIdentity,
        log: URL,
        progress: inout Set<WorkspaceLifecycleRecord.Kind>
    ) -> Step {
        if progress.contains(.publicationCompleted) || progress.contains(.originalRestored) {
            return .done
        }
        switch workspaceMountObservation(identity: identity, project: workspace.originalPath) {
        case .originalRestored:
            return .done
        case .missingMount:
            return .blocked(.missingVolume)
        case .unrelatedMount:
            return .blocked(.unrelatedMount)
        case .savedTreeMismatch:
            return .blocked(.ambiguousSavedTree)
        case .ambiguous:
            return .blocked(.ambiguousOwnership)
        case .ownedMount:
            break
        }
        guard case .success(let snapshot) = loadSnapshot(identity) else { return .failed }
        switch WorkspaceInodeBoundary.reattach(
            project: workspace.originalPath,
            identity: identity,
            snapshot: snapshot
        ) {
        case .failure:
            return .failed
        case .success(let boundary):
            switch boundary.preflightPublish() {
            case .failure:
                return .blocked(.publicationConflict)
            case .success:
                break
            }
            switch boundary.publishPreservingMount() {
            case .failure:
                return .failed
            case .success:
                break
            }
        }
        guard mark(.publicationCompleted, workspace, log: log, progress: &progress) else { return .failed }
        return .done
    }

    private static func detach(
        _ workspace: WorkspaceReconstruction,
        identity: WorkspaceDurableIdentity,
        log: URL,
        progress: inout Set<WorkspaceLifecycleRecord.Kind>
    ) -> Step {
        if progress.contains(.mountCleanupCompleted) || progress.contains(.originalRestored) {
            return .done
        }
        switch workspaceMountObservation(identity: identity, project: workspace.originalPath) {
        case .originalRestored, .missingMount:
            guard mark(.mountCleanupCompleted, workspace, log: log, progress: &progress) else { return .failed }
            return .done
        case .unrelatedMount:
            return .blocked(.unrelatedMount)
        case .savedTreeMismatch:
            return .blocked(.ambiguousSavedTree)
        case .ambiguous:
            return .blocked(.ambiguousOwnership)
        case .ownedMount:
            break
        }
        guard case .success(let snapshot) = loadSnapshot(identity) else { return .failed }
        switch WorkspaceInodeBoundary.reattach(
            project: workspace.originalPath,
            identity: identity,
            snapshot: snapshot
        ) {
        case .failure:
            return .failed
        case .success(let boundary):
            switch boundary.detachOwnedMount() {
            case .failure:
                return .failed
            case .success:
                break
            }
        }
        guard mark(.mountCleanupCompleted, workspace, log: log, progress: &progress) else { return .failed }
        return .done
    }

    private static func restore(
        _ workspace: WorkspaceReconstruction,
        identity: WorkspaceDurableIdentity,
        log: URL,
        progress: inout Set<WorkspaceLifecycleRecord.Kind>
    ) -> Step {
        if progress.contains(.originalRestored) {
            return .done
        }
        switch workspaceMountObservation(identity: identity, project: workspace.originalPath) {
        case .originalRestored:
            guard removeOwnedFile(
                path: identity.imagePath,
                device: identity.imageDevice,
                inode: identity.imageInode
            ) else { return .failed }
        case .missingMount:
            switch WorkspaceInodeBoundary.restoreHiddenOriginal(
                project: workspace.originalPath,
                identity: identity
            ) {
            case .failure:
                return .failed
            case .success:
                break
            }
        case .unrelatedMount:
            return .blocked(.unrelatedMount)
        case .ownedMount:
            return .failed
        case .savedTreeMismatch:
            return .blocked(.ambiguousSavedTree)
        case .ambiguous:
            return .blocked(.ambiguousOwnership)
        }
        guard mark(.originalRestored, workspace, log: log, progress: &progress) else { return .failed }
        return .done
    }

    private static func cleanupOwnedFiles(_ identity: WorkspaceDurableIdentity) -> Bool {
        let image = removeOwnedFile(
            path: identity.imagePath,
            device: identity.imageDevice,
            inode: identity.imageInode
        )
        let snapshot = removeOwnedFile(
            path: identity.snapshotPath,
            device: identity.snapshotDevice,
            inode: identity.snapshotInode
        )
        return image && snapshot
    }

    private static func assessWorkspace(
        _ workspace: WorkspaceReconstruction
    ) -> WorkspaceRecoveryAssessment {
        switch workspace.phase {
        case .corrupt:
            return .blocked(WorkspaceRecoveryBlock(workspace: workspace.id, reason: .corrupt))
        case .blocked(let reason):
            return .blocked(WorkspaceRecoveryBlock(workspace: workspace.id, reason: reason))
        case .closed:
            return .clean
        case .recoverable:
            break
        }
        guard let identity = workspace.identity,
            identityUsable(identity),
            savedTreeRelationship(original: workspace.originalPath, identity: identity)
        else {
            return .blocked(WorkspaceRecoveryBlock(workspace: workspace.id, reason: .ambiguousOwnership))
        }
        switch WorkspaceOwnerLock.acquire(path: identity.lockPath, create: false) {
        case .busy:
            return busyAssessment(workspace)
        case .missing, .mismatched, .unavailable:
            return .blocked(WorkspaceRecoveryBlock(workspace: workspace.id, reason: .ambiguousOwnership))
        case .acquired(let lock):
            let matches = lock.matches(
                device: identity.lockDevice,
                inode: identity.lockInode,
                token: identity.ownerToken
            )
            lock.release()
            if matches == false {
                return .blocked(WorkspaceRecoveryBlock(workspace: workspace.id, reason: .ambiguousOwnership))
            }
            return .orphaned(workspace.id)
        }
    }

    private static func busyAssessment(
        _ workspace: WorkspaceReconstruction
    ) -> WorkspaceRecoveryAssessment {
        if workspace.records.contains(where: { $0.kind == .recoveryBegan }) {
            return .recoveryInProgress(workspace.id)
        }
        return .liveOwner(workspace.id)
    }

    private static func busyOutcome(_ workspace: WorkspaceReconstruction) -> WorkspaceRecoveryOutcome {
        if workspace.records.contains(where: { $0.kind == .recoveryBegan }) {
            return .recoveryInProgress(workspace.id)
        }
        return .liveOwner(workspace.id)
    }

    private static func block(
        _ workspace: WorkspaceReconstruction,
        reason: WorkspaceRecoveryBlock.Reason,
        log: URL,
        write: Bool
    ) -> WorkspaceRecoveryOutcome {
        let recorded = workspace.records.contains {
            $0.kind == .recoveryBlocked && $0.blockReason == reason.rawValue
        }
        if write, recorded == false {
            guard append(.recoveryBlocked, workspace, to: log, reason: reason.rawValue) else {
                return .failed
            }
        }
        return .blocked(WorkspaceRecoveryBlock(workspace: workspace.id, reason: reason))
    }

    private static func has(
        _ kind: WorkspaceLifecycleRecord.Kind,
        _ workspace: WorkspaceReconstruction
    ) -> Bool {
        workspace.records.contains { $0.kind == kind }
    }

    @discardableResult
    private static func mark(
        _ kind: WorkspaceLifecycleRecord.Kind,
        _ workspace: WorkspaceReconstruction,
        log: URL,
        progress: inout Set<WorkspaceLifecycleRecord.Kind>
    ) -> Bool {
        if progress.contains(kind) { return true }
        guard append(kind, workspace, to: log) else { return false }
        progress.insert(kind)
        return true
    }

    private static func append(
        _ kind: WorkspaceLifecycleRecord.Kind,
        _ workspace: WorkspaceReconstruction,
        to url: URL,
        reason: String? = nil
    ) -> Bool {
        let record = WorkspaceLifecycleRecord(
            kind: kind,
            workspace: workspace.id,
            originalPath: workspace.originalPath,
            protectedPath: workspace.protectedPath,
            volumeDevice: workspace.identity?.volumeDevice ?? workspace.records.first?.volumeDevice,
            disk: workspace.identity?.disk ?? workspace.records.first?.disk,
            runtime: nil,
            recordedAt: Date(),
            identity: workspace.identity,
            blockReason: reason
        )
        guard case .success = WorkspaceLifecycleLog.append(record, to: url) else { return false }
        return true
    }

    private static func sessionError(_ outcome: WorkspaceRecoveryOutcome) -> WorkspaceSessionError {
        switch outcome {
        case .liveOwner(let id):
            return .ownedByLiveProcess(id)
        case .recoveryInProgress(let id):
            return .recoveryInProgress(id)
        case .blocked(let block):
            return .unresolvedWorkspace(block)
        case .clean, .recovered, .interrupted:
            return .apply(.workspaceInodeBoundaryFailed)
        case .failed:
            return .cleanupFailed(.workspaceInodeBoundaryFailed)
        }
    }

    private static func outcome(
        for claim: WorkspaceOwnerRegistry.Claim,
        path: String,
        log: URL
    ) -> WorkspaceRecoveryOutcome {
        switch claim {
        case .owner(let id):
            return .liveOwner(id)
        case .opening:
            if case .workspace(let workspace) = history(canonicalPath: path, log: log),
                workspace.records.contains(where: { $0.kind == .recoveryBegan })
            {
                return .recoveryInProgress(workspace.id)
            }
            return .liveOwner(nil)
        }
    }

    private static func assessment(
        for claim: WorkspaceOwnerRegistry.Claim,
        path: String,
        log: URL
    ) -> WorkspaceRecoveryAssessment {
        switch outcome(for: claim, path: path, log: log) {
        case .liveOwner(let id):
            return .liveOwner(id)
        case .recoveryInProgress(let id):
            return .recoveryInProgress(id)
        case .blocked(let block):
            return .blocked(block)
        case .clean, .recovered, .interrupted, .failed:
            return .liveOwner(nil)
        }
    }

    private static func canonicalProject(_ workspace: WorkingDirectory) -> String? {
        switch existingResolvedWorkspacePath(workspace) {
        case .success(let path):
            return path
        case .failure:
            guard workspace.rawValue.hasPrefix("/"), workspace.rawValue.contains("\0") == false else {
                return nil
            }
            return workspace.rawValue
        }
    }

    private enum History {
        case unreadable
        case corrupt
        case torn
        case clean
        case workspace(WorkspaceReconstruction)
    }

    private static func history(canonicalPath: String, log: URL) -> History {
        switch WorkspaceLifecycleLog.load(at: log) {
        case .unreadable:
            return .unreadable
        case .missing:
            return .clean
        case .decoded(let read):
            if read.interiorCorruption { return .corrupt }
            let matching = reconstruct(read.records).filter { sameProject($0.originalPath, canonicalPath) }
            let open = matching.filter { $0.phase != .closed }
            if open.count > 1 { return .corrupt }
            if let workspace = open.first { return .workspace(workspace) }
            if read.tornTrailing { return .torn }
            return .clean
        }
    }

    private static func sameProject(_ recorded: String, _ canonical: String) -> Bool {
        if recorded == canonical { return true }
        if let resolved = posixRealpath(recorded), resolved == canonical { return true }
        return false
    }
}

extension WorkspaceRecovery {
    fileprivate struct WorkspaceReconstruction: Equatable {
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

    fileprivate static func reconstruct(
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

    private static func reconstruction(
        id: UUID,
        records: [WorkspaceLifecycleRecord]
    ) -> WorkspaceReconstruction {
        var original = ""
        var protected = ""
        var identity: WorkspaceDurableIdentity?
        var groups: [UUID: RecordedProcessGroup] = [:]
        var malformedGroup = false
        var created = 0
        var phase = WorkspaceReconstruction.Phase.recoverable
        var paths = Set<String>()
        for record in records {
            if record.originalPath.isEmpty == false {
                paths.insert(record.originalPath)
                if original.isEmpty { original = record.originalPath }
            }
            if record.protectedPath.isEmpty == false, protected.isEmpty {
                protected = record.protectedPath
            }
            switch record.kind {
            case .created:
                created += 1
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
                    rawGroup > 1,
                    rawGroup <= Int64(Int32.max)
                else {
                    malformedGroup = true
                    continue
                }
                let group = RecordedProcessGroup(
                    runtime: runtime,
                    pgid: Int32(rawGroup),
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
                .mountCleanupCompleted, .originalRestored:
                break
            }
        }
        if created != 1 || paths.count > 1 || original.isEmpty || protected.isEmpty {
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

    private static func savedTreeRelationship(
        original: String,
        identity: WorkspaceDurableIdentity
    ) -> Bool {
        let parent = (original as NSString).deletingLastPathComponent
        let savedParent = (identity.savedPath as NSString).deletingLastPathComponent
        let savedName = (identity.savedPath as NSString).lastPathComponent
        let quarantineParent = (identity.quarantinePath as NSString).deletingLastPathComponent
        let quarantineName = (identity.quarantinePath as NSString).lastPathComponent
        return parent == savedParent
            && parent == quarantineParent
            && savedName.hasPrefix(".rv-saved-")
            && quarantineName.hasPrefix(".rv-quarantine-")
            && identity.savedPath != original
            && identity.quarantinePath != original
            && identity.savedPath != identity.quarantinePath
    }

    private static func identityUsable(_ identity: WorkspaceDurableIdentity) -> Bool {
        identity.savedPath.hasPrefix("/")
            && identity.lockPath.hasPrefix("/")
            && identity.snapshotPath.hasPrefix("/")
            && identity.disk.hasPrefix("/dev/")
            && identity.mountSource.isEmpty == false
            && identity.volumeDevice != 0
            && identity.ownerToken.uuidString.isEmpty == false
    }

    private static func workspaceMountObservation(
        identity: WorkspaceDurableIdentity,
        project: String
    ) -> WorkspaceMountObservation {
        RVIsolationMount.observe(
            project: project,
            savedPath: identity.savedPath,
            savedDevice: identity.savedDevice,
            savedInode: identity.savedInode,
            volumeDevice: identity.volumeDevice,
            mountSource: identity.mountSource
        )
    }

    static func writeSnapshot(
        _ snapshot: [String: WorkspaceInodeStamp],
        to url: URL
    ) -> Result<(device: UInt64, inode: UInt64), IsolationApplyError> {
        let entries = snapshot.keys.sorted().map { path in
            let stamp = snapshot[path]
            return SnapshotFile.Entry(
                path: path,
                device: stamp?.device ?? 0,
                inode: stamp?.inode ?? 0,
                linkCount: stamp?.linkCount ?? 0,
                kind: kindName(stamp?.kind)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(SnapshotFile(entries: entries)) else {
            return .failure(.sessionRecordFailed)
        }
        return writeExclusiveFile(data, to: url)
    }

    private static func loadSnapshot(
        _ identity: WorkspaceDurableIdentity
    ) -> Result<[String: WorkspaceInodeStamp], IsolationApplyError> {
        var status = stat()
        guard identity.snapshotPath.withCString({ lstat($0, &status) == 0 }),
            UInt64(status.st_dev) == identity.snapshotDevice,
            UInt64(status.st_ino) == identity.snapshotInode,
            (status.st_mode & S_IFMT) == S_IFREG
        else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: identity.snapshotPath)),
            let file = try? JSONDecoder().decode(SnapshotFile.self, from: data)
        else {
            return .failure(.workspaceInodeBoundaryFailed)
        }
        var snapshot: [String: WorkspaceInodeStamp] = [:]
        for entry in file.entries {
            guard let kind = kind(entry.kind), snapshot[entry.path] == nil else {
                return .failure(.workspaceInodeBoundaryFailed)
            }
            snapshot[entry.path] = WorkspaceInodeStamp(
                device: entry.device,
                inode: entry.inode,
                linkCount: entry.linkCount,
                kind: kind
            )
        }
        return .success(snapshot)
    }

    private static func removeOwnedFile(path: String?, device: UInt64?, inode: UInt64?) -> Bool {
        guard let path, let device, let inode else { return true }
        var status = stat()
        let exists = path.withCString { lstat($0, &status) == 0 }
        if exists == false { return true }
        guard UInt64(status.st_dev) == device,
            UInt64(status.st_ino) == inode,
            (status.st_mode & S_IFMT) == S_IFREG
        else {
            return true
        }
        return path.withCString { unlink($0) == 0 }
    }

    private static func writeExclusiveFile(
        _ data: Data,
        to url: URL
    ) -> Result<(device: UInt64, inode: UInt64), IsolationApplyError> {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.sessionRecordFailed)
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = temporary.path.withCString { open($0, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { return .failure(.sessionRecordFailed) }
        var failed = false
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            failed = true
            break
        }
        if failed == false, fsync(fd) != 0 { failed = true }
        close(fd)
        if failed {
            _ = temporary.path.withCString { unlink($0) }
            return .failure(.sessionRecordFailed)
        }
        let renamed = temporary.path.withCString { from in
            url.path.withCString { to in
                rename(from, to) == 0
            }
        }
        guard renamed else {
            _ = temporary.path.withCString { unlink($0) }
            return .failure(.sessionRecordFailed)
        }
        let final = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard final >= 0 else { return .failure(.sessionRecordFailed) }
        defer { close(final) }
        if fsync(final) != 0 { return .failure(.sessionRecordFailed) }
        var status = stat()
        guard fstat(final, &status) == 0 else { return .failure(.sessionRecordFailed) }
        let parent = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        if parent >= 0 {
            _ = fsync(parent)
            close(parent)
        }
        return .success((device: UInt64(status.st_dev), inode: UInt64(status.st_ino)))
    }

    private struct SnapshotFile: Codable {
        struct Entry: Codable {
            var path: String
            var device: UInt64
            var inode: UInt64
            var linkCount: UInt64
            var kind: String
        }

        var entries: [Entry]
    }

    private static func kindName(_ kind: WorkspaceInodeStamp.Kind?) -> String {
        switch kind {
        case .directory:
            return "directory"
        case .regular:
            return "regular"
        case .symlink:
            return "symlink"
        case nil:
            return ""
        }
    }

    private static func kind(_ name: String) -> WorkspaceInodeStamp.Kind? {
        switch name {
        case "directory":
            return .directory
        case "regular":
            return .regular
        case "symlink":
            return .symlink
        default:
            return nil
        }
    }
}

/// Mount observation shared by recovery and the inode boundary.
enum WorkspaceMountObservation: Equatable, Sendable {
    case ownedMount
    case missingMount
    case originalRestored
    case unrelatedMount
    case savedTreeMismatch
    case ambiguous
}

enum RVIsolationMount {
    static func observe(
        project: String,
        savedPath: String,
        savedDevice: UInt64,
        savedInode: UInt64,
        volumeDevice: UInt64,
        mountSource: String
    ) -> WorkspaceMountObservation {
        let saved = workspacePathIdentity(savedPath)
        let projectIdentity = workspacePathIdentity(project)
        let facts = workspaceMountFacts(project)
        let savedMatches = saved?.device == savedDevice && saved?.inode == savedInode && saved?.isDirectory == true
        let projectIsSaved = projectIdentity?.device == savedDevice
            && projectIdentity?.inode == savedInode
            && projectIdentity?.isDirectory == true
        let ownedDevice = projectIdentity?.device == volumeDevice
        let ownedSource = facts?.source == mountSource
        let projectCanonical = posixRealpath(project) ?? project
        let pointCanonical = facts.map { posixRealpath($0.point) ?? $0.point }
        let mountedHere = pointCanonical == projectCanonical
        if ownedDevice && ownedSource {
            return savedMatches ? .ownedMount : .savedTreeMismatch
        }
        if mountedHere {
            return .unrelatedMount
        }
        if projectIsSaved && saved == nil {
            return .originalRestored
        }
        if savedMatches {
            return .missingMount
        }
        if saved != nil {
            return .savedTreeMismatch
        }
        return .ambiguous
    }
}
#endif
