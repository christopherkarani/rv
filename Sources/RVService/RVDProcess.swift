#if canImport(XPC)
import Darwin
import Foundation
import RVAnalytics
import RVIPC

public enum RVDProcess {
    public static func run(configuration: RVDConfiguration) throws {
        let analytics = AnalyticsBootstrap.live(productVersion: ProtocolVersion.serviceSemver)
        let runtime = ServiceRuntime(
            idleExitSeconds: configuration.idleExitSeconds,
            analytics: analytics
        )
        let slot = ListenerSlot()
        let watchdog = IdleWatchdog(seconds: configuration.idleExitSeconds) {
            slot.listener?.stop()
            Darwin.exit(0)
        }
        let listener = XPCEvaluateListener(runtime: runtime, watchdog: watchdog)
        slot.listener = listener
        listener.start()
        Task { await watchdog.ping() }
        RunLoop.main.run()
    }
}

private final class ListenerSlot: @unchecked Sendable {
    var listener: XPCEvaluateListener?
}
#else
import Foundation
import RVAnalytics
import RVIPC

public enum RVDProcess {
    public static func run(configuration: RVDConfiguration) throws {
        let socketURL = try UnixSocketPath.production()
        let analytics = AnalyticsBootstrap.live(productVersion: ProtocolVersion.serviceSemver)
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

private final class ListenerSlot: @unchecked Sendable {
    var listener: UnixEvaluateListener?
}
#endif
