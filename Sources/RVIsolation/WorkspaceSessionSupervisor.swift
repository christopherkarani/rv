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
    private let state: Mutex<State>

    private init(
        id: WorkspaceSessionID,
        original: WorkingDirectory,
        protected: WorkingDirectory,
        createdAt: Date,
        boundary: WorkspaceInodeBoundary,
        lifecycleLog: WorkspaceLifecycleStore
    ) {
        self.id = id
        self.original = original
        self.protected = protected
        self.createdAt = createdAt
        self.boundary = boundary
        self.lifecycleLog = lifecycleLog
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
        lifecycleLog: WorkspaceLifecycleStore
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
        switch rejectWorkspaceInodeAlias(resolved) {
        case .failure(let error):
            return .failure(.apply(error))
        case .success:
            break
        }
        if Task.isCancelled {
            return .failure(.apply(.cancelled))
        }
        let boundary: WorkspaceInodeBoundary
        switch establishWorkspaceInodeBoundary(at: resolved) {
        case .failure(let error):
            return .failure(.apply(error))
        case .success(let established):
            boundary = established
        }
        guard boundary.remainsEstablished() else {
            _ = boundary.discardAndRestore()
            return .failure(.apply(.workspaceInodeBoundaryFailed))
        }
        let id = WorkspaceSessionID()
        let createdAt = Date()
        let recorded = lifecycleLog.append(
            WorkspaceLifecycleRecord(
                kind: .created,
                workspace: id.rawValue,
                originalPath: directory.rawValue,
                protectedPath: directory.rawValue,
                volumeDevice: boundary.volumeDeviceIdentifier,
                disk: boundary.diskIdentifier,
                runtime: nil,
                recordedAt: createdAt
            )
        )
        if case .failure(let error) = recorded {
            switch boundary.discardAndRestore() {
            case .failure(let cleanup):
                return .failure(.cleanupFailed(cleanup))
            case .success:
                return .failure(.apply(error))
            }
        }
        let supervisor = WorkspaceSessionSupervisor(
            id: id,
            original: directory,
            protected: directory,
            createdAt: createdAt,
            boundary: boundary,
            lifecycleLog: lifecycleLog
        )
        let activated = supervisor.state.withLock { state -> Bool in
            guard let active = state.lifecycle.transition(.becameActive) else { return false }
            state.lifecycle = active
            return true
        }
        guard activated else {
            _ = boundary.discardAndRestore()
            return .failure(.apply(.workspaceInodeBoundaryFailed))
        }
        return .success(supervisor)
    }

    deinit {
        let children = state.withLock { Array($0.children.values) }
        for child in children {
            child.stop.request()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, children.contains(where: { $0.watchFinished == false }) {
            usleep(10_000)
        }
        let discard = state.withLock { state -> Bool in
            guard state.finishedClose == nil, state.lifecycle != .closed, boundary.isReleased == false else {
                return false
            }
            return children.allSatisfy { $0.watchFinished && $0.isProcessGone }
        }
        if discard {
            _ = boundary.discardAndRestore()
        }
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
        finish(publish: true)
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
                break
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
            return .failure(error)
        case .success:
            guard let child = slot.child else {
                return .failure(.apply(.processSpawnFailed))
            }
            return .success(child)
        }
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
                state.finishedClose = result
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
        if let recordError = state.withLock({ $0.recordError }) {
            return .failure(.apply(recordError))
        }
        return .success(())
    }

    private func waitForLeader() -> Result<Void, WorkspaceSessionError> {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let finished = state.withLock({ $0.finishedClose }) {
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
}

private final class WorkspaceChild: @unchecked Sendable {
    let live: LiveSeatbeltChild
    let stop = RuntimeCancellation()
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
