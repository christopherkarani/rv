#if os(macOS)
import Darwin
import Synchronization
#endif
import Foundation
import RVDomain

/// Why a workspace operation stopped.
///
/// Spawn, publish, and unmount failures stay `IsolationApplyError` values.
/// The other cases are workspace lifetime failures: the process was not
/// started, or close refused to publish because a child was still alive.
public enum WorkspaceSessionError: Error, Sendable, Equatable {
    case apply(IsolationApplyError)
    /// Close has been accepted, or the workspace is not active. No process was spawned.
    case notAcceptingRuntime(WorkspaceLifecycle)
    /// A child process group was still alive. The workspace was not published.
    case childTeardownFailed
    case cleanupFailed(IsolationApplyError)
    case alreadyClosed
    case unknownRuntime(RuntimeSessionID)
    /// Another live RV process holds this project. No second workspace was created.
    case ownedByLiveProcess(UUID?)
    /// Recovery is already running for this project.
    case recoveryInProgress(UUID)
    /// The previous workspace cannot be reclaimed automatically.
    case unresolvedWorkspace(WorkspaceRecoveryBlock)
}

enum WorkspaceSessionFailure {
    static func isolation(_ error: WorkspaceSessionError) -> IsolationApplyError {
        switch error {
        case .apply(let error), .cleanupFailed(let error):
            error
        case .childTeardownFailed:
            .lifetimeBoundaryFailed
        case .notAcceptingRuntime, .alreadyClosed, .unknownRuntime:
            .workspaceInodeBoundaryFailed
        case .ownedByLiveProcess:
            .workspaceUnresolved("liveOwner")
        case .recoveryInProgress:
            .workspaceUnresolved("recoveryInProgress")
        case .unresolvedWorkspace(let block):
            .workspaceUnresolved(block.reason.rawValue)
        }
    }
}

/// A runtime that has passed the Seatbelt handshake and is still the
/// workspace's responsibility until it exits or the workspace closes.
public struct RunningRuntime: Sendable {
    public let session: RuntimeSession
    let capability: RuntimeCapability

    public var id: RuntimeSessionID { session.id }
}

/// Identity of a descriptor RV still holds. A runtime must not have this
/// device and inode open.
struct WorkspaceControlFile: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
}

/// The one owner of a protected workspace.
///
/// The private volume, publish, and child registration are serialized on
/// this object's lock. Child waits run on the caller's thread for a
/// single-runtime launch, so Swift task cancellation is visible, and on an
/// owned thread for every additional runtime. Those threads are retained
/// until the process group is dead. There is no process-wide workspace table.
public final class WorkspaceSessionSupervisor: @unchecked Sendable {
    #if os(macOS)
    private struct State: Sendable {
        var lifecycle: WorkspaceLifecycle
        var closeAccepted = false
        var closeLeader = false
        var children: [RuntimeSessionID: WorkspaceChild] = [:]
        var publishCount = 0
        var finishedClose: Result<Void, WorkspaceSessionError>?
        var recordError: IsolationApplyError?
        var abandoned = false
    }

    private enum CloseRole {
        case lead(publish: Bool)
        case wait
        case finished(Result<Void, WorkspaceSessionError>)
    }

    public let id: WorkspaceSessionID
    private let original: WorkingDirectory
    private let protected: WorkingDirectory
    private let createdAt: Date
    private let boundary: WorkspaceInodeBoundary
    private let lifecycleLog: WorkspaceLifecycleStore
    private let ownerLock: WorkspaceOwnerLock
    private let state: Mutex<State>

    private init(
        id: WorkspaceSessionID,
        original: WorkingDirectory,
        protected: WorkingDirectory,
        createdAt: Date,
        boundary: WorkspaceInodeBoundary,
        lifecycleLog: WorkspaceLifecycleStore,
        ownerLock: WorkspaceOwnerLock
    ) {
        self.id = id
        self.original = original
        self.protected = protected
        self.createdAt = createdAt
        self.boundary = boundary
        self.lifecycleLog = lifecycleLog
        self.ownerLock = ownerLock
        self.state = Mutex(State(lifecycle: .creating))
    }
    #endif

    /// Open a protected workspace at `workspace`.
    ///
    /// On failure the workspace is not active. Linux refuses before a mount.
    public static func open(
        _ workspace: WorkingDirectory
    ) -> Result<WorkspaceSessionSupervisor, WorkspaceSessionError> {
        #if os(macOS)
        return open(workspace, lifecycleLog: .production)
        #else
        return .failure(.apply(.containedGuaranteesUnsupported))
        #endif
    }

    #if os(macOS)
    static func open(
        _ workspace: WorkingDirectory,
        lifecycleLog: WorkspaceLifecycleStore,
        runtimeLog: URL? = nil
    ) -> Result<WorkspaceSessionSupervisor, WorkspaceSessionError> {
        let resolved: String
        switch existingResolvedWorkspacePath(workspace) {
        case .failure(let error):
            return .failure(.apply(error))
        case .success(let path):
            resolved = path
        }
        guard let directory = WorkingDirectory(validating: resolved) else {
            return .failure(.apply(.workspacePathUnresolvable))
        }
        guard let lifeURL = lifecycleLog.file else {
            return .failure(.apply(.sessionRecordFailed))
        }
        let sessions = runtimeLog ?? RuntimeSessionLog.productionURL()
        guard let sessions else {
            return .failure(.apply(.sessionRecordFailed))
        }
        let ownerLock: WorkspaceOwnerLock
        switch WorkspaceRecovery.admit(
            canonicalPath: resolved,
            lifecycleLog: lifeURL,
            runtimeLog: sessions
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let lock):
            ownerLock = lock
        }
        func releaseAdmission(owner: UUID?) {
            if let owner {
                WorkspaceOwnerRegistry.remove(path: resolved, owner: owner)
            } else {
                WorkspaceOwnerRegistry.cancelOpening(resolved)
            }
            ownerLock.release()
        }
        func failOpen(
            _ boundary: WorkspaceInodeBoundary,
            owner: UUID
        ) -> Result<WorkspaceSessionSupervisor, WorkspaceSessionError> {
            switch boundary.discardAndRestore() {
            case .failure(let cleanup):
                releaseAdmission(owner: owner)
                return .failure(.cleanupFailed(cleanup))
            case .success:
                releaseAdmission(owner: owner)
                return .failure(.apply(.sessionRecordFailed))
            }
        }
        switch rejectWorkspaceInodeAlias(resolved) {
        case .failure(let error):
            releaseAdmission(owner: nil)
            return .failure(.apply(error))
        case .success:
            break
        }
        if Task.isCancelled {
            releaseAdmission(owner: nil)
            return .failure(.apply(.cancelled))
        }
        let boundary: WorkspaceInodeBoundary
        switch establishWorkspaceInodeBoundary(at: resolved) {
        case .failure(let error):
            releaseAdmission(owner: nil)
            return .failure(.apply(error))
        case .success(let established):
            boundary = established
        }
        guard boundary.remainsEstablished() else {
            _ = boundary.discardAndRestore()
            releaseAdmission(owner: nil)
            return .failure(.apply(.workspaceInodeBoundaryFailed))
        }
        let id = WorkspaceSessionID()
        guard WorkspaceOwnerRegistry.adopt(resolved, owner: id.rawValue) else {
            _ = boundary.discardAndRestore()
            WorkspaceOwnerRegistry.cancelOpening(resolved)
            ownerLock.release()
            return .failure(.apply(.workspaceInodeBoundaryFailed))
        }
        let createdAt = Date()
        let snapshotFile = WorkspaceRecovery.snapshotURL(
            directory: lifeURL.deletingLastPathComponent(),
            id: id.rawValue
        )
        let snapshotIdentity: (device: UInt64, inode: UInt64)
        switch WorkspaceRecovery.writeSnapshot(boundary.snapshotStamps(), to: snapshotFile) {
        case .failure:
            return failOpen(boundary, owner: id.rawValue)
        case .success(let identity):
            snapshotIdentity = identity
        }
        guard let token = ownerLock.token else {
            _ = removeSnapshot(snapshotFile.path, device: snapshotIdentity.device, inode: snapshotIdentity.inode)
            return failOpen(boundary, owner: id.rawValue)
        }
        let durable = boundary.recoveryIdentity(
            lockPath: ownerLock.path,
            lockDevice: ownerLock.device,
            lockInode: ownerLock.inode,
            ownerToken: token,
            snapshotPath: snapshotFile.path,
            snapshotDevice: snapshotIdentity.device,
            snapshotInode: snapshotIdentity.inode
        )
        let recorded = lifecycleLog.append(
            WorkspaceLifecycleRecord(
                kind: .created,
                workspace: id.rawValue,
                originalPath: directory.rawValue,
                protectedPath: directory.rawValue,
                volumeDevice: durable.volumeDevice,
                disk: durable.disk,
                runtime: nil,
                recordedAt: createdAt,
                identity: durable
            )
        )
        if case .failure(let error) = recorded {
            _ = removeSnapshot(snapshotFile.path, device: snapshotIdentity.device, inode: snapshotIdentity.inode)
            switch boundary.discardAndRestore() {
            case .failure(let cleanup):
                releaseAdmission(owner: id.rawValue)
                return .failure(.cleanupFailed(cleanup))
            case .success:
                releaseAdmission(owner: id.rawValue)
                return .failure(.apply(error))
            }
        }
        let supervisor = WorkspaceSessionSupervisor(
            id: id,
            original: directory,
            protected: directory,
            createdAt: createdAt,
            boundary: boundary,
            lifecycleLog: lifecycleLog,
            ownerLock: ownerLock
        )
        let activated = supervisor.state.withLock { state -> Bool in
            guard let active = state.lifecycle.transition(.becameActive) else { return false }
            state.lifecycle = active
            return true
        }
        guard activated else {
            switch boundary.discardAndRestore() {
            case .success:
                _ = lifecycleLog.append(
                    WorkspaceLifecycleRecord(
                        kind: .closed,
                        workspace: id.rawValue,
                        originalPath: directory.rawValue,
                        protectedPath: directory.rawValue,
                        volumeDevice: durable.volumeDevice,
                        disk: durable.disk,
                        runtime: nil,
                        recordedAt: Date(),
                        identity: durable
                    )
                )
            case .failure:
                break
            }
            releaseAdmission(owner: id.rawValue)
            return .failure(.apply(.workspaceInodeBoundaryFailed))
        }
        return .success(supervisor)
    }

    /// Drop the kernel lock without publishing. Tests use this to simulate process death.
    func abandonForCrashSimulation() {
        state.withLock { $0.abandoned = true }
        WorkspaceOwnerRegistry.remove(path: original.rawValue, owner: id.rawValue)
        ownerLock.release()
    }

    deinit {
        let abandoned = state.withLock { $0.abandoned }
        if abandoned {
            let children = state.withLock { Array($0.children.values) }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, children.contains(where: { $0.watchFinished == false }) {
                usleep(10_000)
            }
            ownerLock.release()
            return
        }
        let children = state.withLock { Array($0.children.values) }
        for child in children {
            child.stop.request()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, children.contains(where: { $0.watchFinished == false }) {
            usleep(10_000)
        }
        let discard = state.withLock { state -> Bool in
            // A close that never reached `.closed` leaves the volume mounted.
            // Dropping the supervisor puts the original directory back once
            // every child is gone. A successful close has already released it.
            guard state.lifecycle != .closed, boundary.isReleased == false else {
                return false
            }
            return children.allSatisfy { $0.watchFinished && $0.isProcessGone }
        }
        if discard {
            _ = boundary.discardAndRestore()
        }
        WorkspaceOwnerRegistry.remove(path: original.rawValue, owner: id.rawValue)
        ownerLock.release()
    }

    public var snapshot: RVWorkspaceSession {
        state.withLock { state in
            RVWorkspaceSession(
                id: id,
                originalPath: original,
                protectedPath: protected,
                createdAt: createdAt,
                phase: state.lifecycle,
                policyWorkspace: original
            )
        }
    }

    var protectedPath: String { protected.rawValue }
    var volumeDevice: UInt64 { boundary.volumeDeviceIdentifier }
    var publishCount: Int { state.withLock { $0.publishCount } }

    /// Start one contained runtime inside this workspace.
    ///
    /// Returns after the Seatbelt handshake. The process keeps running.
    /// A second call does not create another volume.
    public func launch(
        host: HookHost?,
        command: IsolatedCommand,
        plan: ContainedPlan,
        io: IsolatedIO = .discard,
        admission: RuntimeAdmissionConfiguration = .failClosed
    ) -> Result<RunningRuntime, WorkspaceSessionError> {
        launch(
            host: host,
            command: command,
            plan: plan,
            io: io,
            admission: admission,
            sessionStore: .production
        )
    }

    func launch(
        host: HookHost?,
        command: IsolatedCommand,
        plan: ContainedPlan,
        io: IsolatedIO,
        admission: RuntimeAdmissionConfiguration,
        sessionStore: RuntimeSessionStore
    ) -> Result<RunningRuntime, WorkspaceSessionError> {
        let request: IsolatedLaunchRequest
        switch prepareSeatbelt(plan.isolationPlan(), command) {
        case .failure(let error):
            return .failure(.apply(error))
        case .success(let prepared):
            request = prepared.withIO(io)
        }
        guard request.containedWorkspacePath == protected.rawValue else {
            return .failure(.apply(.workspacePathUnresolvable))
        }
        let spawned: Result<WorkspaceChild, WorkspaceSessionError> = spawn(
            request,
            host: host,
            sessionStore: sessionStore,
            admission: admission,
            register: true
        )
        switch spawned {
        case .failure(let error):
            return .failure(error)
        case .success(let child):
            let session = child.live.session
            child.start {
                self.noteRuntimeEnded(session)
            }
            return waitUntilEstablished(child)
        }
    }

    /// One runtime, watched on the caller's thread, then the caller closes.
    func runSingleRuntime(
        _ request: IsolatedLaunchRequest,
        host: HookHost?,
        sessionStore: RuntimeSessionStore,
        admission: RuntimeAdmissionConfiguration
    ) -> MountedSeatbeltOutcome {
        switch spawn(
            request,
            host: host,
            sessionStore: sessionStore,
            admission: admission,
            register: false
        ) {
        case .failure(let error):
            return MountedSeatbeltOutcome(
                result: .failure(WorkspaceSessionFailure.isolation(error)),
                publish: false
            )
        case .success(let child):
            let mounted = watchSeatbeltProcess(child.live, stop: child.stop)
            noteRuntimeEnded(child.live.session)
            return mounted
        }
    }

    func finishSingleRuntime(publish: Bool) -> Result<Void, IsolationApplyError> {
        switch finish(publish: publish) {
        case .success:
            return .success(())
        case .failure(let error):
            return .failure(WorkspaceSessionFailure.isolation(error))
        }
    }

    /// Stop one runtime. The workspace stays mounted and is not published.
    public func cancel(
        _ runtime: RuntimeSessionID
    ) -> Result<Void, WorkspaceSessionError> {
        let child = state.withLock { state -> WorkspaceChild? in
            guard state.lifecycle == .active || state.lifecycle == .closing else { return nil }
            return state.children[runtime]
        }
        guard let child else { return .failure(.unknownRuntime(runtime)) }
        child.stop.request()
        guard waitForChildren([child], seconds: 45) else {
            return .failure(.childTeardownFailed)
        }
        return .success(())
    }

    /// Stop every runtime, publish once, and remove the private volume.
    public func close() -> Result<Void, WorkspaceSessionError> {
        if state.withLock({ $0.abandoned }) {
            return .failure(.alreadyClosed)
        }
        return finish(publish: true)
    }

    func savedFile(_ relative: String) -> Data? {
        boundary.savedFileData(relative)
    }

    func controlFiles() -> [WorkspaceControlFile] {
        var descriptors = boundary.heldDescriptors()
        let children = state.withLock { Array($0.children.values) }
        for child in children {
            descriptors.append(contentsOf: child.live.parentDescriptors)
        }
        return descriptors.compactMap(controlFile(of:))
    }

    func submit(
        _ frame: RuntimeActionFrame,
        to runtime: RuntimeSessionID
    ) -> RuntimeAdmissionDecision? {
        let child = state.withLock { $0.children[runtime] }
        guard let child else { return nil }
        if child.watchFinished {
            return child.live.admission.submit(.success(frame))
        }
        return child.live.submit(frame)
    }

    private func spawn(
        _ request: IsolatedLaunchRequest,
        host: HookHost?,
        sessionStore: RuntimeSessionStore,
        admission: RuntimeAdmissionConfiguration,
        register: Bool
    ) -> Result<WorkspaceChild, WorkspaceSessionError> {
        guard let profile = request.seatbeltProfile,
            let workspace = request.containedWorkspacePath
        else {
            return .failure(.apply(.containedGuaranteesUnsupported))
        }
        let slot = WorkspaceChildSlot()
        let result: Result<Void, WorkspaceSessionError> = state.withLock { state in
            guard state.closeAccepted == false, state.lifecycle.acceptsRuntime else {
                return .failure(.notAcceptingRuntime(state.lifecycle))
            }
            let session = RuntimeSession(
                id: RuntimeSessionID(),
                workspaceSessionID: id,
                host: host,
                workspace: original,
                backend: .seatbelt,
                startedAt: Date(),
                child: nil
            )
            switch sessionStore.append(session) {
            case .failure(let error):
                return .failure(.apply(error))
            case .success:
                slot.logged = session
            }
            switch spawnSeatbeltProcess(
                request,
                workspace: workspace,
                profile: profile,
                boundary: boundary,
                started: session,
                admission: admission
            ) {
            case .failure(let error):
                return .failure(.apply(error))
            case .success(let live):
                let child = WorkspaceChild(live: live)
                if register {
                    state.children[live.session.id] = child
                }
                slot.child = child
                return .success(())
            }
        }
        switch result {
        case .failure(let error):
            if slot.child == nil, let session = slot.logged {
                noteRuntimeEnded(session)
            }
            return .failure(error)
        case .success:
            guard let child = slot.child else {
                return .failure(.apply(.processSpawnFailed))
            }
            switch recordProcessGroup(child) {
            case .failure(let error):
                retireUnrecorded(child)
                return .failure(error)
            case .success:
                return .success(child)
            }
        }
    }

    private func recordProcessGroup(
        _ child: WorkspaceChild
    ) -> Result<Void, WorkspaceSessionError> {
        guard let fact = ProcessGroupRecovery.capture(pid: child.live.pid) else {
            return .failure(.apply(.lifetimeBoundaryFailed))
        }
        child.provenGroup = fact
        let recorded = lifecycleLog.append(
            WorkspaceLifecycleRecord(
                kind: .runtimeStarted,
                workspace: id.rawValue,
                originalPath: original.rawValue,
                protectedPath: protected.rawValue,
                volumeDevice: boundary.volumeDeviceIdentifier,
                disk: boundary.diskIdentifier,
                runtime: child.live.session.id.rawValue,
                recordedAt: Date(),
                processGroup: Int64(fact.pgid),
                processStartSeconds: fact.startSeconds,
                processStartMicroseconds: fact.startMicroseconds
            )
        )
        if case .failure(let error) = recorded {
            return .failure(.apply(error))
        }
        return .success(())
    }

    private func retireUnrecorded(_ child: WorkspaceChild) {
        let session = child.live.session
        let pid = child.live.pid
        state.withLock { state in
            state.children[session.id] = nil
        }
        if let fact = child.provenGroup {
            _ = ProcessGroupRecovery.terminate(
                RecordedProcessGroup(
                    runtime: session.id.rawValue,
                    pgid: fact.pgid,
                    startSeconds: fact.startSeconds,
                    startMicroseconds: fact.startMicroseconds
                )
            )
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if processGroupIsEmpty(pid), processIsGone(pid) { break }
            usleep(10_000)
        }
        noteRuntimeEnded(session)
    }

    private func waitUntilEstablished(
        _ child: WorkspaceChild
    ) -> Result<RunningRuntime, WorkspaceSessionError> {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if Task.isCancelled {
                child.stop.request()
            }
            if child.live.isEstablished {
                return .success(
                    RunningRuntime(session: child.live.session, capability: child.live.capability)
                )
            }
            if child.watchFinished {
                if child.live.isEstablished {
                    return .success(
                        RunningRuntime(session: child.live.session, capability: child.live.capability)
                    )
                }
                return .failure(.apply(child.live.terminalError ?? .seatbeltNotEstablished))
            }
            usleep(10_000)
        }
        child.stop.request()
        _ = waitForChildren([child], seconds: 45)
        return .failure(.apply(child.live.terminalError ?? .seatbeltNotEstablished))
    }

    private func finish(publish: Bool) -> Result<Void, WorkspaceSessionError> {
        if state.withLock({ $0.abandoned }) {
            return .failure(.alreadyClosed)
        }
        let role: CloseRole = state.withLock { state in
            if let finished = state.finishedClose {
                return .finished(finished)
            }
            if state.lifecycle == .closed {
                return .finished(.failure(.alreadyClosed))
            }
            if state.closeLeader {
                return .wait
            }
            if state.lifecycle == .active {
                guard let closing = state.lifecycle.transition(.beginClose) else {
                    return .finished(.failure(.notAcceptingRuntime(state.lifecycle)))
                }
                state.lifecycle = closing
            } else if state.lifecycle != .closing {
                return .finished(.failure(.notAcceptingRuntime(state.lifecycle)))
            }
            state.closeLeader = true
            state.closeAccepted = true
            return .lead(publish: publish)
        }
        switch role {
        case .finished(let result):
            return result
        case .wait:
            return waitForLeader()
        case .lead(let publish):
            let result = performFinish(publish: publish)
            state.withLock { state in
                if case .failure(.childTeardownFailed) = result {
                    // The children may die after this wait. A later close has
                    // to be able to publish; caching this failure would not.
                    state.closeLeader = false
                } else {
                    state.finishedClose = result
                }
            }
            return result
        }
    }

    private func performFinish(publish: Bool) -> Result<Void, WorkspaceSessionError> {
        let children = state.withLock { Array($0.children.values) }
        for child in children {
            child.stop.request()
        }
        guard waitForChildren(children, seconds: 45) else {
            return .failure(.childTeardownFailed)
        }
        if publish {
            state.withLock { $0.publishCount += 1 }
        }
        let restored = publish ? boundary.publishAndRestore() : boundary.discardAndRestore()
        switch restored {
        case .failure(let error):
            return .failure(.cleanupFailed(error))
        case .success:
            break
        }
        state.withLock { state in
            if let closed = state.lifecycle.transition(.becameClosed) {
                state.lifecycle = closed
            }
        }
        let logged = lifecycleLog.append(
            WorkspaceLifecycleRecord(
                kind: .closed,
                workspace: id.rawValue,
                originalPath: original.rawValue,
                protectedPath: protected.rawValue,
                volumeDevice: boundary.volumeDeviceIdentifier,
                disk: boundary.diskIdentifier,
                runtime: nil,
                recordedAt: Date()
            )
        )
        if case .failure(let error) = logged {
            return .failure(.apply(error))
        }
        WorkspaceOwnerRegistry.remove(path: original.rawValue, owner: id.rawValue)
        ownerLock.release()
        if let recordError = state.withLock({ $0.recordError }) {
            return .failure(.apply(recordError))
        }
        return .success(())
    }

    private func waitForLeader() -> Result<Void, WorkspaceSessionError> {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let finished = state.withLock { state -> Result<Void, WorkspaceSessionError>? in
                if let finished = state.finishedClose {
                    return finished
                }
                // The leader stopped without publishing. Concurrent waiters
                // must observe that failure instead of waiting out the timeout.
                if state.closeLeader == false, state.lifecycle == .closing {
                    return .failure(.childTeardownFailed)
                }
                return nil
            }
            if let finished {
                return finished
            }
            usleep(10_000)
        }
        return .failure(.cleanupFailed(.workspaceInodeBoundaryFailed))
    }

    private func waitForChildren(_ children: [WorkspaceChild], seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if children.allSatisfy({ $0.watchFinished && $0.isProcessGone }) {
                return true
            }
            usleep(10_000)
        }
        return children.allSatisfy { $0.watchFinished && $0.isProcessGone }
    }

    private func noteRuntimeEnded(_ session: RuntimeSession) {
        let recorded = lifecycleLog.append(
            WorkspaceLifecycleRecord(
                kind: .runtimeEnded,
                workspace: id.rawValue,
                originalPath: original.rawValue,
                protectedPath: protected.rawValue,
                volumeDevice: boundary.volumeDeviceIdentifier,
                disk: boundary.diskIdentifier,
                runtime: session.id.rawValue,
                recordedAt: Date()
            )
        )
        if case .failure(let error) = recorded {
            state.withLock { state in
                if state.recordError == nil {
                    state.recordError = error
                }
            }
        }
    }

    func ownerCredential() -> WorkspaceOwnerCredential? {
        guard let token = ownerLock.token else { return nil }
        return WorkspaceOwnerCredential(
            token: token,
            lockPath: ownerLock.path,
            lockDevice: ownerLock.device,
            lockInode: ownerLock.inode
        )
    }

    /// Runtimes this workspace owns. No capability, pid, or process group.
    func runtimeFacts() -> [WorkspaceRuntimeFact] {
        state.withLock { state in
            state.children.map { _, child in
                WorkspaceRuntimeFact(
                    id: child.live.session.id.rawValue,
                    hookHost: child.live.session.host?.rawValue,
                    running: child.watchFinished == false
                )
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    func cancel(runtime rawValue: UUID) -> Result<Void, WorkspaceSessionError> {
        let named = RuntimeSessionID(rawValue: rawValue)
        let known = state.withLock { $0.children[named] != nil }
        guard known else { return .failure(.unknownRuntime(named)) }
        return cancel(named)
    }

    func recordHostStarted(_ host: UUID) -> Bool {
        let recorded = lifecycleLog.append(
            WorkspaceLifecycleRecord(
                kind: .hostStarted,
                workspace: id.rawValue,
                originalPath: original.rawValue,
                protectedPath: protected.rawValue,
                volumeDevice: boundary.volumeDeviceIdentifier,
                disk: boundary.diskIdentifier,
                runtime: nil,
                recordedAt: Date(),
                host: host
            )
        )
        if case .failure = recorded { return false }
        return true
    }

    private func controlFile(of fd: Int32) -> WorkspaceControlFile? {
        var status = stat()
        guard fstat(fd, &status) == 0 else { return nil }
        return WorkspaceControlFile(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }
    #endif
}

#if os(macOS)
private final class WorkspaceChildSlot: @unchecked Sendable {
    var child: WorkspaceChild?
    var logged: RuntimeSession?
}

private func removeSnapshot(_ path: String, device: UInt64, inode: UInt64) -> Bool {
    var status = stat()
    guard path.withCString({ lstat($0, &status) == 0 }) else { return true }
    guard UInt64(status.st_dev) == device, UInt64(status.st_ino) == inode else { return false }
    return path.withCString { unlink($0) == 0 }
}

private final class WorkspaceChild: @unchecked Sendable {
    let live: LiveSeatbeltChild
    let stop = RuntimeCancellation()
    /// Start time captured before the group is recorded. Absent when the
    /// kernel identity could not be proved, in which case nothing is signalled.
    var provenGroup: ProcessGroupFact?
    private let finished = Mutex(false)

    init(live: LiveSeatbeltChild) {
        self.live = live
    }

    var watchFinished: Bool {
        finished.withLock { $0 }
    }

    var isProcessGone: Bool {
        processGroupIsEmpty(live.pid) && processIsGone(live.pid)
    }

    func markFinished() {
        finished.withLock { $0 = true }
    }

    func start(_ ended: @escaping @Sendable () -> Void) {
        let child = self
        let thread = Thread {
            _ = watchSeatbeltProcess(child.live, stop: child.stop)
            ended()
            child.markFinished()
        }
        thread.name = "rv-runtime-\(child.live.session.id.rawValue.uuidString)"
        thread.start()
    }
}
#endif
