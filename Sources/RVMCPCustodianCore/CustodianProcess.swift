#if canImport(XPC)
import Darwin
import Foundation
import RVPolicy
import RVMCP
import Synchronization

public enum CustodianProcessError: Error, Sendable, Equatable {
    /// HOME is unset, so the custodian cannot resolve the config
    /// directory its enrollment file lives in. Never trust a client path.
    case homeMissing
}

public enum CustodianProcess {
    public static func run(configuration: CustodianConfiguration) throws {
        guard let home = HomeDirectory.process() else {
            throw CustodianProcessError.homeMissing
        }
        // The custodian resolves the config directory itself, with the
        // same resolver clients use; a client-supplied path is never read.
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        let handler = CustodianRequestHandler(
            service: MCPCustodianKeyService(
                signing: .custodianKeychain(configDirectory: configDirectory)))
        let slot = ListenerSlot()
        let watchdog = CustodianIdleWatchdog(seconds: configuration.idleExitSeconds) {
            slot.listener?.stop()
            Darwin.exit(0)
        }
        let listener = CustodianXPCListener(handler: handler, watchdog: watchdog)
        slot.listener = listener
        listener.start()
        Task { await watchdog.ping() }
        RunLoop.main.run()
    }
}

private final class ListenerSlot: Sendable {
    private let box = Mutex<CustodianXPCListener?>(nil)

    var listener: CustodianXPCListener? {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }
}
#endif
