#if canImport(XPC)
import Darwin
import Foundation
import RVAnalytics
import RVDomain
import RVIPC
import RVJudgePool
import RVPolicy
import Synchronization

public enum RVDProcess {
    public static func run(configuration: RVDConfiguration) throws {
        try RVDLaunch.requireHome(environment: ProcessInfo.processInfo.environment)
        let socketURL = try UnixSocketPath.production()
        let backoff = RVDLifecycle.beginStartup(environment: ProcessInfo.processInfo.environment)
        let analytics = AnalyticsBootstrap.makeLive(productVersion: ProductVersion.semver)
        let hosts = LiveWorkspaceHostRegistry()
        let ceremonies = WorkspaceOperatorCeremonyService(hosts: hosts)
        let actionCeremonies = ActionApprovalCeremonyService(hosts: hosts)
        let uiSessions = LiveOperatorUISessionRegistry()
        let runtime = ServiceRuntime(
            snapshots: nil,
            catalog: nil,
            home: nil,
            allowOnce: nil,
            allowOnceDirectory: nil,
            idleExitSeconds: configuration.idleExitSeconds,
            log: nil,
            analytics: analytics,
            clock: { Date() },
            pendingApprovals: .automatic,
            ceremonies: ceremonies,
            actionCeremonies: actionCeremonies
        )
        runtime.startHookLocalSpoolTimer()
        JudgeRuntime.bindLoadWait(JudgeRuntime.daemonLoadWait)
        // Core ML runs in the dev.rv.judge worker pool, never in rvd: a
        // worker abort or hang costs one prediction, not the daemon.
        // Unreachable pool = review (docs/architecture/judge-pool.md).
        JudgeRuntime.bindClient(XPCJudgeClient())
        let slot = ListenerSlot()
        let watchdog = RVDLifecycle.watchdog(configuration: configuration, runtime: runtime) {
            slot.listeners?.stop()
            Darwin.exit(0)
        }
        let listeners = ListenerPair(
            xpc: XPCEvaluateListener(
                runtime: runtime, watchdog: watchdog, hostRegistry: hosts, uiSessions: uiSessions),
            unix: UnixSocketListener(runtime: runtime, watchdog: watchdog, socketURL: socketURL)
        )
        slot.listeners = listeners
        // XPC is the macOS production transport; the Unix socket is
        // secondary. A socket that cannot start (e.g. a refused
        // `~/.config`) is reported and skipped, never a launch failure that
        // would block every hook on each launchd activation. It is bound
        // before the backoff wait and accepts after it; XPC needs no such
        // step, since launchd holds the Mach service and queues messages
        // until the listener exists (hooks time out, they never see INVALID).
        do {
            try listeners.unix.bind()
        } catch {
            try? FileHandle.standardError.write(contentsOf:
                Data(RVDLogFile.line("rvd: unix socket unavailable (\(error)); continuing with XPC only").utf8)
            )
        }
        RVDLifecycle.waitOutBackoff(backoff)
        if backoff.delay > .zero { listeners.unix.dropQueued() }
        listeners.unix.startAccepting()
        listeners.xpc.start()
        watchdog.start()
        RVDLifecycle.serving(backoff)
        RunLoop.main.run()
    }
}

private struct ListenerPair: Sendable {
    let xpc: XPCEvaluateListener
    let unix: UnixSocketListener

    func stop() {
        xpc.stop()
        unix.stop()
    }
}

private final class ListenerSlot: Sendable {
    private let box = Mutex<ListenerPair?>(nil)

    var listeners: ListenerPair? {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }
}
#else
import Foundation
import RVAnalytics
import RVDomain
import RVIPC
import RVPolicy
import Synchronization

public enum RVDProcess {
    public static func run(configuration: RVDConfiguration) throws {
        try RVDLaunch.requireHome(environment: ProcessInfo.processInfo.environment)
        let socketURL = try UnixSocketPath.production()
        let backoff = RVDLifecycle.beginStartup(environment: ProcessInfo.processInfo.environment)
        let analytics = AnalyticsBootstrap.makeLive(productVersion: ProductVersion.semver)
        let ceremonies = WorkspaceOperatorCeremonyService()
        let actionCeremonies = ActionApprovalCeremonyService()
        let runtime = ServiceRuntime(
            snapshots: nil,
            catalog: nil,
            home: nil,
            allowOnce: nil,
            allowOnceDirectory: nil,
            idleExitSeconds: configuration.idleExitSeconds,
            log: nil,
            analytics: analytics,
            clock: { Date() },
            pendingApprovals: .automatic,
            ceremonies: ceremonies,
            actionCeremonies: actionCeremonies
        )
        runtime.startHookLocalSpoolTimer()
        JudgeRuntime.bindLoadWait(JudgeRuntime.daemonLoadWait)
        let slot = ListenerSlot()
        let watchdog = RVDLifecycle.watchdog(configuration: configuration, runtime: runtime) {
            slot.listener?.stop()
            Foundation.exit(0)
        }
        let listener = UnixEvaluateListener(
            runtime: runtime,
            watchdog: watchdog,
            socketURL: socketURL
        )
        slot.listener = listener
        // The socket is Linux's only transport: a start failure is fatal.
        // Bound before the backoff wait, accepting after it, so hooks see a
        // slow rvd meanwhile, never a missing socket.
        try listener.bind()
        RVDLifecycle.waitOutBackoff(backoff)
        if backoff.delay > .zero { listener.dropQueued() }
        listener.startAccepting()
        watchdog.start()
        RVDLifecycle.serving(backoff)
        RunLoop.main.run()
    }
}

private final class ListenerSlot: Sendable {
    private let box = Mutex<UnixEvaluateListener?>(nil)

    var listener: UnixEvaluateListener? {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }
}
#endif

/// Process-lifetime wiring shared by both platform entry points.
enum RVDLifecycle {
    /// Exits once its own binary was replaced on disk (the supervisor then
    /// runs the new one). With `--idle-exit-seconds` it also idle-exits,
    /// keeping the process (and its allow-once table) while grants are live.
    static func watchdog(
        configuration: RVDConfiguration,
        runtime: ServiceRuntime,
        exit: @escaping @Sendable () -> Void
    ) -> IdleWatchdog {
        let executable = ExecutableChangeProbe.running()
        return IdleWatchdog(
            seconds: configuration.idleExitSeconds,
            hasLiveGrants: { await runtime.hasLiveAllowOnceGrants() },
            executableChanged: { executable?.hasChanged() ?? false },
            onFire: exit
        )
    }

    /// Records this start (`StartupBackoff`) and returns the plan. Only a
    /// supervised rvd: one run by hand, by the SDK or by `rv` itself
    /// (DirectRvd) neither keeps a record nor waits.
    static func beginStartup(
        environment: [String: String],
        store: StartupBackoffStore? = nil
    ) -> StartupBackoff.Plan {
        guard StartupBackoff.isSupervised(environment: environment),
            let home = RVDLaunch.validatedHome(environment: environment)
        else { return StartupBackoff.untracked }
        let store = store ?? .live(home: home)
        let plan = StartupBackoff.plan(previous: store.load())
        // Saved before the wait: a run that dies while waiting still counts.
        store.save(plan.record)
        return plan
    }

    /// Waits out the delay earlier early exits earned. Called with the
    /// listeners bound but not yet accepting.
    static func waitOutBackoff(
        _ plan: StartupBackoff.Plan,
        sleep: (Duration) -> Void = { Thread.sleep(forTimeInterval: Double($0.components.seconds)) }
    ) {
        guard plan.delay > .zero else { return }
        log("rvd: \(plan.record.earlyExits) early exits in a row; waiting "
            + "\(plan.delay.components.seconds)s before serving (rv service restart skips the wait)")
        sleep(plan.delay)
    }

    /// Once listening: prewarm the judge unless early exits say it may be
    /// what keeps killing rvd, and clear the count once this run survives.
    static func serving(_ plan: StartupBackoff.Plan) {
        if plan.prewarmJudge {
            prewarmJudge()
        } else {
            log("rvd: skipping judge prewarm after \(plan.record.earlyExits) early exits; "
                + "the judge loads on the first judged request")
        }
        guard let home = RVDLaunch.validatedHome(environment: ProcessInfo.processInfo.environment) else { return }
        if plan.tracked {
            let store = StartupBackoffStore.live(home: home)
            let window = Int(StartupBackoff.survivalWindow.components.seconds)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(window)) {
                store.save(.survived)
            }
        }
        scheduleLogRotation(path: RVDLogFile.path(home: home))
    }

    /// rvd no longer idle-exits, so the startup rotation alone would let
    /// its log grow without bound.
    private static func scheduleLogRotation(path: String) {
        let interval = Int(RVDLogFile.rotationCheckInterval.components.seconds)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(interval)) {
            RVDLogFile.rotateIfFull(path: path)
            scheduleLogRotation(path: path)
        }
    }

    private static func log(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data(RVDLogFile.line(message).utf8))
    }

    /// Loads the judge off the main path after the listeners are up: the
    /// first Hello is never delayed, and the first judged request joins the
    /// in-progress load (bounded by `JudgeRuntime.daemonLoadWait`).
    static func prewarmJudge() {
        DispatchQueue.global(qos: .utility).async {
            JudgeRuntime.prewarm(home: HomeDirectory.process())
        }
    }
}
