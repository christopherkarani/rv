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
        let listener = XPCEvaluateListener(runtime: runtime)
        listener.start()
        let watchdog = IdleWatchdog(seconds: configuration.idleExitSeconds) {
            listener.stop()
            Darwin.exit(0)
        }
        Task { await watchdog.ping() }
        RunLoop.main.run()
    }
}
