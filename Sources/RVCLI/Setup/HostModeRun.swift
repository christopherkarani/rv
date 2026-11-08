#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVPolicy
import RVService

/// `rv host list` / `rv host mode`: per-host guard posture plus the one
/// host's wiring. Wiring reuses setup's per-host attach and uninstall's
/// per-host detach; nothing here merges host files itself.
enum HostModeRun {
    struct Row: Encodable, Equatable {
        let host: String
        let mode: String
        let wiring: String
    }

    struct ListDocument: Encodable, Equatable {
        let guardMode: String
        let hosts: [Row]
        let managedEnforce: Bool
        let schema = "rv.hosts.v1"

        enum CodingKeys: String, CodingKey {
            case guardMode = "guard"
            case hosts
            case managedEnforce = "managed_enforce"
            case schema
        }
    }

    struct ModeDocument: Encodable, Equatable {
        let host: String
        let mode: String
        let schema = "rv.host-mode.v1"
        let wiring: String
    }

    /// A row's `mode` is the host's effective mode, not only what is stored:
    /// a stored entry wins; a host with none follows the global
    /// `guard.mode`, so under global observe it reads `observe`, never a
    /// `block` it would not enforce. The organization pin is reported
    /// separately (`managed_enforce`).
    static func effectiveMode(stored: HostMode?, guardMode: GuardMode) -> HostMode {
        if let stored { return stored }
        return guardMode == .observe ? .observe : .block
    }

    static func list(_ env: SetupEnvironment, json: Bool) -> SetupOutcome {
        do {
            let installations = try SetupRun.inspectInstallations(layout: OwnedPaths(home: env.home), env: env)
            let modes = store(env).load()
            let guardMode = JudgeRuntime.guardMode(home: env.home)
            let rows = HookHost.allCases
                .sorted { $0.rawValue < $1.rawValue }
                .map { host in
                    Row(
                        host: host.rawValue,
                        mode: effectiveMode(stored: modes[host], guardMode: guardMode).rawValue,
                        wiring: installations.state(for: host).rawValue
                    )
                }
            let document = ListDocument(
                guardMode: guardMode.rawValue,
                hosts: rows,
                managedEnforce: env.managedEnforce(env.home)
            )
            if json {
                return SetupOutcome(stdout: try RobotJSON.encode(document) + "\n", exitCode: 0)
            }
            var lines = rows.map { "\($0.host)  \($0.mode)  \($0.wiring)" }
            if document.managedEnforce {
                lines.append("organization gate pins enforce: observe and off do not change evaluation")
            }
            return SetupOutcome(stdout: lines.joined(separator: "\n") + "\n", exitCode: 0)
        } catch let error as SetupError {
            return failure(error, command: .hostList)
        } catch {
            return SetupOutcome(stdout: "", stderr: "rv host list failed: \(error)\n", exitCode: EX_SOFTWARE)
        }
    }

    /// Loosening (toward `off`) needs `authenticate` first; on refusal
    /// nothing is written. `off` removes this host's rv-owned hook files;
    /// leaving `off` re-wires the host when it is detected. `off` is
    /// refused while an organization gate pins enforce (unwiring the hook
    /// would bypass the org policy); `observe` is still stored, since rvd
    /// pins enforce under the gate anyway.
    static func setMode(
        _ mode: HostMode,
        for host: HookHost,
        env: SetupEnvironment,
        json: Bool,
        authenticate: () async throws -> Void
    ) async -> SetupOutcome {
        do {
            try SetupRun.requireInstalledCopy(env)
            if mode == .off, env.managedEnforce(env.home) {
                return SetupOutcome(
                    stdout: "",
                    stderr: "rv host mode failed: organization policy requires rv on \(host.rawValue)\n",
                    exitCode: EX_NOPERM)
            }
            let store = store(env)
            let current = store.mode(for: host)
            if mode.isLooser(than: current) {
                do {
                    try await authenticate()
                } catch {
                    throw SetupError.ownerAuthenticationRequired
                }
            }
            // Order keeps every intermediate state no looser than both ends
            // at rvd: going `off`, the hooks come out before `off` is
            // stored (a failed detach stores nothing, so wired hooks never
            // run under `off`, and a retry still needs the owner); leaving
            // `off`, the tighter mode is stored before re-wiring (a failed
            // re-wire leaves the host unwired under that mode, which
            // `rv setup` repairs).
            if mode == .off {
                try applyWiring(from: current, to: mode, host: host, env: env)
            }
            do {
                try store.save(mode, for: host)
            } catch {
                return SetupOutcome(
                    stdout: "", stderr: "rv host mode failed: unable to write config.json\n",
                    exitCode: EX_CANTCREAT)
            }
            if mode != .off {
                try applyWiring(from: current, to: mode, host: host, env: env)
            }
            let wiring = try SetupRun.inspectInstallations(layout: OwnedPaths(home: env.home), env: env)
                .state(for: host).rawValue
            if json {
                let document = ModeDocument(host: host.rawValue, mode: mode.rawValue, wiring: wiring)
                return SetupOutcome(stdout: try RobotJSON.encode(document) + "\n", exitCode: 0)
            }
            return SetupOutcome(stdout: "\(host.rawValue)  \(mode.rawValue)  \(wiring)\n", exitCode: 0)
        } catch let error as SetupError {
            return failure(error, command: .hostMode)
        } catch {
            return SetupOutcome(stdout: "", stderr: "rv host mode failed: \(error)\n", exitCode: EX_SOFTWARE)
        }
    }

    private static func applyWiring(
        from current: HostMode,
        to mode: HostMode,
        host: HookHost,
        env: SetupEnvironment
    ) throws(SetupError) {
        let files = FileOps(fileManager: env.fileManager)
        let layout = OwnedPaths(home: env.home)
        let installations = try SetupRun.inspectInstallations(layout: layout, env: env)
        if mode == .off {
            let detached = try HostLifecycle.detach(
                installations: installations, env: env, layout: layout, files: files, only: [host])
            // Detach drops a file it cannot remove silently: check it left.
            let after = try SetupRun.inspectInstallations(layout: layout, env: env)
            if detached.removedPaths.contains(where: files.fileExists) || after.state(for: host) == .wired {
                throw SetupError.hostHookRemoveFailed(host)
            }
            return
        }
        guard current == .off else { return }
        switch SetupWorkPlanBuilder.step(
            for: host, installation: installations.installation(for: host), layout: layout, force: false
        ) {
        case .write(let write), .forceClearThenWrite(let write):
            _ = try HostLifecycle.perform(write, env: env, layout: layout, files: files)
        case .createConfigDirectory, .writeLaunchAgent, .skipLaunchAgent,
            .skipUndetected, .skipOccupied, .skipOff:
            break
        }
    }

    private static func store(_ env: SetupEnvironment) -> HostModeStore {
        HostModeStore(configDirectory: RVPolicyPaths.configDirectory(home: env.home))
    }

    private static func failure(_ error: SetupError, command: SetupFailureCommand) -> SetupOutcome {
        let output = setupFailureOutput(error, command: command)
        return SetupOutcome(stdout: "", stderr: output.stderr, exitCode: output.exitCode)
    }
}
