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
    /// Does a hook interpreter (`python3`) run? Asked only for an
    /// interpreter some hooked host needs. Default true (tests).
    var interpreterRunnable: (String) -> Bool = { _ in true }

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
#endif
        probes.interpreterRunnable = { AdapterRuntime.liveRunnable($0, pathEntries: pathEntries) }
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
#if os(Linux)
    static let packBundleName = "rv_RVPacks.resources"
#else
    static let packBundleName = "rv_RVPacks.bundle"
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
    /// that hook exits 127 and the host lets the tool call through.
    static func adapterRuntime(
        hosts: HostAdapterInstallationSnapshot,
        probes: DoctorInstallProbes
    ) -> [DoctorProblem] {
        var runnable: [String: Bool] = [:]
        return AdapterRuntime.hooked(hosts).compactMap { host in
            guard let interpreter = AdapterRuntime.interpreter(for: host) else { return nil }
            if runnable[interpreter] == nil {
                runnable[interpreter] = probes.interpreterRunnable(interpreter)
            }
            guard runnable[interpreter] == false else { return nil }
            return DoctorProblem(
                id: "adapter-runtime-\(host.rawValue)",
                severity: .fail,
                summary: "\(host.rawValue) hook runs \(interpreter), which is not runnable; "
                    + "\(host.rawValue) treats the failed hook as non-blocking, so its tool calls run unguarded",
                fix: "\(AdapterRuntime.installHint(interpreter)), then rv setup"
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
        let bundle = (paths.localRvd as NSString).deletingLastPathComponent + "/" + packBundleName
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundle, isDirectory: &isDirectory), isDirectory.boolValue else {
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
