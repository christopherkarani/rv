#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVPolicy
import RVPresentation
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

/// Install facts doctor cannot read from `rvd` itself.
struct DoctorInstallProbes {
    var userID: uid_t
    var launchd: LaunchdObservation?
    var trustManifest: TrustManifestState
    /// Would hooks trust the installed `rvd`? Nil when not evaluated.
    var daemonTrust: DoctorServiceTrust? = nil
    /// Does a hook interpreter run: the absolute path a hook command bakes,
    /// or `python3` on PATH for an earlier rv's command? Asked only for an
    /// interpreter some hooked host needs. Default true (tests).
    var interpreterRunnable: (String) -> Bool = { _ in true }
    /// Can this user replace a baked interpreter (its file or a directory
    /// above it, through symlinks)? Default false (tests).
    var interpreterReplaceable: (String) -> Bool = { _ in false }
    /// Linux: does a systemd user manager answer `systemctl --user`? Nil
    /// off Linux or when not evaluated (tests).
    var systemdUserManagerReachable: Bool? = nil

    static func live(
        home: HomeDirectory,
        pathEntries: [String] = [],
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
            daemonTrust: DaemonTrustProbe.live(OwnedPaths(home: home).localRvd)
        )
#else
        var probes = DoctorInstallProbes(userID: userID, launchd: nil, trustManifest: .notApplicable)
        probes.systemdUserManagerReachable = ProcessSystemctl().userManagerReachable()
#endif
        probes.interpreterRunnable = { AdapterRuntime.liveRunnable($0, pathEntries: pathEntries) }
        probes.interpreterReplaceable = AdapterRuntime.userCanReplace
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
            launchdDomain(probes.launchd, paths: paths, userID: probes.userID),
            configDirectory(paths: paths, userID: probes.userID),
        ].compactMap { $0 }
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
            let missing = (baked.isEmpty ? [name] : baked).first { interpreter in
                if runnable[interpreter] == nil {
                    runnable[interpreter] = probes.interpreterRunnable(interpreter)
                }
                return runnable[interpreter] == false
            }
            guard let interpreter = missing else {
                // Outside a system directory the interpreter is not in rv's
                // wiring table: the agent rv guards could swap it.
                guard let replaceable = baked.first(where: { $0.hasPrefix("/") && probes.interpreterReplaceable($0) })
                else { return nil }
                return DoctorProblem(
                    id: "adapter-runtime-replaceable-\(host.rawValue)",
                    severity: .warn,
                    summary: "\(host.rawValue) hook runs \(replaceable), which this user can replace, "
                        + "so an agent could swap the interpreter to skip the guard",
                    fix: "put a system \(name) (e.g. /usr/bin/\(name)) first on PATH, then rv setup"
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

    /// Mirrors rvd's socket base-directory rule: `~/.config` must be a
    /// directory owned by this user and not group/world-writable.
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
}
