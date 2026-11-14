import Dispatch
import Foundation
import RVDomain
import RVHistory
import RVMCP
import Synchronization

/// The host-config check each `rv mcp serve` process runs once before
/// serving: the `rv mcp list` inventory, reduced to how many host entries
/// run a server around the gateway or hold an unreviewed one. It only
/// warns; it never blocks serving.
extension MCPRun {
    /// How long `rv mcp serve` waits for the check and its audit append
    /// together before serving without them.
    static let hostCheckTimeout: TimeInterval = 2

    /// Host entries `rv mcp check` fails on because they run a server
    /// outside rv or one nobody reviewed.
    struct HostCheckCounts: Sendable, Equatable {
        /// mcp.json defines the server, but the host runs it directly.
        var bypass = 0
        /// mcp.json blocks the server, but the host runs it directly (not
        /// through rv, not disabled).
        var blocked = 0
        /// mcp.json does not mention the server.
        var unreviewed = 0

        var total: Int { bypass + blocked + unreviewed }
    }

    /// `rows` counted as `HostCheckCounts`. A blocked entry counts only when
    /// the host launches it itself: through `rv mcp serve` rv refuses it,
    /// and a disabled one does not run.
    static func hostCheckCounts(_ rows: [MCPInventoryRow], rvExecutable: String) -> HostCheckCounts {
        var counts = HostCheckCounts()
        for row in rows {
            switch row.status {
            case .bypass: counts.bypass += 1
            case .unreviewed: counts.unreviewed += 1
            case .blocked:
                let throughRV = row.entry.governedServer != nil && row.entry.launches(rvExecutable)
                if throughRV == false, row.entry.isDisabled == false { counts.blocked += 1 }
            case .governed, .direct, .dangling, .disabled: break
            }
        }
        return counts
    }

    /// What `rv mcp serve` runs: the inventory of `environment`'s host
    /// configs (the same bounded reads as `rv mcp list`), warnings through
    /// `log` (stderr), the event in `environment`'s audit log. Only the
    /// home, process environment and config directory reach the worker:
    /// never the approvals key, so no integrity check and no custodian call.
    static func checkHostsBeforeServing(
        _ environment: MCPEnvironment, configuration: MCPConfiguration, project: URL?,
        managedDirectory: String = MCPHostConfigPaths.claudeCodeManagedDirectory,
        timeout: TimeInterval = hostCheckTimeout, log: (String) -> Void
    ) {
        let rvExecutable = MCPExecutable.currentPath()
        let home = environment.home
        let processEnvironment = environment.processEnvironment
        let configDirectory = environment.configDirectory
        checkHosts(
            timeout: timeout,
            count: {
                let inventory = MCPInventory.discover(
                    home: home, project: project, environment: processEnvironment, managedDirectory: managedDirectory)
                return hostCheckCounts(
                    MCPInventoryRow.rows(inventory, configuration: configuration, rvExecutable: rvExecutable),
                    rvExecutable: rvExecutable)
            },
            log: log,
            audit: { AuditLog.append($0, configDirectory: configDirectory) })
    }

    /// Runs `count`, then `audit` with the event, on their own thread, and
    /// waits for both at most `timeout` in all; whatever is still running
    /// then is left to finish on its own, and one line says which. A count
    /// that finishes late may still append its event. Ungoverned entries
    /// are one line and one event, counts only, so no text from a host
    /// config reaches either. A late or failed audit write is said on `log`
    /// and changes nothing else. Never writes stdout.
    static func checkHosts(
        timeout: TimeInterval = hostCheckTimeout,
        count: @escaping @Sendable () -> HostCheckCounts,
        log: (String) -> Void,
        audit: @escaping @Sendable (AuditEvent) -> Bool,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let deadline = DispatchTime.now() + timeout
        let shownTimeout = String(format: "%g", timeout)
        // nil until counted; then the notice, or nil when there is none.
        let counted = Mutex<HostCheckNotice??>(nil)
        let audited = Mutex<Bool?>(nil)
        let countDone = DispatchSemaphore(value: 0)
        let auditDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let notice = hostCheckNotice(count(), time: clock())
            counted.withLock { $0 = .some(notice) }
            countDone.signal()
            guard let notice else { return }
            let written = audit(notice.event)
            audited.withLock { $0 = written }
            auditDone.signal()
        }
        guard countDone.wait(timeout: deadline) == .success, let found = counted.withLock({ $0 }) else {
            log(
                "still checking host MCP configs after \(shownTimeout) s; serving without waiting; "
                    + "run `rv mcp check` to see them")
            return
        }
        guard let notice = found else { return }
        log(notice.line)
        guard auditDone.wait(timeout: deadline) == .success else {
            log("audit append still running after \(shownTimeout) s; serving without waiting")
            return
        }
        if audited.withLock({ $0 }) != true { log("could not append the audit log") }
    }

    struct HostCheckNotice: Sendable {
        var line: String
        var event: AuditEvent
    }

    /// The stderr line and audit event for `counts`; nil when nothing is ungoverned.
    static func hostCheckNotice(_ counts: HostCheckCounts, time: Date) -> HostCheckNotice? {
        guard counts.total > 0 else { return nil }
        let line = "host MCP configs hold \(counts.total) entr\(counts.total == 1 ? "y" : "ies") rv does not govern "
            + "(\(counts.bypass) bypass the gateway, \(counts.blocked) blocked in mcp.json but still run, "
            + "\(counts.unreviewed) unreviewed); run `rv mcp check` to see them"
        let event = AuditEvent(
            time: time, kind: .mcpHostsUngoverned, decision: .info, subject: "mcp-hosts", reason: line,
            source: "mcp-gateway",
            detail: ["bypass": String(counts.bypass), "blocked": String(counts.blocked), "unreviewed": String(counts.unreviewed)])
        return HostCheckNotice(line: line, event: event)
    }
}
