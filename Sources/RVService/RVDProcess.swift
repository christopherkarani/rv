import Darwin
import Foundation
import RVAnalytics
import RVIPC

public enum RVDProcess {
    public static func run(configuration: RVDConfiguration) throws {
        let analytics = AnalyticsBootstrap.live(productVersion: ProtocolVersion.serviceSemver)
        let watchdog = IdleWatchdog(seconds: configuration.idleExitSeconds) {
            Darwin.exit(0)
        }
        let runtime = ServiceRuntime(
            idleExitSeconds: configuration.idleExitSeconds,
            analytics: analytics,
            onActivity: { await watchdog.ping() }
        )
        let listener = XPCEvaluateListener(runtime: runtime)
        listener.start()
        Task { await watchdog.ping() }
        RunLoop.main.run()
    }
}
