import Foundation
import RVDomain

/// Typed environment projection for Standard workspaces.
///
/// The contained process inherits its parent environment through this
/// policy, never wholesale. Classification is by name only, in three bands:
///
/// 1. Runtime-managed names (`PATH`, `HOME`, `TMPDIR`, …) are dropped here
///    and set by the spawn builder from RV-owned values.
/// 2. Known-safe prefixes (`GIT_AUTHOR_*`, `GIT_COMMITTER_*`) pass first so
///    secret-token rules cannot swallow commit identity.
/// 3. Everything else passes by default when the name is well-formed and the
///    value is sane, unless a denylist rule matches.
///
/// Default-allow is deliberate: version managers, toolchain selectors, and
/// agents use bespoke variable names that no allowlist can enumerate, and
/// the product contract requires them to work without per-tool RV patches.
/// The denylist therefore targets secret-bearing, credential-pointer,
/// loader-injection, interpreter-hook, trust-redirect, and host-path-state
/// names aggressively, and the filesystem sandbox remains the backstop:
/// values that name host paths the cage cannot read fail safely.
///
/// Values are never logged. Tests assert on names only.
public enum ContainedEnvironmentPolicy {
    /// Maximum accepted value size. Host `PATH` values pass through their
    /// own sanitizer with a separate budget.
    public static let maxValueBytes = 32_768

    /// Names the runtime sets itself. Always dropped from the projection.
    public static func isManagedByRuntime(_ name: String) -> Bool {
        switch name {
        case "PATH", "HOME", "TMPDIR", "TEMP", "TMP", "PWD", "OLDPWD", "SHELL", "SHLVL", "_":
            return true
        default:
            return false
        }
    }

    /// Known-safe names that pass before denylist rules. Commit identity is
    /// recorded in every commit and must survive the `AUTH` token rule.
    public static func isAlwaysAllowed(_ name: String) -> Bool {
        name.hasPrefix("GIT_AUTHOR_") || name.hasPrefix("GIT_COMMITTER_")
    }

    /// Whether `name` must be stripped. Case-insensitive: `npm_config_cache`
    /// and `NPM_CONFIG_CACHE` are the same variable to most tools.
    public static func isBlockedVariableName(_ name: String) -> Bool {
        let folded = name.uppercased()
        if deniedExactNames.contains(folded) { return true }
        for prefix in deniedPrefixes {
            if folded.hasPrefix(prefix) { return true }
        }
        for infixString in deniedInfixes {
            if folded.contains(infixString) { return true }
        }
        let tokens = folded.split(separator: "_").map(String.init)
        for token in deniedTokens {
            if tokens.contains(token) { return true }
        }
        return false
    }

    /// Project a host environment to cage-safe entries, sorted by name for
    /// deterministic profiles and tests.
    public static func project(host: [String: String]) -> [(String, String)] {
        var kept: [(String, String)] = []
        for (name, value) in host {
            if isManagedByRuntime(name) { continue }
            guard isValidName(name), isSaneValue(value) else { continue }
            if isAlwaysAllowed(name) {
                kept.append((name, value))
                continue
            }
            if isBlockedVariableName(name) { continue }
            kept.append((name, value))
        }
        kept.sort { $0.0 < $1.0 }
        return kept
    }

    public static func isValidName(_ name: String) -> Bool {
        guard name.isEmpty == false, name.count <= 128 else { return false }
        let scalars = Array(name.unicodeScalars)
        guard isNameStart(scalars[0]) else { return false }
        return scalars.allSatisfy(isNameChar)
    }

    public static func isSaneValue(_ value: String) -> Bool {
        value.utf8.count <= maxValueBytes
            && value.contains("\0") == false
            && value.contains("\n") == false
            && value.contains("\r") == false
    }

    private static func isNameStart(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x5F:
            return true
        default:
            return false
        }
    }

    private static func isNameChar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x5F:
            return true
        default:
            return false
        }
    }
}

extension ContainedEnvironmentPolicy {
    /// Exact names (uppercased) that never cross into the cage.
    static let deniedExactNames: Set<String> = [
        // Privilege / agent sockets and helpers.
        "SSH_AUTH_SOCK", "SSH_AGENT_PID", "GPG_AGENT_INFO",
        "GIT_SSH", "GIT_SSH_COMMAND", "GIT_ASKPASS",
        "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM",
        // Host proxy configuration. RV sets its own proxy variables; a
        // host proxy (possibly with embedded credentials, possibly on
        // loopback where the sandbox admits direct connects) must never
        // become the cage route, and must fail closed when RV has no proxy.
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        // Loader injection.
        "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT",
        // Interpreter hooks.
        "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONBREAKPOINT", "PYTHONINSPECT",
        "RUBYOPT", "RUBYLIB", "RUBYPATH",
        "NODE_OPTIONS", "NODE_PATH",
        "PERL5LIB", "PERL5OPT",
        // Trust redirects. The cage cannot read host CA bundles; stripping
        // selects the sandbox trust store instead of failing TLS opaquely.
        "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE",
        "GIT_SSL_CAINFO", "PIP_CERT",
        // Credential-file pointers.
        "KUBECONFIG", "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE", "AWS_CREDENTIAL_FILE",
        // Host-path tool state that must resolve under the RV home instead.
        "GOPATH", "GOMODCACHE", "GOCACHE", "GOROOT", "GOENV", "GOTOOLDIR",
        "PIP_CONFIG_FILE",
        "NPM_CONFIG_CACHE", "NPM_CONFIG_USERCONFIG", "NPM_CONFIG_GLOBALCONFIG",
        "CONDA_ENVS_PATH", "CONDA_PKGS_DIRS",
        "HF_HOME", "HF_HUB_CACHE", "TRANSFORMERS_CACHE",
        // Writable XDG state. RV sets equivalents under its own home.
        // `XDG_DATA_DIRS` / `XDG_CONFIG_DIRS` stay: read-only search paths
        // whose unreadable entries simply miss.
        "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
        "XDG_RUNTIME_DIR",
    ]

    /// Name prefixes (uppercased) that never cross into the cage.
    static let deniedPrefixes = [
        "DYLD_",
        "GIT_CONFIG_",
        "NODE_DEBUG",
    ]

    /// Substrings (uppercased) that never cross into the cage.
    static let deniedInfixes = [
        "AUTHORIZATION",
        "PRIVATE_KEY",
    ]

    /// Underscore-separated tokens (uppercased) that never cross into the
    /// cage. Catches `*_TOKEN`, `*_API_KEY`, `*_SECRET`, `*_PASSWORD`, and
    /// vendor variants without enumerating every provider.
    static let deniedTokens: Set<String> = [
        "TOKEN", "TOKENS",
        "SECRET", "SECRETS",
        "PASSWORD", "PASSWORDS", "PASSWD", "PASSPHRASE",
        "CREDENTIAL", "CREDENTIALS",
        "KEY", "KEYS",
        "AUTH",
        "BEARER",
        "COOKIE", "COOKIES",
        "OTP", "TOTP",
        "LICENSE",
        "NETRC",
    ]
}

/// Filesystem access for PATH sanitization. Injected so tests run hermetic.
public struct ContainedPATHProbe: Sendable {
    public var realpath: @Sendable (String) -> String?
    public var isDirectory: @Sendable (String) -> Bool
    public var isExecutable: @Sendable (String) -> Bool
    public var listDirectory: @Sendable (String) -> [String]?

    public init(
        realpath: @escaping @Sendable (String) -> String?,
        isDirectory: @escaping @Sendable (String) -> Bool,
        isExecutable: @escaping @Sendable (String) -> Bool,
        listDirectory: @escaping @Sendable (String) -> [String]?
    ) {
        self.realpath = realpath
        self.isDirectory = isDirectory
        self.isExecutable = isExecutable
        self.listDirectory = listDirectory
    }

    public static var live: ContainedPATHProbe {
        ContainedPATHProbe(
            realpath: { posixRealpath($0) },
            isDirectory: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            listDirectory: { path in
                (try? FileManager.default.contentsOfDirectory(atPath: path))?.sorted()
            }
        )
    }
}

/// Sanitized search path plus the filesystem facts the Seatbelt profile
/// needs to make it usable.
public struct SanitizedPATH: Sendable, Equatable {
    /// Colon-joined value for the cage `PATH`.
    public var value: String
    /// Admitted entry directories (realpaths) for read/execute grants.
    public var directories: [String]
    /// Symlink-target and `bin`-parent directories implied by enumeration.
    public var impliedDirectories: [String]
    /// Non-executable sensitive files found directly in PATH directories
    /// (`.env`, key basenames) for explicit deny rules.
    public var sensitiveFiles: [String]

    public init(value: String, directories: [String], impliedDirectories: [String], sensitiveFiles: [String]) {
        self.value = value
        self.directories = directories
        self.impliedDirectories = impliedDirectories
        self.sensitiveFiles = sensitiveFiles
    }
}

public enum ContainedPATH {
    public static let maxEntries = 64
    public static let maxValueBytes = 8_192
    public static let maxListedPerDirectory = 256
    public static let maxImpliedDirectories = 128
    public static let maxSensitiveFiles = 64

    public static let systemFallbacks = ["/usr/bin", "/bin"]

    /// Sanitize a host `PATH` for the cage.
    ///
    /// Keeps absolute entries that resolve to real directories, skipping the
    /// host home root itself and anything at-or-beneath (or above) a
    /// secret-catalog path. Enumerates each admitted directory (bounded) to
    /// find symlink-target directories — `~/.local/bin/node` resolving into
    /// a toolchain tree — and non-executable sensitive files for explicit
    /// denies. A `bin` directory (admitted or symlink-target) additionally
    /// implies its parent one level up (`<tool>/bin` with sibling `lib`),
    /// unless the secret catalog vetoes the expansion. The filesystem root
    /// is never implied.
    public static func sanitize(
        hostPATH: String?,
        hostHome: String,
        agentBin: String?,
        rvBin: String? = nil,
        probe: ContainedPATHProbe = .live
    ) -> SanitizedPATH {
        var admitted: [String] = []
        var seen: Set<String> = []
        func admit(_ candidate: String) {
            guard admitted.count < maxEntries else { return }
            guard candidate.isEmpty == false, candidate.count <= 1_024,
                candidate.hasPrefix("/"),
                candidate.contains("\0") == false, candidate.contains("\n") == false
            else {
                return
            }
            guard let resolved = probe.realpath(candidate), probe.isDirectory(resolved) else {
                return
            }
            guard seen.insert(resolved).inserted else { return }
            if ContainedSensitivePaths.isSensitivePATHEntry(resolved, hostHome: hostHome) {
                return
            }
            admitted.append(resolved)
        }
        // RV transparency shims first, so nested `sandbox-exec` resolves to
        // the passthrough before the (unusable-in-cage) system binary.
        if let rvBin, rvBin.isEmpty == false {
            admit(rvBin)
        }
        if let agentBin, agentBin.isEmpty == false {
            admit(agentBin)
        }
        if let hostPATH {
            for entry in hostPATH.split(separator: ":", omittingEmptySubsequences: false).map(String.init) {
                admit(entry)
            }
        }
        for fallback in systemFallbacks where admitted.contains(fallback) == false {
            admit(fallback)
        }
        // Drop from the low-priority end until the value fits the budget.
        while admitted.joined(separator: ":").utf8.count > maxValueBytes, admitted.isEmpty == false {
            admitted.removeLast()
        }
        var value = admitted.joined(separator: ":")
        if value.isEmpty {
            // The base profile already admits `/usr`, so an empty grant
            // list stays usable; the value keeps shells functional.
            value = systemFallbacks.joined(separator: ":")
        }
        var implied: [String] = []
        var impliedSeen = Set(admitted)
        var sensitive: [String] = []
        // A directly-admitted `bin` directory has the sibling-`lib` shape:
        // a toolchain's `<root>/usr/bin` on PATH needs `<root>/usr`
        // readable or its binaries die in dyld (`swift-driver` loading
        // `libSwiftDriverExecution.dylib` is the observed case). This runs
        // before enumeration because the implied budget is shared: a dense
        // PATH (Homebrew alone contributes dozens of symlink targets) would
        // otherwise starve these few high-value grants. Same secret veto;
        // `/bin` expands to nothing because the root itself is never
        // implied.
        for directory in admitted {
            if implied.count >= maxImpliedDirectories { break }
            guard (directory as NSString).lastPathComponent == "bin" else { continue }
            let parent = (directory as NSString).deletingLastPathComponent
            guard parent.hasPrefix("/"), parent != "/", parent != directory else { continue }
            if impliedSeen.insert(parent).inserted,
                ContainedSensitivePaths.isSensitivePATHEntry(parent, hostHome: hostHome) == false
            {
                implied.append(parent)
            }
        }
        for directory in admitted {
            guard let names = probe.listDirectory(directory) else { continue }
            for name in names.prefix(maxListedPerDirectory) {
                if name == "." || name == ".." { continue }
                let full = "\(directory)/\(name)"
                if ContainedSensitivePaths.isSensitiveBasename(name),
                    probe.isExecutable(full) == false,
                    sensitive.count < maxSensitiveFiles
                {
                    sensitive.append(full)
                }
                if implied.count >= maxImpliedDirectories { break }
                guard let target = probe.realpath(full), target != full else { continue }
                if probe.isDirectory(target) {
                    if impliedSeen.insert(target).inserted,
                        ContainedSensitivePaths.isSensitivePATHEntry(target, hostHome: hostHome) == false
                    {
                        implied.append(target)
                    }
                    continue
                }
                let parent = (target as NSString).deletingLastPathComponent
                guard parent.hasPrefix("/"), parent != directory else { continue }
                if impliedSeen.insert(parent).inserted,
                    ContainedSensitivePaths.isSensitivePATHEntry(parent, hostHome: hostHome) == false
                {
                    implied.append(parent)
                }
                if (parent as NSString).lastPathComponent == "bin" {
                    let grandparent = (parent as NSString).deletingLastPathComponent
                    if grandparent.hasPrefix("/"), grandparent != "/", grandparent != parent,
                        grandparent != directory,
                        impliedSeen.insert(grandparent).inserted,
                        ContainedSensitivePaths.isSensitivePATHEntry(grandparent, hostHome: hostHome) == false
                    {
                        implied.append(grandparent)
                    }
                }
            }
        }
        return SanitizedPATH(
            value: value,
            directories: admitted,
            impliedDirectories: implied,
            sensitiveFiles: sensitive
        )
    }
}

/// Principled toolchain and resource roots.
///
/// System roots are world-readable install locations gated on existence.
/// Home-state roots are single-purpose tool directories (never `.config`,
/// `.local`, or `Library`); each is granted only when it exists on disk.
/// Credential files inside granted trees stay denied through
/// `ContainedSensitivePaths` denies, which take precedence over allows.
public enum ContainedToolchainRoots {
    public static let systemRoots = [
        "/opt/homebrew",
        "/usr/local",
        "/opt/local",
        "/Library/Developer",
        "/Applications/Xcode.app",
        "/Applications/Xcode-beta.app",
        "/Library/Apple",
    ]

    public static let homeStateRoots = [
        ".cargo",
        ".rustup",
        ".swiftly",
        ".pyenv",
        ".volta",
        ".bun",
        ".nvm",
        ".fnm",
        ".asdf",
        ".mise",
        ".rbenv",
        ".sdkman",
        ".deno",
        ".pnpm",
        ".npm-global",
        ".yarn",
        ".gvm",
        ".goenv",
        ".plenv",
        ".phpenv",
        "miniconda3",
        "anaconda3",
        "miniforge3",
    ]

    public static func existingSystemRoots() -> [String] {
        systemRoots.filter {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    public static func existingHomeStateRoots(hostHome: String) -> [String] {
        guard isUsableAbsolutePath(hostHome) else { return [] }
        return homeStateRoots.map { "\(hostHome)/\($0)" }.filter {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }
}

/// Secret-catalog projections for the productive profile.
///
/// The day-one catalog is the single source: home-relative sensitive paths
/// veto PATH admission and expansion, and become explicit Seatbelt denies
/// under granted trees. Temporary agent-auth compatibility paths are
/// excluded from denies so already-working agent logins keep working; that
/// exclusion is the only overlap between the generic boundary and the
/// pre-secret-broker compatibility behavior.
public enum ContainedSensitivePaths {
    /// Home-relative sensitive paths from the catalog (`homeSuffix` and
    /// `hostAuth` kinds), e.g. `.ssh`, `.config/gh`.
    public static var catalogRelatives: [String] {
        var relatives: [String] = []
        for rule in SecretPathCatalog.dayOne.rules {
            switch rule.kind {
            case .homeSuffix(let parts), .hostAuth(let parts):
                relatives.append(parts.joined(separator: "/"))
            case .basename, .envVariant:
                break
            }
        }
        return relatives
    }

    /// Whether an absolute path must never be admitted as (or implied by) a
    /// PATH entry: the home root itself, anything at-or-beneath a sensitive
    /// path, or anything that would expose one from above.
    public static func isSensitivePATHEntry(_ realpath: String, hostHome: String) -> Bool {
        guard isUsableAbsolutePath(hostHome) else { return true }
        guard realpath == hostHome || realpath.hasPrefix(hostHome + "/") else {
            return false
        }
        let relative = realpath == hostHome ? "" : String(realpath.dropFirst(hostHome.count + 1))
        if relative.isEmpty { return true }
        for sensitive in catalogRelatives {
            if sensitive == relative || sensitive.hasPrefix(relative + "/")
                || relative.hasPrefix(sensitive + "/")
            {
                return true
            }
        }
        return false
    }

    /// Whether a bare file name is a sensitive data file (`.env`, key and
    /// credential basenames). Used for enumerated PATH-directory entries.
    public static func isSensitiveBasename(_ name: String) -> Bool {
        for rule in SecretPathCatalog.dayOne.rules {
            switch rule.kind {
            case .basename, .envVariant:
                if rule.kind.matches(name) { return true }
            case .homeSuffix, .hostAuth:
                break
            }
        }
        return false
    }

    /// Absolute Seatbelt deny paths for one host home, minus the temporary
    /// agent-auth compatibility paths. Both files and directories are
    /// denied as subpaths (a subpath rule covers the path itself).
    public static func denyPaths(hostHome: String, excluding: Set<String>) -> [String] {
        guard isUsableAbsolutePath(hostHome) else { return [] }
        var paths = catalogRelatives.map { "\(hostHome)/\($0)" }
        // Registry credentials live inside the granted cargo tree.
        paths.append("\(hostHome)/.cargo/credentials.toml")
        paths.append("\(hostHome)/.cargo/credentials")
        let excluded = excluding.union(compatCredentialPaths(hostHome: hostHome))
        return paths.filter { excluded.contains($0) == false }.sorted()
    }

    static func compatCredentialPaths(hostHome: String) -> Set<String> {
        Set(AgentHomeStaging.credentialLinks.map { "\(hostHome)/\($0.source)" })
    }
}
