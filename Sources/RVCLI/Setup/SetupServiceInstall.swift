import Foundation

extension SetupRun {
    static func writeLaunchAgent(
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps,
        keepAlive: Bool
    ) throws(SetupError) {
        let body = try LaunchAgentTemplate.rendered(rvdPath: env.rvdPath, keepAlive: keepAlive)
        do {
            try files.write(body, to: layout.launchAgent)
        } catch {
            throw SetupError.launchAgentWriteFailed
        }
        if env.touchLaunchd {
            try loadLaunchAgent(env: env, plist: URL(fileURLWithPath: layout.launchAgent))
        }
    }

    /// `launchctl bootstrap` if needed. Already-registered (exit 5) is success
    /// when `print` shows the job. Prefer `gui/`; fall back to `user/` when Aqua
    /// is missing so `curl | sh` from a Background session still completes.
    private static func loadLaunchAgent(env: SetupEnvironment, plist: URL) throws(SetupError) {
        let uid = env.uid()
        for domain in LaunchdDomain.bootoutOrder(uid: uid) {
            try? env.launchctl.bootout(domain: domain, label: launchAgentLabel)
        }
        for domain in LaunchdDomain.bootstrapOrder(uid: uid) {
            if acceptBootstrap(env.launchctl, domain: domain, plist: plist) {
                return
            }
        }
        throw SetupError.launchctlApplyFailed(.bootstrap)
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
