#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVPolicy
import RVPresentation
import RVService
#if os(macOS)
import RVIsolation
#endif

/// Where the LaunchAgent is registered, as `launchctl print` sees it.
struct LaunchdObservation: Equatable, Sendable {
    var guiDomainExists: Bool
    var loadedInGui: Bool
    var loadedInUser: Bool
}

/// State of the admin peer-trust manifest hooks consult first.
enum TrustManifestState: Equatable, Sendable {
    case absent
    case valid
    /// Present but rejected: hooks and doctor fail closed.
    case invalid
    case notApplicable
}

/// Linux: the environment rvd resolves its socket base from
/// (`UnixSocketPath.serverSocket`).
struct SocketBaseEnvironment: Equatable, Sendable {
    /// `XDG_RUNTIME_DIR` as doctor sees it; nil when unset.
    var xdgRuntimeDir: String?
    /// Parent of the uid-derived base used when `XDG_RUNTIME_DIR` is unset.
    var userRuntimeRoot: String = UnixSocketPath.userRuntimeRoot
}

/// Install facts doctor cannot read from `rvd` itself.
struct DoctorInstallProbes {
    var userID: uid_t
    var launchd: LaunchdObservation?
    var trustManifest: TrustManifestState
    /// Would hooks trust the installed `rvd`? Nil when not evaluated.
    var daemonTrust: DoctorServiceTrust? = nil
    /// Verdicts for the other manifest roles whose binaries are installed
    /// (`RoleTrustProbe`). Empty with no manifest or when not evaluated.
    var roleTrust: [DoctorRoleTrust] = []
    /// Which workspace peer-trust roles exist at all (`RoleTrustProbe`).
    var workspaceRoles: WorkspaceTrustRoles = .notEvaluated
    /// Does a hook interpreter run: the absolute path a hook command bakes,
    /// or `python3` on PATH for an earlier rv's command? Asked only for an
    /// interpreter some hooked host needs. Default true (tests).
    var interpreterRunnable: (String) -> Bool = { _ in true }
    /// Can this user replace a baked interpreter (its file or a directory
    /// above it, through symlinks, or the real interpreter and standard
    /// library it runs)? Default false (tests).
    var interpreterReplaceable: (String) -> Bool = { _ in false }
    /// Hook commands must start through `/usr/bin/env` (macOS;
    /// `AdapterCommand`). A test seam for the other platform's rule.
    var launchesThroughEnv: Bool = AdapterCommand.launchesThroughEnv
    /// Linux: does a systemd user manager answer `systemctl --user`? Nil
    /// off Linux or when not evaluated (tests).
    var systemdUserManagerReachable: Bool? = nil
    /// Linux: what picks rvd's socket base directory. Nil off Linux or
    /// when not evaluated (tests).
    var socketBase: SocketBaseEnvironment? = nil
    /// macOS: is `dev.rv.judge` loaded in either domain? Nil when launchd
    /// was not observed (Linux, tests).
    var judgeLoaded: Bool? = nil
    /// macOS: is `dev.rv.judge` loaded in both gui and user domains?
    var judgeLoadedInBothDomains: Bool = false
    /// Does a valid judge bundle sit where rvd looks? Default false (tests).
    var judgeBundleInstalled: Bool = false
    /// The roles an installed manifest names; nil without a valid manifest
    /// (sibling pin, invalid, Linux, tests).
    var manifestRoles: Set<String>? = nil

    static func live(
        home: HomeDirectory,
        pathEntries: [String] = [],
        xdgRuntimeDir: String?,
        userID: uid_t = getuid(),
        launchctl: any LaunchctlApplying = ProcessLaunchctl()
    ) -> DoctorInstallProbes {
#if os(macOS)
        var probes = DoctorInstallProbes(
            userID: userID,
            launchd: LaunchAgentProbe.observe(
                label: SetupRun.launchAgentLabel,
                userID: userID,
                launchctl: launchctl
            ),
            trustManifest: liveTrustManifest(),
            daemonTrust: DaemonTrustProbe.live(OwnedPaths(home: home).localRvd),
            roleTrust: RoleTrustProbe.live(OwnedPaths(home: home)),
            workspaceRoles: RoleTrustProbe.workspaceRoles(
                OwnedPaths(home: home), source: ProtectedPeerTrustConfiguration.hookTrustSource()
            )
        )
        let judge = LaunchAgentProbe.observe(
            label: SetupRun.judgeLaunchAgentLabel, userID: userID, launchctl: launchctl)
        probes.judgeLoaded = judge.loadedInGui || judge.loadedInUser
        probes.judgeLoadedInBothDomains = judge.loadedInGui && judge.loadedInUser
        probes.judgeBundleInstalled = JudgeRuntime.selectsBundle(home: home)
        probes.manifestRoles = ProtectedPeerTrustConfiguration.hookTrustSource().manifestRoles.map {
            Set($0.map(\.rawValue))
        }
#else
        var probes = DoctorInstallProbes(userID: userID, launchd: nil, trustManifest: .notApplicable)
        probes.systemdUserManagerReachable = ProcessSystemctl().userManagerReachable()
        probes.socketBase = SocketBaseEnvironment(xdgRuntimeDir: xdgRuntimeDir)
#endif
        probes.interpreterRunnable = { AdapterRuntime.liveRunnable($0, pathEntries: pathEntries) }
        probes.interpreterReplaceable = { AdapterRuntime.isReplaceableInterpreter($0) }
        return probes
    }

#if os(macOS)
    private static func liveTrustManifest() -> TrustManifestState {
        switch ProtectedPeerTrustConfiguration.hookTrustSource() {
        case .manifest:
            .valid
        case .siblingPin:
            .absent
        case .invalid:
            .invalid
        }
    }
#endif
}

/// Static trust check of the installed `rvd` with the rule hooks apply to
/// the live daemon (`DaemonTrustVerdict`). Doctor and setup share it.
enum DaemonTrustProbe {
    /// Production evaluator; nil off macOS (Linux hooks trust a same-user socket).
    static func live(_ rvdPath: String) -> DoctorServiceTrust? {
#if os(macOS)
        evaluate(rvdPath: rvdPath, source: ProtectedPeerTrustConfiguration.hookTrustSource())
#else
        nil
#endif
    }

#if os(macOS)
    /// Nil when no rvd is installed: `rvd-missing` already covers that.
    static func evaluate(
        rvdPath: String,
        source: ProtectedPeerTrustConfiguration.HookTrustSource
    ) -> DoctorServiceTrust? {
        guard FileManager.default.fileExists(atPath: rvdPath) else { return nil }
        let verdict = source.evaluateDaemon(atPath: rvdPath)
        return DoctorServiceTrust(
            source: verdict.source.rawValue, satisfied: verdict.satisfied, reason: verdict.reason
        )
    }
#endif

    /// Repair for an rvd the hooks would reject.
    static func fix(_ trust: DoctorServiceTrust) -> String {
        switch trust.source {
        case "manifest":
            "sign the build (RV_RELEASE_SIGN=1 Scripts/release.sh) and reinstall it, "
                + "or remove the admin trust manifest: sudo rm '\(DoctorInstallChecks.trustManifestPath)'"
        case "invalid":
            "sudo rm '\(DoctorInstallChecks.trustManifestPath)' (or reinstall a valid manifest)"
        default:
            SetupRun.reinstallHint
        }
    }
}

/// Whether the manifest grants the roles `rv workspace` needs: the host
/// must hold workspaceHost and this rv must hold cli, and only a manifest
/// grants either.
enum WorkspaceTrustRoles: Equatable, Sendable {
    /// No workspace host installed, an invalid manifest (its own row), or tests.
    case notEvaluated
    case noManifest
    /// The role names the installed manifest has entries for.
    case manifest(Set<String>)
}

/// One manifest role's verdict on its installed binary.
struct DoctorRoleTrust: Equatable, Sendable {
    /// The manifest role name (`workspaceHost`, `cli`, `mcpCustodian`).
    var role: String
    var path: String
    var trust: DoctorServiceTrust
}

/// Static trust check of the other installed rv components against their
/// manifest entries, with the rule their peers apply live. `service` is
/// `DaemonTrustProbe`; the operator UI has no install location to check.
enum RoleTrustProbe {
    static func live(_ paths: OwnedPaths) -> [DoctorRoleTrust] {
#if os(macOS)
        let source = ProtectedPeerTrustConfiguration.hookTrustSource()
        return evaluate(binaries: binaries(paths)) { role, path in source.evaluateRole(role, atPath: path) }
#else
        []
#endif
    }

#if os(macOS)
    /// What the manifest grants `rv workspace`, judged only when the
    /// workspace host is installed.
    static func workspaceRoles(
        _ paths: OwnedPaths,
        source: ProtectedPeerTrustConfiguration.HookTrustSource
    ) -> WorkspaceTrustRoles {
        guard FileManager.default.fileExists(atPath: paths.localWorkspaceHost) else { return .notEvaluated }
        switch source {
        case .manifest:
            return .manifest(Set((source.manifestRoles ?? []).map(\.rawValue)))
        case .siblingPin:
            return .noManifest
        case .invalid:
            return .notEvaluated
        }
    }

    /// Each role and the binary rv installs for it.
    static func binaries(_ paths: OwnedPaths) -> [(role: TrustedRVComponentRole, path: String)] {
        [
            (.cli, paths.localRvCli),
            (.workspaceHost, paths.localWorkspaceHost),
            (.mcpCustodian, paths.custodianAppExecutable),
            (.judge, SetupRun.judgeExecutable(rvdPath: paths.localRvd)),
        ]
    }

    /// Installed binaries only; a role the manifest does not name gives no verdict.
    static func evaluate(
        binaries: [(role: TrustedRVComponentRole, path: String)],
        verdict: (TrustedRVComponentRole, String) -> DaemonTrustVerdict?
    ) -> [DoctorRoleTrust] {
        binaries.compactMap { role, path in
            guard FileManager.default.fileExists(atPath: path), let found = verdict(role, path) else { return nil }
            return DoctorRoleTrust(
                role: role.rawValue,
                path: path,
                trust: DoctorServiceTrust(source: found.source.rawValue, satisfied: found.satisfied, reason: found.reason)
            )
        }
    }
#endif
}

/// Install/runtime problems that make hooks deny even though rv "looks"
/// installed. Each carries the exact repair command.
enum DoctorInstallChecks {
    /// Swift Build (the SwiftPM default since 6.4) names the bundle
    /// `.bundle` on every platform; the legacy native build system still
    /// emits `.resources` on Linux. Mirrors `PackRegistry`'s lookup.
    static let packBundleName = "rv_RVPacks.bundle"
#if canImport(Darwin)
    static let packBundleNames = [packBundleName]
#else
    static let packBundleNames = [packBundleName, "rv_RVPacks.resources"]
#endif
    static let trustManifestPath = "/Library/Application Support/RV/peer-trust.json"

    static func problems(
        paths: OwnedPaths,
        fileManager: FileManager,
        probes: DoctorInstallProbes
    ) -> [DoctorProblem] {
        [
            trustManifest(probes.trustManifest),
            daemonTrust(probes.daemonTrust),
            installedBinaries(paths: paths, fileManager: fileManager),
            launchAgentProgram(paths: paths, fileManager: fileManager),
            launchAgentOnDemand(paths: paths, fileManager: fileManager),
            launchdDomain(probes.launchd, paths: paths, userID: probes.userID),
            launchdDuplicate(probes.launchd, paths: paths, userID: probes.userID),
            socketBaseDirectory(paths: paths, probes: probes),
            workspaceRoles(probes.workspaceRoles),
            startupBackoff(paths: paths),
        ].compactMap { $0 } + roleTrust(probes.roleTrust)
    }

    /// rvd's own crash-loop record says it is (or was just) holding off: a
    /// down rvd may be waiting out its backoff, not gone.
    static func startupBackoff(paths: OwnedPaths) -> DoctorProblem? {
        let store = StartupBackoffStore.live(home: paths.home.rawValue)
        guard let record = store.load(), record.running else { return nil }
        let plan = StartupBackoff.plan(previous: StartupBackoff.Record(earlyExits: max(record.earlyExits, 1) - 1, running: true))
        guard plan.delay > .zero else { return nil }
        return DoctorProblem(
            id: "rvd-startup-backoff",
            severity: .warn,
            summary: "rvd stopped within \(StartupBackoff.survivalWindow.components.seconds) s of starting "
                + "\(record.earlyExits) times in a row, so it waits up to "
                + "\(plan.delay.components.seconds) s before it serves; "
                + "\(RVDLogFile.path(home: paths.home.rawValue)) says why",
            fix: "fix the cause, then \(DoctorRun.restartCommand) (it skips the wait)"
        )
    }

    /// One failing row per hooked host whose hook interpreter does not run:
    /// that hook exits 127 and the host lets the tool call through. The
    /// interpreter is the one the host's hook commands bake; an earlier
    /// rv's `python3` command (or one doctor cannot read) is probed on PATH.
    static func adapterRuntime(
        hosts: HostAdapterInstallationSnapshot,
        paths: OwnedPaths,
        fileManager: FileManager,
        probes: DoctorInstallProbes
    ) -> [DoctorProblem] {
        var runnable: [String: Bool] = [:]
        return AdapterRuntime.hooked(hosts).compactMap { host in
            guard let name = AdapterRuntime.interpreter(for: host) else { return nil }
            let baked = AdapterRuntime.bakedInterpreters(host: host, paths: paths, fileManager: fileManager)
            let missing = (baked.isEmpty ? [name] : baked.map(\.path)).first { interpreter in
                if runnable[interpreter] == nil {
                    runnable[interpreter] = probes.interpreterRunnable(interpreter)
                }
                return runnable[interpreter] == false
            }
            guard let interpreter = missing else {
                // The same check setup applies: the baked path, the real
                // interpreter behind it and its standard library.
                if let replaceable = baked.map(\.path).first(where: {
                    $0.hasPrefix("/") && probes.interpreterReplaceable($0)
                }) {
                    return DoctorProblem(
                        id: "adapter-runtime-replaceable-\(host.rawValue)",
                        severity: .warn,
                        summary: "\(host.rawValue) hook runs \(replaceable), which this user can replace "
                            + "(it, the interpreter it launches, or that interpreter's standard library), "
                            + "so an agent could swap the interpreter to skip the guard",
                        fix: replaceableFix(replaceable, name: name, userID: probes.userID)
                    )
                }
                guard let exposed = baked.first(where: {
                    AdapterRuntime.dyldExposed($0, launchesThroughEnv: probes.launchesThroughEnv)
                }) else { return nil }
                return DoctorProblem(
                    id: "adapter-runtime-dyld-\(host.rawValue)",
                    severity: .warn,
                    summary: "\(host.rawValue) hook starts \(exposed.path) without \(AdapterCommand.envLauncher); "
                        + "it is not a SIP-protected binary, so DYLD_* variables in the agent's environment "
                        + "could load a library into the guard",
                    fix: "rerun rv setup"
                )
            }
            return DoctorProblem(
                id: "adapter-runtime-\(host.rawValue)",
                severity: .fail,
                summary: "\(host.rawValue) hook runs \(interpreter), which is not runnable; "
                    + "\(host.rawValue) treats the failed hook as non-blocking, so its tool calls run unguarded",
                fix: "\(AdapterRuntime.installHint(name)), then rv setup"
            )
        }
    }

    /// Linux without a systemd user manager (WSL without systemd, a
    /// container, OpenRC/runit, a login without logind): nothing
    /// supervises rvd, so `rv setup` / `rv service start` run it directly
    /// and it does not survive logout or reboot. Not reported before setup
    /// ran (the service row already says to run it).
    static func systemdUserManager(
        _ reachable: Bool?,
        health: ServiceHealth,
        paths: OwnedPaths
    ) -> DoctorProblem? {
        guard reachable == false else { return nil }
        let start = "\(ShellWord.quote(paths.localRv)) service start"
        let supervised = "or have your process supervisor run \(DirectRvd.command(rvdPath: paths.localRvd))"
        switch health {
        case .notInstalled:
            return nil
        case .reachable:
            return DoctorProblem(
                id: "systemd-user-manager",
                severity: .warn,
                summary: "no systemd user manager is running, so rvd runs without a supervisor "
                    + "and will not survive logout or reboot",
                fix: "add \"\(start) >/dev/null\" to your shell profile (e.g. ~/.profile), \(supervised)"
            )
        case .down, .skew, .requestFailed:
            return DoctorProblem(
                id: "systemd-user-manager",
                severity: .fail,
                summary: "rvd is not running and no systemd user manager is running to start it "
                    + "(systemctl --user cannot reach one)",
                fix: "\(start) (rvd then runs until logout or reboot; add that line to your shell profile, "
                    + "\(supervised))"
            )
        }
    }

    /// Linux directories whose interpreter setup bakes when protected.
    static let linuxSystemInterpreterDirectories = ["/usr/bin/", "/bin/"]

    #if os(macOS)
    static let onMacOS = true
    #else
    static let onMacOS = false
    #endif

    /// Says what setup would bake instead. Root can replace every
    /// interpreter, so the cure there is a non-root account. On macOS setup
    /// bakes the Command Line Tools' Python (a Homebrew or Xcode.app one is
    /// user-owned, and `/usr/bin/python3` only launches one of those). On
    /// Linux a writable `/usr/bin` interpreter is a permissions problem.
    static func replaceableFix(
        _ interpreter: String,
        name: String,
        userID: uid_t,
        macOS: Bool = onMacOS,
        commandLineToolsInstalled: Bool? = nil
    ) -> String {
        if userID == 0 {
            return "run your agents as a regular user, not root: root can replace every \(name), "
                + "system ones included, so no interpreter path is out of an agent's reach"
        }
        if macOS {
            let tools = "\(AdapterRuntime.commandLineToolsDirectory)/\(name)"
            let installed = commandLineToolsInstalled ?? FileManager.default.isExecutableFile(atPath: tools)
            let bakes = "it bakes the Command Line Tools' \(name) (\(tools)), which this user cannot replace"
            return installed
                ? "rerun rv setup: \(bakes)"
                : "install the Command Line Tools (xcode-select --install) and rerun rv setup: \(bakes)"
        }
        guard linuxSystemInterpreterDirectories.contains(where: { interpreter.hasPrefix($0) }) else {
            return "install \(name) with your package manager (e.g. apt install python3) and rerun rv setup: "
                + "it bakes /usr/bin/\(name) when this user cannot replace it"
        }
        return "make \(interpreter), its standard library and the directories above them writable only by root "
            + "(e.g. sudo chown root \(interpreter) && sudo chmod go-w \(interpreter))"
    }

    private static func setupFix(_ paths: OwnedPaths) -> String {
        "run \(paths.localRv) setup"
    }

    static func trustManifest(_ state: TrustManifestState) -> DoctorProblem? {
        guard state == .invalid else { return nil }
        return DoctorProblem(
            id: "trust-manifest",
            severity: .fail,
            summary: "\(trustManifestPath) is present but rejected (must be a valid, root-owned manifest); "
                + "hooks fail closed",
            fix: "sudo rm '\(trustManifestPath)' (or reinstall a valid manifest)"
        )
    }

    /// The installed rvd fails the trust rule hooks apply, so every hook
    /// call is denied however healthy the service looks. An invalid
    /// manifest already has its own row.
    static func daemonTrust(_ trust: DoctorServiceTrust?) -> DoctorProblem? {
        guard let trust, trust.satisfied == false, trust.source != "invalid" else { return nil }
        return DoctorProblem(
            id: "daemon-trust",
            severity: .fail,
            summary: "hooks reject the installed rvd (\(trust.reason ?? "untrusted")); hooks deny every tool call",
            fix: DaemonTrustProbe.fix(trust)
        )
    }

    /// The roles `rv workspace` needs and nothing grants: without a
    /// manifest, or without its workspaceHost or cli entry, every start is
    /// refused. Hooks keep working, so a warning.
    static func workspaceRoles(_ state: WorkspaceTrustRoles) -> DoctorProblem? {
        let required = ["workspaceHost", "cli"]
        let administrator = "the file is root-owned, so this needs an administrator (sudo)"
        switch state {
        case .notEvaluated:
            return nil
        case .noManifest:
            return DoctorProblem(
                id: "peer-trust-workspace-roles-missing",
                severity: .warn,
                summary: "no peer-trust manifest is installed at \(trustManifestPath), and only it grants the "
                    + "workspace host and rv-cli roles; rv workspace and rv opencode will not start",
                fix: "install '\(trustManifestPath)' with workspaceHost and cli entries for the installed builds; "
                    + administrator
            )
        case .manifest(let roles):
            let missing = required.filter { roles.contains($0) == false }
            guard missing.isEmpty == false else { return nil }
            let names = missing.joined(separator: " or ")
            return DoctorProblem(
                id: "peer-trust-workspace-roles-missing",
                severity: .warn,
                summary: "the peer-trust manifest at \(trustManifestPath) has no \(names) entry; "
                    + "rv workspace and rv opencode will not start",
                fix: "add \(missing.joined(separator: " and ")) entries for the installed builds to "
                    + "'\(trustManifestPath)'; " + administrator
            )
        }
    }

    /// A manifest role whose installed binary fails its entry: that
    /// component's peers refuse it. Hooks keep working, so a warning.
    static func roleTrust(_ verdicts: [DoctorRoleTrust]) -> [DoctorProblem] {
        verdicts.compactMap { verdict in
            guard verdict.trust.satisfied == false else { return nil }
            let reason = verdict.trust.reason.map { " (\($0))" } ?? ""
            return DoctorProblem(
                id: "peer-trust-role-unsatisfied-\(verdict.role)",
                severity: .warn,
                summary: roleImpact(verdict.role) + reason,
                fix: "update the \(verdict.role) entry in '\(trustManifestPath)' to pin the installed build "
                    + "(for a release build, a Developer ID entry with its identifier and team); "
                    + "the file is root-owned, so updating it needs an administrator (sudo)"
            )
        }
    }

    private static func roleImpact(_ role: String) -> String {
        switch role {
        case "workspaceHost":
            "the peer-trust manifest pins the workspace host to a different build; "
                + "rv workspace and rv opencode will not start"
        case "cli":
            "the peer-trust manifest pins rv-cli to a different build; "
                + "the workspace host and the approvals custodian refuse this rv"
        case "mcpCustodian":
            "the peer-trust manifest pins the approvals custodian to a different build; "
                + "MCP approvals will fail"
        case "judge":
            "the peer-trust manifest pins rv-judge to a different build; "
                + "rvd refuses the judge pool, so judged calls go to review"
        default:
            "the peer-trust manifest pins \(role) to a different build"
        }
    }

    /// `rvd` beside the hook `rv`, and the pack bundle `rvd` loads beside it.
    static func installedBinaries(paths: OwnedPaths, fileManager: FileManager) -> DoctorProblem? {
        guard fileManager.isExecutableFile(atPath: paths.localRvd) else {
            return DoctorProblem(
                id: "rvd-missing",
                severity: .fail,
                summary: "rvd not found at \(paths.localRvd); hooks have no daemon to ask",
                fix: SetupRun.reinstallHint
            )
        }
        let binDirectory = (paths.localRvd as NSString).deletingLastPathComponent
        let present = packBundleNames.contains { name in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: binDirectory + "/" + name, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        guard present else {
            return DoctorProblem(
                id: "pack-bundle",
                severity: .fail,
                summary: "\(packBundleName) missing next to \(paths.localRvd); rvd cannot load its packs",
                fix: SetupRun.reinstallHint
            )
        }
        return nil
    }

    /// The plist must launch the `rvd` hooks pin (`~/.local/bin/rvd`).
    static func launchAgentProgram(paths: OwnedPaths, fileManager: FileManager) -> DoctorProblem? {
        guard fileManager.fileExists(atPath: paths.launchAgent) else { return nil }
        guard let program = launchAgentProgram(at: paths.launchAgent) else {
            return DoctorProblem(
                id: "launch-agent-rvd",
                severity: .fail,
                summary: "LaunchAgent \(paths.launchAgent) is unreadable or names no program",
                fix: setupFix(paths)
            )
        }
        let expected = (paths.localRvd as NSString).standardizingPath
        guard (program as NSString).standardizingPath != expected else { return nil }
        return DoctorProblem(
            id: "launch-agent-rvd",
            severity: .fail,
            summary: "LaunchAgent runs \(program), but hooks only trust \(paths.localRvd)",
            fix: setupFix(paths)
        )
    }

    static func launchAgentProgram(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any]
        else { return nil }
        if let arguments = dictionary["ProgramArguments"] as? [String], let first = arguments.first {
            return first
        }
        return dictionary["Program"] as? String
    }

    /// The installed plist, not the template rvd was built with: one an
    /// earlier rv wrote runs rvd on demand, so a crash leaves it down until
    /// the next hook call. `rv setup` rewrites it. KeepAlive is checked
    /// against the plist's own program; a wrong program is its own row.
    static func launchAgentOnDemand(paths: OwnedPaths, fileManager: FileManager) -> DoctorProblem? {
        guard fileManager.fileExists(atPath: paths.launchAgent),
            let program = launchAgentProgram(at: paths.launchAgent),
            launchAgentKeepsRvdUp(at: paths.launchAgent, rvdPath: program) == false
        else { return nil }
        return DoctorProblem(
            id: "launch-agent-on-demand",
            severity: .warn,
            summary: "LaunchAgent \(paths.launchAgent) is not RunAtLoad + KeepAlive: "
                + "after a crash rvd stays down until the next hook call",
            fix: setupFix(paths)
        )
    }

    /// RunAtLoad true and KeepAlive true, or KeepAlive while `rvdPath`
    /// exists (what setup writes).
    static func launchAgentKeepsRvdUp(at path: String, rvdPath: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            plist["RunAtLoad"] as? Bool == true
        else { return false }
        if plist["KeepAlive"] as? Bool == true { return true }
        guard let conditions = plist["KeepAlive"] as? [String: Any],
            let pathState = conditions["PathState"] as? [String: Bool]
        else { return false }
        return conditions.count == 1 && pathState == [rvdPath: true]
    }

    /// Loaded in both domains: two always-on rvds race for the socket.
    static func launchdDuplicate(
        _ observation: LaunchdObservation?,
        paths: OwnedPaths,
        userID: uid_t
    ) -> DoctorProblem? {
        guard let observation, observation.loadedInGui, observation.loadedInUser else { return nil }
        return DoctorProblem(
            id: "launchd-domain-duplicate",
            severity: .warn,
            summary: "\(SetupRun.launchAgentLabel) is loaded in both \(LaunchdDomain.gui(userID)) and "
                + "\(LaunchdDomain.user(userID)), so launchd keeps two rvds running",
            fix: setupFix(paths)
        )
    }

    /// A job only in `user/<uid>` is invisible to hosts in the Aqua session.
    static func launchdDomain(
        _ observation: LaunchdObservation?,
        paths: OwnedPaths,
        userID: uid_t
    ) -> DoctorProblem? {
        guard let observation,
            observation.guiDomainExists,
            observation.loadedInUser,
            observation.loadedInGui == false
        else { return nil }
        return DoctorProblem(
            id: "launchd-domain",
            severity: .fail,
            summary: "\(SetupRun.launchAgentLabel) is loaded in \(LaunchdDomain.user(userID)), "
                + "which desktop agents cannot reach (\(LaunchdDomain.gui(userID)) exists)",
            fix: setupFix(paths)
        )
    }

    /// The directory rvd's socket sits under: `~/.config` on macOS, the
    /// runtime directory on Linux (`UnixSocketPath.production`).
    static func socketBaseDirectory(paths: OwnedPaths, probes: DoctorInstallProbes) -> DoctorProblem? {
#if os(Linux)
        runtimeDirectory(probes.socketBase, userID: probes.userID)
#else
        configDirectory(paths: paths, userID: probes.userID)
#endif
    }

    /// Mirrors rvd's socket base-directory rule on macOS: `~/.config` must be
    /// a directory owned by this user and not group/world-writable.
    static func configDirectory(paths: OwnedPaths, userID: uid_t) -> DoctorProblem? {
        let config = paths.home.rawValue + "/.config"
        var info = stat()
        guard stat(config, &info) == 0 else { return nil }
        if (info.st_mode & S_IFMT) != S_IFDIR {
            return DoctorProblem(
                id: "config-dir",
                severity: .fail,
                summary: "\(config) is not a directory; rvd cannot create its socket",
                fix: "mv '\(config)' '\(config).bak' && mkdir -m 700 '\(config)'"
            )
        }
        if info.st_uid != userID {
            return DoctorProblem(
                id: "config-dir",
                severity: .fail,
                summary: "\(config) is owned by uid \(info.st_uid), not uid \(userID); rvd refuses to start",
                fix: "sudo chown \(userID) '\(config)'"
            )
        }
        let mode = Int(info.st_mode) & 0o777
        if mode & 0o022 != 0 {
            return DoctorProblem(
                id: "config-dir",
                severity: .fail,
                summary: "\(config) is group/world-writable (mode \(String(mode, radix: 8))); rvd refuses to start",
                fix: "chmod go-w '\(config)'"
            )
        }
        return nil
    }

    /// Linux: mirrors what `UnixSocketPath.prepareRuntime` refuses, without
    /// its side effects. The base is `$XDG_RUNTIME_DIR`, or `/run/user/<uid>`
    /// when it is unset. rvd refuses an empty `XDG_RUNTIME_DIR`, a socket
    /// path too long for `sockaddr_un`, a base that is not a directory (a
    /// symlink included: rvd judges the link itself), one owned by another
    /// uid or writable by group or others, and a missing uid-derived base
    /// it cannot create (`uncreatableUserRuntimeDirectory`). A missing base
    /// elsewhere is not reported: rvd tries to create it with its parents,
    /// and doctor does not predict whether that works; one that cannot be
    /// looked up at all (`ENOTDIR`, `EACCES`) is. The rows judge the
    /// `XDG_RUNTIME_DIR` this shell sees (the directory it and its agents
    /// dial); an rvd started by the systemd user manager uses
    /// `/run/user/<uid>` instead.
    static func runtimeDirectory(_ environment: SocketBaseEnvironment?, userID: uid_t) -> DoctorProblem? {
        guard let environment else { return nil }
        let ownerRuntime = "\(environment.userRuntimeRoot)/\(userID)"
        let setRuntimeDirectory = "set XDG_RUNTIME_DIR to a directory only you can access, for rvd and for your agents"
        let socket: URL
        do {
            socket = try UnixSocketPath.resolve(xdgRuntimeDir: environment.xdgRuntimeDir ?? ownerRuntime)
        } catch UnixSocketPathError.runtimeDirectoryMissing {
            return DoctorProblem(
                id: "runtime-dir",
                severity: .fail,
                summary: "XDG_RUNTIME_DIR is set but empty; rvd refuses it, "
                    + "and this shell and its agents cannot dial rvd",
                fix: "unset it (rvd then uses \(ownerRuntime)) or set it to a directory only you can access"
            )
        } catch {
            return DoctorProblem(
                id: "runtime-dir",
                severity: .fail,
                summary: "rvd's socket path under \(environment.xdgRuntimeDir ?? ownerRuntime) is too long "
                    + "for a Unix socket; rvd refuses it, and this shell and its agents cannot dial rvd",
                fix: "\(setRuntimeDirectory), with a shorter path, or unset it (rvd then uses \(ownerRuntime))"
            )
        }
        let base = socket.deletingLastPathComponent().deletingLastPathComponent().path
        var info = stat()
        guard lstat(base, &info) == 0 else {
            let lookupError = errno
            if base == ownerRuntime {
                // rvd makes `<root>/<uid>` itself when it can; report only
                // the case it cannot, with rvd's own fix.
                guard let missing = UnixSocketPath.uncreatableUserRuntimeDirectory(
                    xdgRuntimeDir: nil, uid: userID, userRuntimeRoot: environment.userRuntimeRoot
                ) else { return nil }
                return DoctorProblem(
                    id: "runtime-dir",
                    severity: .fail,
                    summary: "\(missing) is missing and only root can create it; rvd refuses to start",
                    fix: UnixSocketPath.userRuntimeDirectoryFix(directory: missing, uid: userID)
                )
            }
            // rvd creates a missing base elsewhere with its parents; one
            // that cannot even be looked up (an ancestor is a file, or not
            // searchable) it cannot create either.
            guard lookupError != ENOENT else { return nil }
            return DoctorProblem(
                id: "runtime-dir",
                severity: .fail,
                summary: "\(base) cannot be looked up (\(String(cString: strerror(lookupError)))); "
                    + "rvd cannot create its socket there, and this shell and its agents dial it",
                fix: "\(setRuntimeDirectory), or unset it (rvd then uses \(ownerRuntime))"
            )
        }
        return existingRuntimeDirectory(
            base, info: info, userID: userID,
            // Only this user's own uid-derived directory is repaired in
            // place; anything else (`/tmp`, another user's runtime
            // directory under `sudo -E`) is left alone.
            elsewhere: base == ownerRuntime
                ? nil : "\(setRuntimeDirectory), or unset it (rvd then uses \(ownerRuntime))"
        )
    }

    /// The rule rvd applies to a base that exists. `elsewhere` is the fix
    /// for a base that is not this user's uid-derived directory, nil for
    /// that directory itself.
    private static func existingRuntimeDirectory(
        _ base: String, info: stat, userID: uid_t, elsewhere: String?
    ) -> DoctorProblem? {
        let refuses = elsewhere == nil
            ? "rvd refuses this directory"
            : "rvd refuses this directory (XDG_RUNTIME_DIR here: the directory this shell and its agents dial)"
        if (info.st_mode & S_IFMT) != S_IFDIR {
            return DoctorProblem(
                id: "runtime-dir",
                severity: .fail,
                summary: "\(base) is not a directory; \(refuses)",
                fix: elsewhere
                    ?? "as root, mv '\(base)' '\(base).bak' && mkdir -m 0700 \(base) && chown \(userID) \(base)"
            )
        }
        if info.st_uid != userID {
            return DoctorProblem(
                id: "runtime-dir",
                severity: .fail,
                summary: "\(base) is owned by uid \(info.st_uid), not uid \(userID); \(refuses)",
                fix: elsewhere ?? "sudo chown \(userID) '\(base)'"
            )
        }
        let mode = Int(info.st_mode) & 0o777
        if mode & 0o022 != 0 {
            return DoctorProblem(
                id: "runtime-dir",
                severity: .fail,
                summary: "\(base) is group/world-writable (mode \(String(mode, radix: 8))); \(refuses)",
                fix: elsewhere ?? "chmod go-w '\(base)'"
            )
        }
        return nil
    }
}
