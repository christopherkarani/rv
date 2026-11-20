#if canImport(XPC)
import Darwin
import Foundation
import RVAnalytics
import RVDomain
import RVIPC
import RVLaya
import RVPolicy
import Synchronization

public enum RVDProcess {
    public static func run(configuration: RVDConfiguration) throws {
        try RVDLaunch.requireHome(environment: ProcessInfo.processInfo.environment)
        let socketURL = try UnixSocketPath.production()
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
        RVDLifecycle.bindCoreMLGuard()
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
        RVDLifecycle.prewarmJudge()
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
import RVLaya
import RVPolicy
import Synchronization

public enum RVDProcess {
    public static func run(configuration: RVDConfiguration) throws {
        try RVDLaunch.requireHome(environment: ProcessInfo.processInfo.environment)
        let socketURL = try UnixSocketPath.production()
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
        RVDLifecycle.prewarmJudge()
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
    /// Idle exit that keeps the process (and its allow-once table) while
    /// grants are live, and exits once its own binary was replaced on disk.
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

    /// Binds the crash-aware Core ML guard before any judge can load: the
    /// previous run's in-flight marker is read on first use, so nothing may
    /// touch Core ML before this. Its lines go to stderr (rvd.log).
    static func bindCoreMLGuard() {
        #if canImport(CoreML)
        CoreMLGuard.bind(.daemon(stateRoot: JudgeRuntime.coreMLStateRoot()) { message in
            try? FileHandle.standardError.write(contentsOf: Data(RVDLogFile.line(message).utf8))
        })
        DispatchQueue.global(qos: .background).async { CoreMLGuard.sweepLegacyCompiledModels() }
        #endif
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
