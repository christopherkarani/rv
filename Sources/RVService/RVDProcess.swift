#if canImport(XPC)
import Darwin
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
        JudgeRuntime.bindLoadWait(JudgeRuntime.daemonLoadWait)
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
        // would block every hook on each launchd activation.
        do {
            try listeners.unix.start()
        } catch {
            try? FileHandle.standardError.write(contentsOf:
                Data(RVDLogFile.line("rvd: unix socket unavailable (\(error)); continuing with XPC only").utf8)
            )
        }
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
        try listener.start()
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

    /// Applies `StartupBackoff` before rvd listens: records this start and
    /// waits out the delay the previous early exits earned.
    static func beginStartup(
        environment: [String: String],
        store: StartupBackoffStore? = nil,
        sleep: (Duration) -> Void = { Thread.sleep(forTimeInterval: Double($0.components.seconds)) }
    ) -> StartupBackoff.Plan {
        guard let home = RVDLaunch.validatedHome(environment: environment) else {
            return StartupBackoff.plan(previous: nil)
        }
        let store = store ?? .live(home: home)
        let plan = StartupBackoff.plan(previous: store.load())
        // Saved before the wait: a run that dies while waiting still counts.
        store.save(plan.record)
        if plan.delay > .zero {
            log("rvd: \(plan.record.earlyExits) early exits in a row; waiting "
                + "\(plan.delay.components.seconds)s before starting (rv service restart skips the wait)")
            sleep(plan.delay)
        }
        return plan
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
        let store = StartupBackoffStore.live(home: home)
        let window = Int(StartupBackoff.survivalWindow.components.seconds)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(window)) {
            store.save(.survived)
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
