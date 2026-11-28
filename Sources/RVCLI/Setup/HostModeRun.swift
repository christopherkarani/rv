#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVHistory
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
        /// An agent's block of this host: when it ends (ISO 8601).
        var until: String? = nil
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
        /// An agent's block: when it ends (ISO 8601) and the mode then.
        var until: String? = nil
        var then: String? = nil

        enum CodingKeys: String, CodingKey {
            case host, mode, schema, then, until, wiring
        }
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

    /// `only`: show one host (`rv host mode claude`); nil shows every host.
    static func list(
        _ env: SetupEnvironment, json: Bool, only: HookHost? = nil, now: Date = Date(), timeZone: TimeZone = .current
    ) -> SetupOutcome {
        do {
            let installations = try SetupRun.inspectInstallations(layout: OwnedPaths(home: env.home), env: env)
            // An unreadable config shows every host under the global mode,
            // as a host with no entry would.
            let modes: [HookHost: HostMode]
            switch store(env).read() {
            case .entries(let entries): modes = entries
            case .unreadable: modes = [:]
            }
            let config = GuardConfig.read(home: env.home)
            let guardMode = GuardModeResolution.resolve(
                config, host: nil, environment: ProcessInfo.processInfo.environment)
            let shown = HookHost.allCases
                .filter { only == nil || $0 == only }
                .sorted { $0.rawValue < $1.rawValue }
            // An agent's block that is open now shows as `block` with its end.
            let blocks = Dictionary(uniqueKeysWithValues: shown.compactMap { host in
                config.temporaryBlock(for: host, at: now).map { (host, $0) }
            })
            let rows = shown
                .map { host in
                    let block = blocks[host]
                    return Row(
                        host: host.rawValue,
                        mode: block == nil ? effectiveMode(stored: modes[host], guardMode: guardMode).rawValue : HostMode.block.rawValue,
                        wiring: installations.state(for: host).rawValue,
                        until: block.map { ClockText.iso($0.until) }
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
            var lines: [String] = zip(shown, rows).map { host, row in
                let until = blocks[host].map { "  until \(ClockText.hourMinute($0.until, timeZone: timeZone))" } ?? ""
                return "\(row.host)  \(row.mode)  \(row.wiring)\(until)"
            }
            if document.managedEnforce {
                lines.append("organization gate pins enforce: observe and off do not change evaluation")
                // A gate that arrived after a host went off does not re-wire it.
                let unwired = HookHost.allCases
                    .filter { only == nil || $0 == only }
                    .filter { modes[$0] == .off && installations.state(for: $0) != .wired }
                    .map(\.rawValue)
                    .sorted()
                if unwired.isEmpty == false {
                    let names = unwired.joined(separator: ", ")
                    lines.append("off and unwired under the organization gate: \(names); run rv setup to restore")
                }
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
    ///
    /// `block` of a host that is not already enforcing must never lock an
    /// agent out (Q4): at a terminal it asks `authenticate` and is then
    /// permanent; without one it is what `HostTighten.unconfirmedBlock`
    /// says (a block that ends on its own after an hour, or a proposal the
    /// owner types). Ending an agent's open block early is a loosening.
    static func setMode(
        _ mode: HostMode,
        for host: HookHost,
        env: SetupEnvironment,
        json: Bool,
        requester: HostModeRequester = .unattended,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        proposals: any HostModeProposalSink = UnstoredHostModeProposals(),
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
            let stored = store.read()
            // Two questions, each with its own conservative reading of an
            // unreadable config: for "is this a loosening?" the host is
            // `block` (any move away needs the owner); for "is the host
            // leaving `off`?" it is `off`, so the trusted-daemon check runs.
            // The save then refuses the file, so nothing is stored or re-wired.
            let current = stored.mode(for: host, ifUnreadable: .block)
            let wiredFrom = stored.mode(for: host, ifUnreadable: .off)
            let config = store.readGuardConfig()
            let openBlock = config?.temporaryBlock(for: host, at: now)
            var authorization: String?
            if mode == .block {
                // Unreadable reads as enforcing: the save below refuses it.
                let storedMode = config.map {
                    effectiveMode(stored: $0.hosts[host], guardMode: GuardModeResolution.resolveStored($0, host: nil))
                } ?? .block
                if storedMode != .block, requester.atTerminal {
                    do {
                        try await authenticate()
                        authorization = "owner (permanent block)"
                    } catch {
                        throw SetupError.ownerAuthenticationRequired
                    }
                } else {
                    switch HostTighten.unconfirmedBlock(
                        of: host, storedMode: storedMode, lastBlock: config?.temporaryBlocks[host],
                        callingHosts: requester.callingHosts, now: now) {
                    case .permanent:
                        break
                    case .alreadyTemporary(let window):
                        return temporaryOutcome(
                            host: host, window: window, restores: storedMode, env: env, json: json,
                            already: true, timeZone: timeZone)
                    case .temporary(let window):
                        try ConfigChangeAudit.$authorization.withValue(nil) {
                            try store.saveTemporaryBlock(for: host, window: window)
                        }
                        return temporaryOutcome(
                            host: host, window: window, restores: storedMode, env: env, json: json,
                            already: false, timeZone: timeZone)
                    case .proposal(let reason):
                        let proposal = HostModeProposal(host: host, mode: mode, reason: reason)
                        return proposalOutcome(proposal, id: proposals.submit(proposal), json: json)
                    }
                }
            } else if mode.isLooser(than: openBlock == nil ? current : .block) {
                // Only loosening asks the owner; tightening needs no check.
                // An agent's open block counts: ending it early loosens.
                do {
                    try await authenticate()
                    authorization = "owner (loosening check)"
                } catch {
                    throw SetupError.ownerAuthenticationRequired
                }
            }
            // Order keeps every intermediate state no looser than both ends
            // at rvd: going `off`, the hooks come out after the change is
            // recorded and before `off` is stored (an unrecorded `off`
            // detaches nothing, a failed detach stores nothing, so wired
            // hooks never run under `off`, and a retry still needs the
            // owner); leaving `off`, the tighter mode is stored before
            // re-wiring (a failed re-wire leaves the host unwired under that
            // mode, which `rv setup` repairs). An agent's block is removed
            // only after the owner's mode is stored.
            if wiredFrom == .off, mode != .off {
                // Leaving `off` re-wires the host: refuse, as `rv setup`
                // does, before storing anything when the fail-closed hook
                // would reject the installed rvd and deny every tool call.
                try SetupRun.requireTrustedDaemon(env)
            }
            // The owner's permanent block replaces the agent's record; the
            // owner ending an open one early keeps it, ended now, so the
            // cooldown counts from here. An ended record is left alone.
            let clearsAgentBlock = authorization != nil && mode == .block && config?.temporaryBlocks[host] != nil
            let endsAgentBlock = authorization != nil && mode != .block ? openBlock : nil
            do {
                try await ConfigChangeAudit.$authorization.withValue(authorization) {
                    try store.save(mode, for: host) {
                        if mode == .off { try applyWiring(from: wiredFrom, to: mode, host: host, env: env) }
                    }
                    if clearsAgentBlock {
                        try store.clearTemporaryBlock(for: host, direction: .tightening)
                    }
                    if let endsAgentBlock {
                        try store.endTemporaryBlock(for: host, window: endsAgentBlock, at: now)
                    }
                }
            } catch let error as SetupError {
                return failure(error, command: .hostMode)
            } catch OwnerConfigWriteError.unreadable {
                return SetupOutcome(
                    stdout: "", stderr: ConfigUnreadableRefusal.message(prefix: "rv host mode failed"),
                    exitCode: ConfigUnreadableRefusal.exitCode)
            } catch let unrecorded as ConfigChangeUnrecorded {
                return SetupOutcome(
                    stdout: "", stderr: ConfigChangeRefusal.message(command: "host mode", unrecorded),
                    exitCode: ConfigChangeRefusal.exitCode)
            } catch {
                return SetupOutcome(
                    stdout: "", stderr: "rv host mode failed: unable to write config.json\n",
                    exitCode: EX_CANTCREAT)
            }
            if mode != .off {
                try applyWiring(from: wiredFrom, to: mode, host: host, env: env)
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
        } catch OwnerConfigWriteError.unreadable {
            return SetupOutcome(
                stdout: "", stderr: ConfigUnreadableRefusal.message(prefix: "rv host mode failed"),
                exitCode: ConfigUnreadableRefusal.exitCode)
        } catch let unrecorded as ConfigChangeUnrecorded {
            return SetupOutcome(
                stdout: "", stderr: ConfigChangeRefusal.message(command: "host mode", unrecorded),
                exitCode: ConfigChangeRefusal.exitCode)
        } catch {
            return SetupOutcome(stdout: "", stderr: "rv host mode failed: \(error)\n", exitCode: EX_SOFTWARE)
        }
    }

    /// An agent's block that ends on its own: the row, when it ends and
    /// what comes back, and the command that keeps it, last.
    private static func temporaryOutcome(
        host: HookHost, window: GuardWindow, restores: HostMode, env: SetupEnvironment, json: Bool,
        already: Bool, timeZone: TimeZone
    ) -> SetupOutcome {
        let wiring = (try? SetupRun.inspectInstallations(layout: OwnedPaths(home: env.home), env: env))?
            .state(for: host).rawValue ?? "unknown"
        let keep = "\(CommandVocabulary.Command.host.invocation) mode \(host.rawValue) block"
        if json {
            let document = ModeDocument(
                host: host.rawValue, mode: HostMode.block.rawValue, wiring: wiring,
                until: ClockText.iso(window.until), then: restores.rawValue)
            return SetupOutcome(stdout: (try? RobotJSON.encode(document)).map { $0 + "\n" } ?? "", exitCode: 0)
        }
        let until = ClockText.hourMinute(window.until, timeZone: timeZone)
        let why = already
            ? "  An agent already blocked \(host.rawValue); it ends on its own at \(until)."
            : "  An agent's block ends on its own after an hour; then \(host.rawValue) is back to \(restores.rawValue)."
        return SetupOutcome(
            stdout: [
                "\(host.rawValue)  block  \(wiring)  until \(until)",
                why,
                "  To keep it blocked, you type:",
                "\(CommandVocabulary.Glyph.next.rawValue) \(keep)",
            ].joined(separator: "\n") + "\n",
            exitCode: 0)
    }

    struct ProposalDocument: Encodable, Equatable {
        let host: String
        let id: String?
        let mode: String
        let proposed = true
        let reason: String
        let schema = "rv.host-mode-proposal.v1"
    }

    /// Nothing changed: what was asked, why it waits, and the command the
    /// owner types, last. Exits `EX_NOPERM`, so `&&` after it does not run
    /// as if the host were blocked.
    private static func proposalOutcome(_ proposal: HostModeProposal, id: String?, json: Bool) -> SetupOutcome {
        let host = proposal.host.rawValue
        if json {
            let document = ProposalDocument(
                host: host, id: id, mode: proposal.mode.rawValue, reason: proposal.reason.rawValue)
            return SetupOutcome(stdout: (try? RobotJSON.encode(document)).map { $0 + "\n" } ?? "", exitCode: EX_NOPERM)
        }
        let why = switch proposal.reason {
        case .ownHost: "Blocking \(host) would stop the agent that asked, so nothing changed."
        case .unknownCaller: "rv can't tell which agent asked, and blocking \(host) could stop it, so nothing changed."
        case .hostOff: "\(host) is off; an agent can't wire it back in as block, so nothing changed."
        case .cooldown: "An agent's block of \(host) ended less than 6 hours ago; another waits for you, so nothing changed."
        }
        let command = "\(CommandVocabulary.Command.host.invocation) mode \(host) \(proposal.mode.rawValue)"
        return SetupOutcome(
            stdout: [
                "\(CommandVocabulary.Glyph.ask.rawValue) asks  \(proposal.mode.rawValue) \(host): you decide",
                "  \(why)",
                "  To do it, you type:",
                "\(CommandVocabulary.Glyph.next.rawValue) \(command)",
            ].joined(separator: "\n") + "\n",
            exitCode: EX_NOPERM)
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
            .skipUndetected, .skipOccupied, .skipOff, .skipRuntimeMissing:
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
