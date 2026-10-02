#if canImport(XPC)
import Darwin
import Foundation
import RVAnalytics
import RVIPC
import Synchronization

public enum RVDProcess {
    public static func run(configuration: RVDConfiguration) throws {
        let socketURL = try UnixSocketPath.production()
        let analytics = AnalyticsBootstrap.makeLive(productVersion: ProtocolVersion.serviceSemver)
        let runtime = ServiceRuntime(
            idleExitSeconds: configuration.idleExitSeconds,
            analytics: analytics
        )
        let slot = ListenerSlot()
        let watchdog = IdleWatchdog(seconds: configuration.idleExitSeconds) {
            slot.listeners?.stop()
            Darwin.exit(0)
        }
        let listeners = ListenerPair(
            xpc: XPCEvaluateListener(runtime: runtime, watchdog: watchdog),
            unix: UnixSocketListener(runtime: runtime, watchdog: watchdog, socketURL: socketURL)
        )
        slot.listeners = listeners
        // Unix first: a bind failure exits before XPC registration, matching
        // the Linux `--socket` fail-fast behavior.
        try listeners.unix.start()
        listeners.xpc.start()
        Task { await watchdog.ping() }
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
import RVIPC
import Synchronization

public enum RVDProcess {
    public static func run(configuration: RVDConfiguration) throws {
        let socketURL = try UnixSocketPath.production()
        let analytics = AnalyticsBootstrap.makeLive(productVersion: ProtocolVersion.serviceSemver)
        let runtime = ServiceRuntime(
            idleExitSeconds: configuration.idleExitSeconds,
            analytics: analytics
        )
        let slot = ListenerSlot()
        let watchdog = IdleWatchdog(seconds: configuration.idleExitSeconds) {
            slot.listener?.stop()
            Foundation.exit(0)
        }
        let listener = UnixEvaluateListener(
            runtime: runtime,
            watchdog: watchdog,
            socketURL: socketURL
        )
        slot.listener = listener
        try listener.start()
        Task { await watchdog.ping() }
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
