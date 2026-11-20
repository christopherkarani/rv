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
        RVDLifecycle.armStateMarker()
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
        RVDLifecycle.armStateMarker()
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
        let announced = OnceFlag()
        return IdleWatchdog(
            seconds: configuration.idleExitSeconds,
            hasLiveGrants: { await runtime.hasLiveAllowOnceGrants() },
            executableChanged: {
                guard executable?.hasChanged() ?? false else { return false }
                // An upgrade replaced rvd: it drains and exits, and the
                // supervisor starts the new binary. Announce that restart
                // once, so observe-mode hooks do not fail closed meanwhile.
                if announced.claim(), let marker = stateMarkerPath() {
                    RVDStateMarker.writeRestarting(path: marker)
                }
                return true
            },
            onFire: exit
        )
    }

    /// The owner's marker, only when rvd runs with the owner's own HOME
    /// (launchd and systemd set it so); a test HOME never touches it.
    static func stateMarkerPath() -> String? {
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return nil }
        return RVDStateMarker.passwdPath(ifHomeIs: home)
    }

    /// rvd serves: arm the marker now, then re-arm on a tick so deleting it
    /// in one command and stopping rvd in a later one still fails closed.
    /// The tick leaves a pending restart (`rv setup`, an upgrade) alone.
    static func armStateMarker() {
        guard let marker = stateMarkerPath() else { return }
        RVDStateMarker.writeArmed(path: marker)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + RVDStateMarker.rearmInterval,
            repeating: RVDStateMarker.rearmInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { _ = RVDStateMarker.rearm(path: marker) }
        timer.resume()
        stateMarkerTimer.keep(timer)
    }

    /// Keeps the re-arm timer alive for the process lifetime.
    private static let stateMarkerTimer = TimerSlot()

    /// Loads the judge off the main path after the listeners are up: the
    /// first Hello is never delayed, and the first judged request joins the
    /// in-progress load (bounded by `JudgeRuntime.daemonLoadWait`).
    static func prewarmJudge() {
        DispatchQueue.global(qos: .utility).async {
            JudgeRuntime.prewarm(home: HomeDirectory.process())
        }
    }
}

/// True for the first `claim()` only.
final class OnceFlag: Sendable {
    private let flag = Atomic<Bool>(false)

    func claim() -> Bool {
        flag.exchange(true, ordering: .relaxed) == false
    }
}

private final class TimerSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    func keep(_ timer: DispatchSourceTimer) {
        lock.lock()
        self.timer = timer
        lock.unlock()
    }
}
