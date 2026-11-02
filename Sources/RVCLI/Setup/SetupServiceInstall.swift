#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

extension SetupRun {
    /// Renders the plist and, when this HOME owns the real launchd session,
    /// (re)loads it. Returns the domain the job landed in, if it was loaded.
    @discardableResult
    static func writeLaunchAgent(
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps,
        keepAlive: Bool
    ) throws(SetupError) -> String? {
        let body = try LaunchAgentTemplate.rendered(rvdPath: env.rvdPath, keepAlive: keepAlive)
        do {
            try files.write(body, to: layout.launchAgent)
        } catch {
            throw SetupError.launchAgentWriteFailed
        }
        guard env.touchLaunchd else { return nil }
        return try loadLaunchAgent(env: env, plist: URL(fileURLWithPath: layout.launchAgent))
    }

    /// Polling cadence and ceiling for the job to leave launchd after bootout.
    static let unloadPollInterval: TimeInterval = 0.1
    static let unloadPollLimit: TimeInterval = 3.0
    /// `gui/` bootstrap attempts and the backoff before each retry. launchctl
    /// commonly answers 5 (Input/output error) right after a bootout.
    static let bootstrapBackoff: [TimeInterval] = [0.25, 0.5]

    /// Boots out both domains, waits for the job to leave, then bootstraps
    /// into `gui/<uid>` (where Aqua hosts resolve the Mach service), retrying
    /// briefly. `user/<uid>` is used only when no `gui/` domain exists (SSH /
    /// Background session); a job there is unreachable from Aqua hosts, so a
    /// failing `gui/` bootstrap is an error, never a silent `user/` landing.
    @discardableResult
    static func loadLaunchAgent(env: SetupEnvironment, plist: URL) throws(SetupError) -> String {
        let uid = env.uid()
        for domain in LaunchdDomain.bootoutOrder(uid: uid) {
            try? env.launchctl.bootout(domain: domain, label: launchAgentLabel)
        }
        waitUntilUnloaded(env: env, uid: uid)

        let gui = LaunchdDomain.gui(uid)
        guard env.launchctl.domainExists(gui) else {
            let user = LaunchdDomain.user(uid)
            if acceptBootstrap(env.launchctl, domain: user, plist: plist) {
                return user
            }
            throw SetupError.launchctlApplyFailed(.bootstrap)
        }
        if acceptBootstrap(env.launchctl, domain: gui, plist: plist) {
            return gui
        }
        for delay in bootstrapBackoff {
            env.sleep(delay)
            if acceptBootstrap(env.launchctl, domain: gui, plist: plist) {
                return gui
            }
        }
        throw SetupError.launchctlApplyFailed(.bootstrap)
    }

    private static func waitUntilUnloaded(env: SetupEnvironment, uid: uid_t) {
        let domains = LaunchdDomain.bootoutOrder(uid: uid)
        let maxPolls = Int((unloadPollLimit / unloadPollInterval).rounded(.down))
        var polls = 0
        while polls < maxPolls,
            domains.contains(where: { env.launchctl.isLoaded(domain: $0, label: launchAgentLabel) })
        {
            env.sleep(unloadPollInterval)
            polls += 1
        }
    }

    static func acceptBootstrap(
        _ launchctl: any LaunchctlApplying,
        domain: String,
        plist: URL
    ) -> Bool {
        do {
            try launchctl.bootstrap(domain: domain, plist: plist)
            return true
        } catch {
            return launchctl.isLoaded(domain: domain, label: launchAgentLabel)
        }
    }

    static func writeSystemdUserUnit(
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) {
        let body = try SystemdUserTemplate.rendered(rvdPath: env.rvdPath)
        do {
            try files.write(body, to: layout.systemdUserUnit)
        } catch {
            throw SetupError.systemdUnitWriteFailed
        }
        if env.touchSystemd {
            do {
                try env.systemctl.enableNow(unit: SystemdUserTemplate.unitName)
            } catch {
                throw SetupError.systemdApplyFailed(.enable)
            }
        }
    }

    static func evaluateServicePath(layout: OwnedPaths, supervisor: EvaluateSupervisor) -> String {
        switch supervisor {
        case .launchd:
            layout.launchAgent
        case .systemdUser:
            layout.systemdUserUnit
        }
    }
}
