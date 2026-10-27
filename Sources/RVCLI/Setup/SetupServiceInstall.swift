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
            try loadLaunchAgent(
                env: env, plist: URL(fileURLWithPath: layout.launchAgent), label: launchAgentLabel)
        }
        try writeCustodianLaunchAgent(env: env, layout: layout, files: files)
    }

    // The approvals custodian ships separately (RVApprovals.app). Register it
    // only when the bundle executable is installed; without it MCP approvals
    // stay disabled and every other setup step is unaffected.
    static func writeCustodianLaunchAgent(
        env: SetupEnvironment,
        layout: OwnedPaths,
        files: FileOps
    ) throws(SetupError) {
        guard env.fileManager.isExecutableFile(atPath: layout.custodianAppExecutable) else { return }
        let body = try LaunchAgentTemplate.renderedCustodian(
            custodianPath: layout.custodianAppExecutable)
        do {
            try files.write(body, to: layout.custodianLaunchAgent)
        } catch {
            throw SetupError.launchAgentWriteFailed
        }
        if env.touchLaunchd {
            try loadLaunchAgent(
                env: env,
                plist: URL(fileURLWithPath: layout.custodianLaunchAgent),
                label: custodianLaunchAgentLabel)
        }
    }

    /// `launchctl bootstrap` if needed. Already-registered (exit 5) is success
    /// when `print` shows the job. Prefer `gui/`; fall back to `user/` when Aqua
    /// is missing so `curl | sh` from a Background session still completes.
    private static func loadLaunchAgent(
        env: SetupEnvironment, plist: URL, label: String
    ) throws(SetupError) {
        let uid = env.uid()
        for domain in LaunchdDomain.bootoutOrder(uid: uid) {
            try? env.launchctl.bootout(domain: domain, label: label)
        }
        for domain in LaunchdDomain.bootstrapOrder(uid: uid) {
            if acceptBootstrap(env.launchctl, domain: domain, plist: plist, label: label) {
                return
            }
        }
        throw SetupError.launchctlApplyFailed(.bootstrap)
    }

    static func acceptBootstrap(
        _ launchctl: any LaunchctlApplying,
        domain: String,
        plist: URL,
        label: String = launchAgentLabel
    ) -> Bool {
        do {
            try launchctl.bootstrap(domain: domain, plist: plist)
            return true
        } catch {
            return launchctl.isLoaded(domain: domain, label: label)
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
