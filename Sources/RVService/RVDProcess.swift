import Darwin
import Foundation

public enum RVDProcess {
    public static func run(configuration: RVDConfiguration) throws {
        let runtime = ServiceRuntime(idleExitSeconds: configuration.idleExitSeconds)
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
