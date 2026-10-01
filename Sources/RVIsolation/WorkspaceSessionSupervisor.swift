#if os(macOS)
import Darwin
import Synchronization
#endif
import Foundation
import RVDomain
import RVPolicy

/// Why a workspace operation stopped.
///
/// Spawn, publish, and unmount failures stay `IsolationApplyError` values.
/// The other cases are workspace lifetime failures: the process was not
/// started, or close refused to publish because a child was still alive.
enum WorkspaceSessionError: Error, Sendable, Equatable {
    case apply(IsolationApplyError)
    /// Close has been accepted, or the workspace is not active. No process was spawned.
    case notAcceptingRuntime(WorkspaceLifecycle)
    /// A child process group was still alive. The workspace was not published.
    case childTeardownFailed
    case cleanupFailed(IsolationApplyError)
    case alreadyClosed
    case unknownRuntime(RuntimeSessionID)
    /// The workspace is active, and the concurrent running-runtime cap is full.
    /// No process was spawned.
    case runtimeLimit
    /// Another live RV process holds this project. No second workspace was created.
    case ownedByLiveProcess(UUID?)
    /// Recovery is already running for this project.
    case recoveryInProgress(UUID)
    /// The previous workspace cannot be reclaimed automatically.
    case unresolvedWorkspace(WorkspaceRecoveryBlock)
    /// Identity-launch preparation refused the proposal. No process was
    /// spawned and nothing was stored.
    case preparationFailed(PreparedLaunchError)
    /// No usable prepared launch for the presented reference: absent,
    /// expired, bound to another workspace, or the workspace is no longer
    /// active. Deliberately undifferentiated: callers must re-prepare, and
    /// no expiry oracle is exposed. No process was spawned.
    case unknownPreparedLaunch
}

enum WorkspaceSessionFailure {
    static func isolation(_ error: WorkspaceSessionError) -> IsolationApplyError {
        switch error {
        case .apply(let error), .cleanupFailed(let error):
            error
        case .childTeardownFailed:
            .lifetimeBoundaryFailed
        case .notAcceptingRuntime, .alreadyClosed, .unknownRuntime, .runtimeLimit:
            .workspaceInodeBoundaryFailed
        case .preparationFailed, .unknownPreparedLaunch:
            // Preparation/dispatch never flow through the executor outcome
            // mapping; a refused proposal or stale prepared reference is a
            // request-lifecycle failure, like an unknown runtime.
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
struct RunningRuntime: Sendable {
    let session: RuntimeSession
    let capability: RuntimeCapability

    var id: RuntimeSessionID { session.id }
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
///
/// Only the workspace host process opens a supervisor. Interactive commands
/// in other processes attach through `WorkspaceClient`; they cannot name
/// this type.
// @unchecked: `boundary` (WorkspaceInodeBoundary) is a non-Sendable holder.
// All supervisor-owned mutable state is in `Mutex<State>`.
final class WorkspaceSessionSupervisor: @unchecked Sendable {
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

    let id: WorkspaceSessionID
    private let original: WorkingDirectory
    private let protected: WorkingDirectory
    private let createdAt: Date
    private let boundary: WorkspaceInodeBoundary
    private let lifecycleLog: WorkspaceLifecycleStore
    private let ownerLock: WorkspaceOwnerLock
    /// Live Agent Instances this workspace host owns. Launches without an
    /// Agent Definition mint no instance and keep the legacy behavior.
    let agentInstances: AgentInstanceRegistry
    /// Ephemeral prepared identity launches. In-memory only; every entry
    /// is dropped when close is accepted. Preparation and closure nest
    /// store access inside the lifecycle lock (ordering: lifecycle, then
    /// store) so the two can neither deadlock nor resurrect entries.
    private let preparedLaunches = PreparedLaunchStore()
    private let state: Mutex<State>
    private let egressProxy: EgressProxy?
    private let egressPort: Int?

    private init(
        id: WorkspaceSessionID,
        original: WorkingDirectory,
        protected: WorkingDirectory,
        createdAt: Date,
        boundary: WorkspaceInodeBoundary,
        lifecycleLog: WorkspaceLifecycleStore,
        ownerLock: WorkspaceOwnerLock,
        instanceJournal: AgentInstanceJournalStore
    ) {
        self.id = id
        self.original = original
        self.protected = protected
        self.createdAt = createdAt
        self.boundary = boundary
        self.lifecycleLog = lifecycleLog
        self.ownerLock = ownerLock
        self.agentInstances = AgentInstanceRegistry(journal: instanceJournal)
        self.state = Mutex(State(lifecycle: .creating))
        // One CONNECT proxy per workspace host. A bind failure leaves the
        // port nil and contained spawns omit proxy variables (fail closed:
        // without a proxy the cage has no route out at all).
        let proxy = EgressProxy()
        if let port = proxy.start() {
            self.egressProxy = proxy
            self.egressPort = port
        } else {
            self.egressProxy = nil
            self.egressPort = nil
        }
    }

    #endif

    /// Open a protected workspace at `workspace`.
    ///
    /// On failure the workspace is not active. Linux refuses before a mount.
    /// The workspace host process is the only production caller.
    static func open(
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
        runtimeLog: URL? = nil,
        instanceJournal: AgentInstanceJournalStore = .production
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
        if blockingWorkIsCancelled() {
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
            ownerLock: ownerLock,
            instanceJournal: instanceJournal
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
        egressProxy?.stop()
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
            _ = stopOwnedSession(leader: child.live.pid, reap: false)
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

    var snapshot: RVWorkspaceSession {
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

    /// Identity-aware production entry point. Prepares the trusted
    /// selection into an immutable launch, then dispatches it. Product
    /// callers stay denied at the authorization layer; the future
    /// redemption flow will call prepare and dispatch separately across
    /// the authorization boundary.
    func launchAgent(
        selection: ResolvedAgentLaunch, arguments: [String], io: IsolatedIO,
        admission: RuntimeAdmissionConfiguration,
        sessionStore: RuntimeSessionStore, runningLimit: Int? = nil,
        host: WorkspaceHostID, generation: WorkspaceHostGeneration,
        requestID: UUID? = nil
    ) -> Result<RunningRuntime, WorkspaceSessionError> {
        switch prepareIdentityLaunch(
            selection: selection, arguments: arguments, io: io,
            host: host, generation: generation, requestID: requestID
        ) {
        case .failure(let error):
            return .failure(.preparationFailed(error))
        case .success(let prepared):
            return dispatchPreparedLaunch(
                prepared, sessionStore: sessionStore,
                admission: admission, runningLimit: runningLimit
            )
        }
    }

    /// Freezes one identity-launch proposal into an immutable prepared
    /// operation without executing anything.
    ///
    /// Preparation resolves the effective working directory, compiles the
    /// containment profile, builds the resource manifest, resolves
    /// productive-workspace facts, freezes the effective non-secret
    /// environment, and builds the PR1 `WorkspaceLaunchIntent` from those
    /// trusted resolved inputs. It never spawns a process (no workload and
    /// no `git`: commit-identity seeding is disabled on this path), mints
    /// no `AgentInstance`, issues no `RuntimeCapability`, opens no
    /// admission authority, creates no PTY child, releases no credentials,
    /// and mutates no policy. Observable host effects are confined to
    /// filesystem reads plus idempotent RV-managed directory creation.
    ///
    /// Validation order is fixed: selection consistency, credential gate,
    /// profile correspondence, command, IO mapping, cwd resolution, intent
    /// construction, containment preparation, environment freeze, then
    /// lifecycle check with atomic store insert.
    func prepareIdentityLaunch(
        selection: ResolvedAgentLaunch,
        arguments: [String],
        io: IsolatedIO,
        host: WorkspaceHostID,
        generation: WorkspaceHostGeneration,
        requestID: UUID? = nil,
        hostEnvironment: [String: String]? = nil,
        now: Date = Date(),
        timeToLive: TimeInterval = PreparedLaunchLimits.timeToLiveSeconds
    ) -> Result<PreparedWorkspaceLaunch, PreparedLaunchError> {
        let kind: PreparedSelectionKind
        switch verifyPreparedSelection(selection) {
        case .failure(let error):
            return .failure(error)
        case .success(let verified):
            kind = verified
        }
        guard isCredentialFreeSelection(selection) else {
            return .failure(.credentialStagingNotSupported)
        }
        let effectiveProfile: RuntimeResourceProfile?
        switch committedEffectiveProfile(kind: kind, selection: selection) {
        case .failure(let error):
            return .failure(error)
        case .success(let profile):
            effectiveProfile = profile
        }
        guard let command = IsolatedCommand(executable: selection.executable, arguments: arguments) else {
            return .failure(.invalidCommand)
        }
        guard let intentIO = preparedLaunchIO(from: io) else {
            return .failure(.unsupportedIO)
        }
        let policyWorkspace = snapshot.policyWorkspace
        let resolved: String
        switch existingResolvedWorkspacePath(policyWorkspace) {
        case .failure(let error):
            return .failure(.preparationFailed(error))
        case .success(let path):
            resolved = path
        }
        let intentResult: Result<WorkspaceLaunchIntent, WorkspaceLaunchIntentError>
        switch kind {
        case .named(let definition):
            intentResult = WorkspaceLaunchIntent.makeNamed(
                definition: definition,
                revision: selection.resolved.revision,
                resolvedExecutable: selection.executable,
                workspaceSessionID: id,
                workingDirectory: resolved,
                arguments: arguments,
                io: intentIO
            )
        case .custom(let digest):
            intentResult = WorkspaceLaunchIntent.makeCustom(
                executable: selection.executable,
                expectedContentDigestSHA256: digest,
                workspaceSessionID: id,
                workingDirectory: resolved,
                arguments: arguments,
                io: intentIO
            )
        }
        let intent: WorkspaceLaunchIntent
        switch intentResult {
        case .failure(let error):
            return .failure(.invalidIntent(error))
        case .success(let built):
            intent = built
        }
        let plan = compileContainedPlan(workspace: policyWorkspace)
        let compiled: IsolatedLaunchRequest
        switch prepareSeatbelt(
            plan.isolationPlan(), command,
            resourceProfile: effectiveProfile,
            legacyAgentIntegration: false,
            gitIdentity: { _ in (nil, nil) }
        ) {
        case .failure(let error):
            return .failure(.preparationFailed(error))
        case .success(let request):
            compiled = request.withIO(io)
        }
        guard compiled.containedWorkspacePath == resolved else {
            return .failure(.preparationFailed(.workspacePathUnresolvable))
        }
        guard let productive = compiled.productive else {
            return .failure(.preparationFailed(.containedGuaranteesUnsupported))
        }
        let frozenHost = hostEnvironment ?? ProcessInfo.processInfo.environment
        let entries = containedRuntimeEnvironment(
            workspace: resolved,
            io: io,
            agentBin: nil,
            resources: compiled.resources,
            egressProxyPort: egressPort,
            hostEnvironment: frozenHost,
            keychain: [],
            productive: productive
        )
        let environment = WorkspaceLaunchEnvironmentSnapshot(entries: entries)
        guard environment.totalBytes <= PreparedLaunchLimits.maxFrozenEnvironmentBytes else {
            return .failure(.environmentTooLarge)
        }
        let prepared = PreparedWorkspaceLaunch(
            binding: PreparedLaunchBinding(
                workspace: id, host: host, generation: generation,
                preparedLaunchID: PreparedLaunchID()
            ),
            requestID: requestID,
            intent: intent,
            intentDigest: intent.canonicalDigest,
            preparedAt: now,
            expiresAt: now.addingTimeInterval(timeToLive),
            selection: selection,
            command: command,
            resolvedWorkspacePath: resolved,
            io: io,
            environment: environment,
            productive: productive,
            launchRequest: compiled,
            egressProxyPort: egressPort,
            hook: selection.resolved.definition.hookHost,
            stagingAgent: selection.resolved.definition.agentTag
        )
        enum InsertOutcome { case inserted, inactive, full }
        let outcome = state.withLock { state -> InsertOutcome in
            guard state.lifecycle.acceptsRuntime, state.closeAccepted == false else {
                return .inactive
            }
            return preparedLaunches.insert(prepared, now: now) ? .inserted : .full
        }
        switch outcome {
        case .inserted:
            return .success(prepared)
        case .inactive:
            return .failure(.workspaceNotActive)
        case .full:
            return .failure(.storeFull)
        }
    }

    /// Dispatches a retained prepared launch: the only consumer of
    /// `PreparedWorkspaceLaunch` execution state.
    ///
    /// Consumes retained state exclusively: the compiled request, command,
    /// resolved path, IO, frozen environment, productive facts, and manifest
    /// all come from `prepared`. Nothing is re-resolved: no definition
    /// lookup, no link lookup, no profile selection, no cwd choice, no argv
    /// parsing, no environment resolution. Only runtime instance data is
    /// generated here (session, capability, instance, process group,
    /// admission descriptors), which cannot substitute launch semantics.
    /// (The egress port is a supervisor-lifetime immutable `let`, so the
    /// spawn body's live read provably equals the retained copy; the copy
    /// exists for audit completeness and future redemption checks.)
    ///
    /// Internal and unreachable from any product request in PR2: identity
    /// operations stay denied at the authorization layer, so only tests
    /// and the direct `launchAgent` path exercise this. The future
    /// redemption PR gates it behind permit acceptance; until then, no
    /// method here dispatches from a bare `PreparedLaunchID`.
    ///
    /// Freshness is checked here and re-checked at spawn commit inside the
    /// spawn critical section, so an invalidation or expiry landing
    /// between the two still fails the launch.
    func dispatchPreparedLaunch(
        _ prepared: PreparedWorkspaceLaunch,
        sessionStore: RuntimeSessionStore,
        admission: RuntimeAdmissionConfiguration,
        runningLimit: Int? = nil,
        spawnFault: RuntimeSpawnFault? = nil,
        now: Date = Date()
    ) -> Result<RunningRuntime, WorkspaceSessionError> {
        let fresh = state.withLock { state in
            state.lifecycle.acceptsRuntime && state.closeAccepted == false
                && prepared.binding.workspace == id
                && preparedLaunches.isUsable(prepared.binding.preparedLaunchID, now: now)
        }
        guard fresh else {
            return .failure(.unknownPreparedLaunch)
        }
        // Retained state must still be credential-free and must correspond
        // to the bound intent: re-derive the digest from retained parts and
        // require equality. Any drift fails closed.
        guard isCredentialFreeSelection(prepared.selection),
            retainedIntentMatches(prepared)
        else {
            return .failure(.unknownPreparedLaunch)
        }
        var request = prepared.launchRequest
        if let spawnFault {
            request = request.withSpawnFault(spawnFault)
        }
        return establishRuntime(
            request: request,
            expectedWorkspacePath: prepared.resolvedWorkspacePath,
            preparedEnvironment: prepared.environment.entries,
            host: prepared.hook,
            stagingAgent: prepared.stagingAgent,
            sessionStore: sessionStore,
            admission: admission,
            runningLimit: runningLimit,
            // Unreachable: the credential-free assert above guarantees the
            // retained profile holds no keychain entries to read.
            keychainReader: .live,
            agentDefinition: prepared.selection.resolved.definition,
            preparedID: prepared.binding.preparedLaunchID,
            now: now
        )
    }

    /// Safe description of one prepared launch, or nil when absent or
    /// expired. Point-in-time and non-authoritative; never returns
    /// retained execution state.
    func describePreparedLaunch(_ id: PreparedLaunchID, now: Date = Date()) -> PreparedLaunchDescription? {
        preparedLaunches.description(for: id, now: now)
    }

    /// Explicitly invalidates one prepared launch. Idempotent. Takes the
    /// lifecycle lock (ordering: lifecycle, then store) so removal is
    /// mutually exclusive with the spawn-commit check: an invalidation
    /// racing dispatch either lands before the commit check (dispatch
    /// fails) or after the spawn commits (too late, correctly).
    func invalidatePreparedLaunch(_ id: PreparedLaunchID) {
        state.withLock { _ in
            preparedLaunches.remove(id)
        }
    }

    /// Re-derives the intent from retained parts and requires the identical
    /// digest, proving the retained selection, profile, cwd, argv, and IO
    /// correspond to the bound intent instead of having drifted after
    /// preparation.
    private func retainedIntentMatches(_ prepared: PreparedWorkspaceLaunch) -> Bool {
        guard prepared.command.executable == prepared.selection.executable,
            prepared.launchRequest.command == prepared.command,
            prepared.launchRequest.containedWorkspacePath == prepared.resolvedWorkspacePath,
            prepared.io == prepared.launchRequest.io,
            case .success(let kind) = verifyPreparedSelection(prepared.selection),
            case .success(let effectiveProfile) = committedEffectiveProfile(
                kind: kind, selection: prepared.selection
            ),
            prepared.launchRequest.resources?.profile == effectiveProfile,
            let intentIO = preparedLaunchIO(from: prepared.io)
        else {
            return false
        }
        let rebuilt: Result<WorkspaceLaunchIntent, WorkspaceLaunchIntentError>
        switch kind {
        case .named(let definition):
            rebuilt = WorkspaceLaunchIntent.makeNamed(
                definition: definition,
                revision: prepared.selection.resolved.revision,
                resolvedExecutable: prepared.command.executable,
                workspaceSessionID: prepared.binding.workspace,
                workingDirectory: prepared.resolvedWorkspacePath,
                arguments: prepared.command.arguments,
                io: intentIO
            )
        case .custom(let digest):
            rebuilt = WorkspaceLaunchIntent.makeCustom(
                executable: prepared.command.executable,
                expectedContentDigestSHA256: digest,
                workspaceSessionID: prepared.binding.workspace,
                workingDirectory: prepared.resolvedWorkspacePath,
                arguments: prepared.command.arguments,
                io: intentIO
            )
        }
        guard case .success(let intent) = rebuilt else {
            return false
        }
        return intent.canonicalDigest == prepared.intentDigest
    }

    /// Legacy launches do not mint an AgentInstance, regardless of integration name.
    func launchLegacy(
        host: HookHost?, stagingAgent: String? = nil, command: IsolatedCommand,
        plan: ContainedPlan, io: IsolatedIO, resourceProfile: RuntimeResourceProfile? = nil,
        admission: RuntimeAdmissionConfiguration, sessionStore: RuntimeSessionStore,
        runningLimit: Int? = nil
    ) -> Result<RunningRuntime, WorkspaceSessionError> {
        launch(host: host, stagingAgent: stagingAgent, command: command, plan: plan,
               io: io, resourceProfile: resourceProfile, admission: admission,
               sessionStore: sessionStore, runningLimit: runningLimit, agentDefinition: nil)
    }

    /// Start one contained runtime inside this workspace.
    ///
    /// Returns after the Seatbelt handshake. The process keeps running.
    /// A second call does not create another volume.
    func launch(
        host: HookHost?,
        stagingAgent: String? = nil,
        command: IsolatedCommand,
        plan: ContainedPlan,
        io: IsolatedIO = .discard,
        resourceProfile: RuntimeResourceProfile? = nil,
        admission: RuntimeAdmissionConfiguration = .failClosed,
        spawnFault: RuntimeSpawnFault? = nil,
        agentDefinition: AgentDefinition? = nil
    ) -> Result<RunningRuntime, WorkspaceSessionError> {
        launch(
            host: host,
            stagingAgent: stagingAgent,
            command: command,
            plan: plan,
            io: io,
            resourceProfile: resourceProfile,
            admission: admission,
            sessionStore: .production,
            spawnFault: spawnFault,
            agentDefinition: agentDefinition
        )
    }

    func launch(
        host: HookHost?,
        stagingAgent: String? = nil,
        command: IsolatedCommand,
        plan: ContainedPlan,
        io: IsolatedIO,
        resourceProfile: RuntimeResourceProfile? = nil,
        admission: RuntimeAdmissionConfiguration,
        sessionStore: RuntimeSessionStore,
        runningLimit: Int? = nil,
        keychainReader: KeychainReader = .live,
        spawnFault: RuntimeSpawnFault? = nil,
        agentDefinition: AgentDefinition? = nil
    ) -> Result<RunningRuntime, WorkspaceSessionError> {
        let request: IsolatedLaunchRequest
        switch prepareSeatbelt(
            plan.isolationPlan(), command, resourceProfile: resourceProfile,
            legacyAgentIntegration: agentDefinition == nil
        ) {
        case .failure(let error):
            return .failure(.apply(error))
        case .success(let prepared):
            if let spawnFault {
                request = prepared.withIO(io).withSpawnFault(spawnFault)
            } else {
                request = prepared.withIO(io)
            }
        }
        return establishRuntime(
            request: request,
            expectedWorkspacePath: protected.rawValue,
            preparedEnvironment: nil,
            host: host,
            stagingAgent: stagingAgent,
            sessionStore: sessionStore,
            admission: admission,
            runningLimit: runningLimit,
            keychainReader: keychainReader,
            agentDefinition: agentDefinition
        )
    }

    /// Establishes one runtime from a fully resolved request. Shared by the
    /// legacy direct-launch path (which resolves its request inline above)
    /// and prepared dispatch (which consumes retained state). The workspace
    /// check pins the request to the expected resolved path; a retained
    /// environment bypasses spawn-time resolution entirely, while nil
    /// preserves legacy live resolution. A prepared ID re-validates store
    /// usability at spawn commit (nil skips the check for legacy).
    private func establishRuntime(
        request: IsolatedLaunchRequest,
        expectedWorkspacePath: String,
        preparedEnvironment: [String]?,
        host: HookHost?,
        stagingAgent: String?,
        sessionStore: RuntimeSessionStore,
        admission: RuntimeAdmissionConfiguration,
        runningLimit: Int?,
        keychainReader: KeychainReader,
        agentDefinition: AgentDefinition?,
        preparedID: PreparedLaunchID? = nil,
        now: Date = Date()
    ) -> Result<RunningRuntime, WorkspaceSessionError> {
        guard request.containedWorkspacePath == expectedWorkspacePath else {
            return .failure(.apply(.workspacePathUnresolvable))
        }
        let spawned: Result<WorkspaceChild, WorkspaceSessionError> = spawn(
            request,
            host: host,
            stagingAgent: stagingAgent,
            sessionStore: sessionStore,
            admission: admission,
            register: true,
            runningLimit: runningLimit,
            keychainReader: keychainReader,
            agentDefinition: agentDefinition,
            preparedEnvironment: preparedEnvironment,
            preparedID: preparedID,
            now: now
        )
        switch spawned {
        case .failure(let error):
            return .failure(error)
        case .success(let child):
            let session = child.live.session
            child.start {
                self.noteRuntimeEnded(session)
            } settled: {
                self.pruneFinishedRuntimes(limit: WorkspaceControlLimits.maxRuntimes)
            }
            switch waitUntilEstablished(child) {
            case .failure(let error):
                // The attempt was announced but never established. Finish
                // the instance now — the exit watcher would only finish it
                // as already-inactive — so the journal records the outcome
                // promptly with the right reason even if the watcher never
                // fires. Legacy launches without a definition are a no-op.
                _ = agentInstances.finishRuntime(session.id, reason: .establishmentFailed)
                return .failure(error)
            case .success(let running):
                guard agentDefinition == nil || activateRunningInstance(for: child) else {
                    // The runtime established but identity did not. Authority
                    // dies first, then the process is reaped; the launch
                    // reports failure either way.
                    _ = agentInstances.finishRuntime(session.id, reason: .establishmentFailed)
                    _ = cancel(session.id)
                    return .failure(.apply(.lifetimeBoundaryFailed))
                }
                return .success(running)
            }
        }
    }

    /// One runtime, watched on the caller's thread, then the caller closes.
    /// `LocalExecutor` calls this from `rv-executor-apply`, not a cooperative task.
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
    func cancel(
        _ runtime: RuntimeSessionID
    ) -> Result<Void, WorkspaceSessionError> {
        let child = state.withLock { state -> WorkspaceChild? in
            guard state.lifecycle == .active || state.lifecycle == .closing else { return nil }
            return state.children[runtime]
        }
        guard let child else { return .failure(.unknownRuntime(runtime)) }
        child.stop.request()
        _ = stopOwnedSession(leader: child.live.pid, reap: false)
        // Authority dies on cancel, before the reap completes. A lingering
        // process group keeps no usable principal.
        _ = agentInstances.finishRuntime(runtime, reason: .cancelled)
        guard waitForChildren([child], seconds: 45) else {
            return .failure(.childTeardownFailed)
        }
        return .success(())
    }

    /// Stop every runtime, publish once, and remove the private volume.
    func close() -> Result<Void, WorkspaceSessionError> {
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
        stagingAgent: String? = nil,
        sessionStore: RuntimeSessionStore,
        admission: RuntimeAdmissionConfiguration,
        register: Bool,
        runningLimit: Int? = nil,
        keychainReader: KeychainReader = .live,
        agentDefinition: AgentDefinition? = nil,
        preparedEnvironment: [String]? = nil,
        preparedID: PreparedLaunchID? = nil,
        now: Date = Date()
    ) -> Result<WorkspaceChild, WorkspaceSessionError> {
        guard let profile = request.seatbeltProfile,
            let workspace = request.containedWorkspacePath
        else {
            return .failure(.apply(.containedGuaranteesUnsupported))
        }
        // Keychain reads run before the state lock: SecItemCopyMatching can
        // present an unbounded host prompt, and holding the supervisor
        // lock across it would stall cancel/close/launch. Values are
        // reused by the spawn retry, so a launch prompts at most once.
        let agentName = stagingAgent ?? host?.rawValue
        let keychain: [(name: String, value: String)]
        if let resources = request.resources {
            switch resources.keychainEnvironment(forAgent: agentName, reader: keychainReader) {
            case .success(let entries):
                keychain = entries
            case .failure(let staging):
                return .failure(.apply(.resourceStagingFailed(staging.detail)))
            }
        } else {
            keychain = []
        }
        var slot = WorkspaceChildSlot()
        let result: Result<Void, WorkspaceSessionError> = state.withLock { state in
            guard state.closeAccepted == false, state.lifecycle.acceptsRuntime else {
                return .failure(.notAcceptingRuntime(state.lifecycle))
            }
            if let preparedID {
                // Re-validated at spawn commit, inside the same critical
                // section as the close check: an invalidation or expiry
                // that lands after dispatch's entry check still fails
                // here. Explicit removal serializes fully against this
                // section; TTL wall-clock expiry during it (~ms) can only
                // delay the inevitable by that section.
                guard preparedLaunches.isUsable(preparedID, now: now) else {
                    return .failure(.unknownPreparedLaunch)
                }
            }
            if let runningLimit {
                let running = state.children.values.filter { $0.watchFinished == false }.count
                if running >= runningLimit {
                    return .failure(.runtimeLimit)
                }
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
                admission: admission,
                egressProxyPort: egressPort,
                host: host,
                stagingAgent: stagingAgent,
                keychain: keychain,
                preparedEnvironment: preparedEnvironment
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
                noteRuntimeEnded(session, reason: .spawnFailed)
            }
            return .failure(error)
        case .success:
            guard let child = slot.child else {
                return .failure(.apply(.processSpawnFailed))
            }
            if let definition = agentDefinition {
                // Announce before the resume below: the child image is still
                // stopped, so no request can arrive on an unbound channel.
                guard announceAgentInstance(definition, child: child) else {
                    retireUnrecorded(child)
                    return .failure(.apply(.sessionRecordFailed))
                }
            }
            switch recordProcessGroup(child, spawnFault: request.spawnFault) {
            case .failure(let error):
                retireUnrecorded(child)
                return .failure(error)
            case .success:
                return .success(child)
            }
        }
    }

    /// Mints and announces the Agent Instance for a spawned child, and binds
    /// the child's admission channel to it. False refuses the launch.
    ///
    /// The definition comes from the trusted caller, never the workload.
    /// Executable evidence is the weak launch-observed level: RV spawned the
    /// process group but verified neither content nor signing.
    private func announceAgentInstance(
        _ definition: AgentDefinition,
        child: WorkspaceChild
    ) -> Bool {
        let session = child.live.session
        let instance = AgentInstance(
            id: AgentInstanceID(),
            owner: OwnerPrincipal.current(),
            definitionID: definition.id,
            definitionRevision: AgentDefinitionRevision.resolve(definition),
            workspaceSessionID: id,
            runtimeSessionID: session.id,
            executableEvidence: ExecutableEvidence(pid: child.live.pid),
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: child.live.pid),
            workloadProcess: nil,
            parent: nil,
            effectiveAuthority: definition.authorityCeiling,
            delegableAuthority: definition.authorityCeiling,
            mintedAt: Date()
        )
        guard agentInstances.announce(instance) else { return false }
        guard child.live.admission.bindAgentInstance(instance.id, registry: agentInstances) else {
            _ = agentInstances.finishRuntime(session.id, reason: .spawnFailed)
            return false
        }
        return true
    }

    /// Activates the announced instance once the runtime established.
    private func activateRunningInstance(for child: WorkspaceChild) -> Bool {
        let session = child.live.session
        guard let instance = agentInstances.instance(forRuntime: session.id),
            let established = EstablishedRuntimeSession(
                session: session,
                instance: instance,
                establishedAt: Date()
            )
        else {
            return false
        }
        return agentInstances.activate(established) != nil
    }

    private func recordProcessGroup(
        _ child: WorkspaceChild,
        spawnFault: RuntimeSpawnFault?
    ) -> Result<Void, WorkspaceSessionError> {
        // Request-scoped: a global flag here would fail parallel sibling
        // launches that share this process.
        if spawnFault == .register {
            return .failure(.apply(.lifetimeBoundaryFailed))
        }
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
        switch resumeAndClaimForeground(child.live) {
        case .failure(let error):
            return .failure(.apply(error))
        case .success:
            return .success(())
        }
    }

    private func retireUnrecorded(_ child: WorkspaceChild) {
        let session = child.live.session
        let pid = child.live.pid
        state.withLock { state in
            state.children[session.id] = nil
        }
        child.live.abandonIfUnwatched()
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
        // The staged private home holds credential copies; the watch path
        // removes it on the normal teardown, so the retire path must too.
        // `remove` is `try? rm -rf`: idempotent if a watcher also fires.
        child.live.resources?.remove()
        noteRuntimeEnded(session, reason: .spawnFailed)
    }

    private func waitUntilEstablished(
        _ child: WorkspaceChild
    ) -> Result<RunningRuntime, WorkspaceSessionError> {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if blockingWorkIsCancelled() {
                child.stop.request()
                _ = stopOwnedSession(leader: child.live.pid, reap: false)
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
        _ = stopOwnedSession(leader: child.live.pid, reap: false)
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
            // Prepared launches die with the active workspace. This runs
            // inside the election lock, so a preparation that won the race
            // is dropped here, and any later preparation sees the closed
            // lifecycle and fails: entries can never reappear after close.
            preparedLaunches.invalidateAll()
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
            _ = stopOwnedSession(leader: child.live.pid, reap: false)
        }
        guard waitForChildren(children, seconds: 45) else {
            return .failure(.childTeardownFailed)
        }
        egressProxy?.stop()
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

    private func noteRuntimeEnded(
        _ session: RuntimeSession,
        reason: AgentRevokeReason = .runtimeEnded
    ) {
        _ = agentInstances.finishRuntime(session.id, reason: reason)
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

    /// Drops the oldest finished runtimes until what remains fits in `limit`.
    /// Running runtimes stay. The cap is the control protocol's report bound.
    func pruneFinishedRuntimes(limit: Int) {
        state.withLock { state in
            let entries = state.children.map { id, child in
                RuntimeRetention.Entry(
                    id: id.rawValue,
                    startedAt: child.live.session.startedAt,
                    running: child.watchFinished == false
                        || (child.live.pty?.hasSubscribers ?? false)
                )
            }
            let drop = RuntimeRetention.finishedIDsToDrop(entries, limit: limit)
            guard drop.isEmpty == false else { return }
            for id in state.children.keys where drop.contains(id.rawValue) {
                state.children[id] = nil
            }
        }
    }

    /// Runtimes this workspace owns. No capability, pid, or process group.
    func runtimeFacts() -> [WorkspaceRuntimeFact] {
        let children = state.withLock { Array($0.children.values) }
        return children.map { child in
            let window = child.live.pty?.window()
            let terminal = child.live.pty != nil
            // The exit notice is queued inside the watch, before the watch
            // flag flips (a log append runs between them). A client that
            // received the notice must already see running=false here.
            let exited = child.live.pty?.hasExited == true
            return WorkspaceRuntimeFact(
                id: child.live.session.id.rawValue,
                hookHost: child.live.session.host?.rawValue,
                running: child.watchFinished == false && exited == false,
                terminal: terminal,
                rows: terminal ? window?.rows : nil,
                columns: terminal ? window?.columns : nil,
                inputOwner: child.live.pty?.hasInputOwner ?? false
            )
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func subscribeTerminal(
        runtime: UUID,
        client: UUID,
        emit: @escaping @Sendable (TerminalNotice) -> Bool,
        windowNotices: Bool = false,
        replayBatches: Bool = true
    ) -> Result<Void, WorkspaceControlCode> {
        guard let terminal = terminal(runtime) else {
            return .failure(terminalMissing(runtime))
        }
        return terminal.subscribe(client: client, emit: emit, windowNotices: windowNotices, replayBatches: replayBatches)
            .mapError { self.controlCode($0) }
    }

    func activateTerminal(runtime: UUID, client: UUID) {
        terminal(runtime)?.activate(client: client)
    }

    func detachTerminalClient(_ client: UUID) {
        let children = state.withLock { Array($0.children.values) }
        for child in children {
            child.live.pty?.detach(client: client)
        }
    }

    func unsubscribeTerminal(runtime: UUID, client: UUID) -> Result<Void, WorkspaceControlCode> {
        guard let terminal = terminal(runtime) else {
            return .failure(terminalMissing(runtime))
        }
        terminal.detach(client: client)
        return .success(())
    }

    func acquireTerminalInput(runtime: UUID, client: UUID) -> Result<Void, WorkspaceControlCode> {
        guard let terminal = terminal(runtime) else {
            return .failure(terminalMissing(runtime))
        }
        return terminal.acquireInput(client: client).mapError { self.controlCode($0) }
    }

    func releaseTerminalInput(runtime: UUID, client: UUID) -> Result<Void, WorkspaceControlCode> {
        guard let terminal = terminal(runtime) else {
            return .failure(terminalMissing(runtime))
        }
        return terminal.releaseInput(client: client).mapError { self.controlCode($0) }
    }

    func writeTerminal(runtime: UUID, client: UUID, bytes: Data) -> Result<Void, WorkspaceControlCode> {
        guard let terminal = terminal(runtime) else {
            return .failure(terminalMissing(runtime))
        }
        return terminal.writeInput(client: client, bytes: bytes).mapError { self.controlCode($0) }
    }

    func resizeTerminal(
        runtime: UUID,
        client: UUID,
        rows: Int,
        columns: Int
    ) -> Result<Void, WorkspaceControlCode> {
        guard let terminal = terminal(runtime) else {
            return .failure(terminalMissing(runtime))
        }
        return terminal.resize(client: client, rows: rows, columns: columns)
            .mapError { self.controlCode($0) }
    }

    func terminalWindow(runtime: UUID) -> (rows: Int, columns: Int)? {
        terminal(runtime)?.window()
    }

    func terminalMasterOpen(_ runtime: UUID) -> Bool {
        guard let fd = terminal(runtime)?.masterFD else { return false }
        return fd >= 0
    }

    private func terminal(_ runtime: UUID) -> RuntimeTerminal? {
        let named = RuntimeSessionID(rawValue: runtime)
        return state.withLock { $0.children[named]?.live.pty }
    }

    private func terminalMissing(_ runtime: UUID) -> WorkspaceControlCode {
        let named = RuntimeSessionID(rawValue: runtime)
        let known = state.withLock { $0.children[named] != nil }
        return known ? .terminalUnavailable : .runtimeNotFound
    }

    private func controlCode(_ error: TerminalControlError) -> WorkspaceControlCode {
        switch error {
        case .unavailable: .terminalUnavailable
        case .busy: .terminalBusy
        case .limit: .terminalLimit
        case .invalid: .invalidRequest
        case .prefixCommitted: .terminalPrefixCommitted
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
// Method-local outbox for one `launch` call. It never leaves the caller's
// thread: the `withLock` closure that fills it is non-escaping.
private struct WorkspaceChildSlot {
    var child: WorkspaceChild?
    var logged: RuntimeSession?
}

private func removeSnapshot(_ path: String, device: UInt64, inode: UInt64) -> Bool {
    var status = stat()
    guard path.withCString({ lstat($0, &status) == 0 }) else { return true }
    guard UInt64(status.st_dev) == device, UInt64(status.st_ino) == inode else { return false }
    return path.withCString { unlink($0) == 0 }
}

/// Which finished runtimes to forget so a report still fits in `limit`.
struct RuntimeRetention: Equatable {
    struct Entry: Equatable {
        var id: UUID
        var startedAt: Date
        var running: Bool
    }

    /// Oldest finished ids that do not fit beside every running entry.
    /// Running entries are never dropped.
    static func finishedIDsToDrop(_ entries: [Entry], limit: Int) -> Set<UUID> {
        let running = entries.filter(\.running).count
        let room = max(0, limit - running)
        let finished = entries.filter { $0.running == false }.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        guard finished.count > room else { return [] }
        return Set(finished.prefix(finished.count - room).map(\.id))
    }
}

private final class WorkspaceChild: Sendable {
    let live: LiveSeatbeltChild
    let stop = RuntimeCancellation()
    /// Start time captured before the group is recorded. Absent when the
    /// kernel identity could not be proved, in which case nothing is signalled.
    private let provenGroupBox = Mutex<ProcessGroupFact?>(nil)
    private let finished = Mutex(false)

    /// Set once on the launch path, read when retiring an unrecorded child.
    var provenGroup: ProcessGroupFact? {
        get { provenGroupBox.withLock { $0 } }
        set { provenGroupBox.withLock { $0 = newValue } }
    }

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

    func start(
        _ ended: @escaping @Sendable () -> Void,
        settled: @escaping @Sendable () -> Void
    ) {
        let child = self
        let thread = Thread {
            _ = watchSeatbeltProcess(child.live, stop: child.stop)
            ended()
            child.markFinished()
            settled()
        }
        thread.name = "rv-runtime-\(child.live.session.id.rawValue.uuidString)"
        thread.start()
    }
}
#endif
