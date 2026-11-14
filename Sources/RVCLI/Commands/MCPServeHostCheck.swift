import Dispatch
import Foundation
import RVHistory
import RVMCP
import Synchronization

/// The host-config check `rv mcp serve` runs once before serving: the
/// `rv mcp list` report, reduced to how many host entries bypass the
/// gateway or are unreviewed. It only warns; it never blocks serving.
extension MCPRun {
    /// How long `rv mcp serve` waits for the report before serving without it.
    static let hostCheckTimeout: TimeInterval = 2

    /// What `rv mcp serve` runs: the report over `environment`'s host
    /// configs (the same bounded reads as `rv mcp list`), warnings through
    /// `log` (stderr), the event in `environment`'s audit log.
    static func checkHostsBeforeServing(
        _ environment: MCPEnvironment, configuration: MCPConfiguration, project: URL?, log: (String) -> Void
    ) {
        let rvExecutable = MCPExecutable.currentPath()
        checkHosts(
            report: { report(environment, project: project, configuration: configuration, rvExecutable: rvExecutable) },
            log: log,
            audit: { AuditLog.append($0, configDirectory: environment.configDirectory) })
    }

    /// Waits at most `timeout` for `report`; a report still running then is
    /// abandoned with one line. When host entries bypass the gateway or are
    /// unreviewed: one line and one event, counts only, so no text from a
    /// host config reaches either. A failed audit write is said on `log`
    /// and changes nothing else. Never writes stdout.
    static func checkHosts(
        timeout: TimeInterval = hostCheckTimeout,
        report: @escaping @Sendable () -> Report,
        log: (String) -> Void,
        audit: (AuditEvent) -> Bool,
        clock: () -> Date = { Date() }
    ) {
        guard let finished = within(timeout, report) else {
            log("could not check host MCP configs within \(String(format: "%g", timeout)) s; run `rv mcp check` to see them")
            return
        }
        let bypass = finished.rows.filter { $0.status == MCPEntryStatus.bypass.rawValue }.count
        let unreviewed = finished.rows.filter { $0.status == MCPEntryStatus.unreviewed.rawValue }.count
        let total = bypass + unreviewed
        guard total > 0 else { return }
        let summary = "host MCP configs hold \(total) server\(total == 1 ? "" : "s") rv does not govern "
            + "(\(bypass) bypass the gateway, \(unreviewed) unreviewed); run `rv mcp check` to see them"
        log(summary)
        let event = AuditEvent(
            time: clock(), kind: .mcpHostsUngoverned, decision: .info, subject: "mcp-hosts", reason: summary,
            source: "mcp-gateway", detail: ["bypass": String(bypass), "unreviewed": String(unreviewed)])
        if audit(event) == false { log("could not append the audit log") }
    }

    /// `work`'s result when it finishes within `timeout` seconds, else nil.
    /// It runs on its own thread, which is left to finish (or stay blocked,
    /// say on a FIFO swapped in for a host config) on its own.
    static func within<T: Sendable>(_ timeout: TimeInterval, _ work: @escaping @Sendable () -> T) -> T? {
        let result = Mutex<T?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let value = work()
            result.withLock { $0 = value }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return result.withLock { $0 }
    }
}
