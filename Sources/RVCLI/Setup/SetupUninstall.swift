import Foundation
import RVAnalytics
import RVDomain
import RVHistory
import RVHooks
import RVPolicy
import RVPresentation

extension SetupRun {
    static func uninstallPerform(
        _ env: SetupEnvironment,
        appearance: CLIAppearance,
        clock: any SetupCeremonyClock,
        animate: Bool,
        write: ((String) -> Void)?
    ) throws(SetupError) -> (text: String, emitted: Bool) {
        let files = FileOps(fileManager: env.fileManager)
        let layout = OwnedPaths(home: env.home)
        let installations = try inspectInstallations(layout: layout, env: env)
        let detached = try HostLifecycle.detach(
            installations: installations,
            env: env,
            layout: layout,
            files: files
        )
        let removedHosts = detached.removedHosts
        let occupiedHosts = detached.occupiedHosts
        var removedPaths = detached.removedPaths

        let servicePath = evaluateServicePath(layout: layout, supervisor: env.supervisor)
        let launchAgentExisted = files.fileExists(servicePath)
        let binariesExisted = files.fileExists(layout.localRv)
            || files.fileExists(layout.localRvCli)
            || files.fileExists(layout.localRvd)
        removedPaths.append(
            contentsOf: [servicePath, layout.localRv, layout.localRvCli, layout.localRvd]
        )

        let configDir = URL(fileURLWithPath: layout.configDirectory, isDirectory: true)
        let analytics = AnalyticsPaths(configDirectory: configDir)
        let configArtifacts =
            analytics.uninstallArtifacts
            + RVPolicyPaths.uninstallArtifacts(inConfigDir: configDir)
            + DenialLedgerPaths(configDirectory: configDir).uninstallArtifacts
        let configExisted = configArtifacts.contains { files.fileExists($0.path) }
        for artifact in configArtifacts {
            removedPaths.append(artifact.path)
        }

        for path in removedPaths {
            files.removeFile(atPath: path)
        }
        files.removeDirectoryIfEmpty(atPath: layout.configDirectory)

        if env.supervisor == .launchd, env.touchLaunchd {
            let uid = env.uid()
            try? env.launchctl.bootout(domain: LaunchdDomain.user(uid), label: launchAgentLabel)
            do {
                try env.launchctl.bootout(domain: LaunchdDomain.gui(uid), label: launchAgentLabel)
            } catch {
                throw SetupError.launchctlApplyFailed(.bootout)
            }
        }
        if env.supervisor == .systemdUser, env.touchSystemd {
            do {
                try env.systemctl.disableNow(unit: SystemdUserTemplate.unitName)
            } catch {
                throw SetupError.systemdApplyFailed(.disable)
            }
        }

        if removedPaths.contains(where: { files.fileExists($0) }) {
            throw SetupError.ownedPathStillExists
        }

        let report = UninstallReport(
            removedHosts: removedHosts,
            occupiedHosts: occupiedHosts,
            removedLaunchAgent: launchAgentExisted,
            removedBinaries: binariesExisted,
            removedConfigArtifacts: configExisted
        )
        return SetupFormat.uninstallStdout(
            report: report,
            appearance: appearance,
            clock: clock,
            animate: animate,
            write: write
        )
    }

    /// Removes rv-fingerprinted Cursor handlers only. Returns whether anything changed.
    static func removeCursorRVHooks(at path: String, files: FileOps) throws(SetupError) -> Bool {
        if files.isSymbolicLink(path) {
            return false
        }
        guard let data = files.readData(path) else { return false }
        let next: Data?
        do {
            next = try CursorHooksMerge.uninstall(existingData: data)
        } catch {
            throw SetupError.hostHookWriteFailed(.cursor)
        }
        guard let next else {
            files.removeFile(atPath: path)
            return true
        }
        if next == data {
            return false
        }
        do {
            try files.writeData(next, to: path)
        } catch {
            throw SetupError.hostHookWriteFailed(.cursor)
        }
        return true
    }

    /// Removes rv-fingerprinted Codex handlers only. Returns whether anything changed.
    static func removeCodexRVHooks(at path: String, files: FileOps) throws(SetupError) -> Bool {
        if files.isSymbolicLink(path) {
            return false
        }
        guard let data = files.readData(path) else { return false }
        let next: Data?
        do {
            next = try CodexHooksMerge.uninstall(existingData: data)
        } catch {
            throw SetupError.hostHookWriteFailed(.codex)
        }
        guard let next else {
            files.removeFile(atPath: path)
            return true
        }
        if next == data {
            return false
        }
        do {
            try files.writeData(next, to: path)
        } catch {
            throw SetupError.hostHookWriteFailed(.codex)
        }
        return true
    }

    /// Companion uninstall entry. AC-013: the companion app's uninstaller calls this
    /// library entry to clear KeepAlive in-place without removing CLI/rvd. Not wired
    /// to `rv uninstall` (which removes owned files) to avoid accidental user use.
    /// Probe is performed by the caller via `env.companionPresence`; this helper
    /// just enforces the post-uninstall invariant (KeepAlive == false) when a
    /// plist already exists. Linux is a no-op (systemd `Restart=no` is static).
    static func restoreKeepAliveAfterCompanionUninstall(
        _ env: SetupEnvironment
    ) throws(SetupError) {
        guard env.supervisor == .launchd else { return }
        let files = FileOps(fileManager: env.fileManager)
        let layout = OwnedPaths(home: env.home)
        guard files.fileExists(layout.launchAgent) else { return }
        try writeLaunchAgent(env: env, layout: layout, files: files, keepAlive: false)
    }

    /// Removes rv-fingerprinted Claude handlers only. Returns whether anything changed.
    static func removeClaudeRVHooks(at path: String, files: FileOps) throws(SetupError) -> Bool {
        try applyClaudeUninstall(at: path, files: files, unreadable: .fail)
    }

    /// Occupied foreign/tampered `rv-guard.py` still strips on uninstall.
    static func stripClaudeFingerprintLeavingOccupied(
        at path: String,
        files: FileOps
    ) throws(SetupError) -> Bool {
        try applyClaudeUninstall(at: path, files: files, unreadable: .leave)
    }

    private enum ClaudeUnreadableUninstall {
        case fail
        case leave
    }

    private static func applyClaudeUninstall(
        at path: String,
        files: FileOps,
        unreadable: ClaudeUnreadableUninstall
    ) throws(SetupError) -> Bool {
        if files.isSymbolicLink(path) {
            return false
        }
        guard let data = files.readData(path) else {
            return removeClaudeAdapterIfCurrent(settingsPath: path, files: files)
        }
        let next: Data?
        do {
            next = try ClaudeSettingsMerge.uninstall(existingData: data)
        } catch {
            switch unreadable {
            case .fail:
                throw SetupError.hostHookWriteFailed(.claude)
            case .leave:
                return false
            }
        }
        var wroteSettings = false
        if let next {
            if next != data {
                do {
                    try files.writeData(next, to: path)
                } catch {
                    throw SetupError.hostHookWriteFailed(.claude)
                }
                wroteSettings = true
            }
        } else {
            files.removeFile(atPath: path)
            wroteSettings = true
        }
        let removedAdapter = removeClaudeAdapterIfCurrent(settingsPath: path, files: files)
        return wroteSettings || removedAdapter
    }

    /// Removes `~/.claude/hooks/rv-guard.py` when it is the current rv adapter.
    private static func removeClaudeAdapterIfCurrent(settingsPath: String, files: FileOps) -> Bool {
        let adapterPath = ClaudeSettingsMerge.adapterPath(settingsPath: settingsPath)
        if files.isSymbolicLink(adapterPath) {
            return false
        }
        guard let data = files.readData(adapterPath),
              let text = String(data: data, encoding: .utf8),
              let adapter = try? HostAdapterResources.load(for: .claude),
              adapter.matchesCurrent(text)
        else {
            return false
        }
        files.removeFile(atPath: adapterPath)
        return true
    }
}
