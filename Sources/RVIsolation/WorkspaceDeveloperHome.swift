import Foundation

/// RV-managed developer home for one workspace.
///
/// Standard workspaces no longer use the project root as `$HOME`. Each
/// workspace gets a stable RV-owned directory outside the published project
/// tree:
///
/// ```
/// $HOME/.config/rv/workspaces/<slug>-<hash16>/home    $HOME
/// $HOME/.config/rv/workspaces/<slug>-<hash16>/cache   $XDG_CACHE_HOME
/// $HOME/.config/rv/workspaces/<slug>-<hash16>/tmp     $TMPDIR
/// ```
///
/// The identity derives from the resolved workspace path, so it survives
/// runtime restarts and is unique per checkout. The directories are created
/// host-side before spawn with owner-only permissions; they persist across
/// sessions (tool caches are expensive to rebuild) and are removed by
/// `rv uninstall`, which owns `$HOME/.config/rv`. No host dotfiles are
/// copied: a host shell profile may export secrets, and the cage must never
/// inherit them implicitly. The only seeded file is a minimal `.gitconfig`
/// carrying commit identity (never credentials).
public struct WorkspaceDeveloperHome: Sendable, Equatable {
    /// `$HOME/.config/rv/workspaces/<identity>`.
    public var root: String
    /// Writable `$HOME` for contained processes.
    public var home: String
    /// Writable `$XDG_CACHE_HOME` for contained processes.
    public var cache: String
    /// Writable `$TMPDIR` for contained processes (no trailing slash; the
    /// environment builder appends one per platform convention).
    public var tmp: String
    /// RV-owned transparency shims, first on the cage `PATH`. Read-only to
    /// the cage; refreshed by `ensure`.
    public var bin: String

    public init(root: String, home: String, cache: String, tmp: String, bin: String? = nil) {
        self.root = root
        self.home = home
        self.cache = cache
        self.tmp = tmp
        self.bin = bin ?? "\(root)/bin"
    }
}

extension WorkspaceDeveloperHome {
    /// Base directory holding every workspace home. Nil when the host home
    /// is unusable.
    public static func workspacesBase(hostHome: String) -> String? {
        guard isUsableAbsolutePath(hostHome) else { return nil }
        return "\(hostHome)/.config/rv/workspaces"
    }

    /// Stable identity for a resolved workspace path: a readable slug from
    /// the basename plus an FNV-1a hash of the full path for uniqueness.
    public static func identity(forWorkspacePath workspacePath: String) -> String {
        let basename = (workspacePath as NSString).lastPathComponent
        let kept = basename.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F:
                return true
            default:
                return false
            }
        }
        var slug = String(String.UnicodeScalarView(kept).prefix(24))
        if slug.isEmpty || slug == "." || slug == ".." {
            slug = "ws"
        }
        return "\(slug)-\(fnv1aHex(workspacePath))"
    }

    /// Resolve the RV-managed home for a workspace. Returns nil when either
    /// input is unusable; callers fall back to the legacy workspace home.
    public static func resolve(workspacePath: String, hostHome: String) -> WorkspaceDeveloperHome? {
        guard isUsableAbsolutePath(workspacePath), isUsableAbsolutePath(hostHome) else {
            return nil
        }
        guard let base = workspacesBase(hostHome: hostHome) else { return nil }
        let root = "\(base)/\(identity(forWorkspacePath: workspacePath))"
        return WorkspaceDeveloperHome(
            root: root,
            home: "\(root)/home",
            cache: "\(root)/cache",
            tmp: "\(root)/tmp"
        )
    }

    /// Create the home/cache/tmp directories host-side and seed the minimal
    /// files contained tools need. Best-effort: returns false when the home
    /// cannot be prepared, in which case the caller falls back to the
    /// legacy workspace home instead of failing the spawn.
    @discardableResult
    public func ensure(hostHome: String) -> Bool {
        guard isUsableAbsolutePath(hostHome) else { return false }
        let manager = FileManager.default
        for directory in [root, home, cache, tmp, bin] {
            do {
                try manager.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                return false
            }
        }
        // Harden pre-existing directories without touching their contents.
        for directory in [root, home, cache, tmp, bin] {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        }
        refreshTransparencyShims()
        linkReadOnlyToolState(hostHome: hostHome)
        seedGitIdentity(hostHome: hostHome)
        return true
    }

    /// Write (or refresh) the PATH shadowing shims. The cage resolves
    /// `sandbox-exec` through `PATH` to this wrapper because the kernel
    /// forbids applying a Seatbelt profile inside the cage
    /// (`sandbox_apply: Operation not permitted`): any tool that shells out
    /// to `sandbox-exec` — SwiftPM manifest loading is the prominent one —
    /// would otherwise fail unconditionally. The wrapper re-execs the
    /// payload under the outer RV profile, which still confines it; the
    /// inner profile cannot apply by kernel law, so transparency loses no
    /// enforceable boundary. Content is refreshed on every `ensure` so a
    /// cage-modified or stale copy cannot linger (the cage holds no write
    /// grant on `bin`, so modification needs a host-side actor anyway).
    func refreshTransparencyShims() {
        writeShim(name: "sandbox-exec", content: Self.sandboxExecPassthrough)
        writeShim(name: "swift", content: Self.swiftTransparencyShim(selfPath: "\(bin)/swift"))
    }

    func writeShim(name: String, content: String) {
        let manager = FileManager.default
        let path = "\(bin)/\(name)"
        let data = Data(content.utf8)
        if let existing = manager.contents(atPath: path), existing == data {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return
        }
        manager.createFile(atPath: path, contents: data)
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// SwiftPM evaluates manifests under `/usr/bin/sandbox-exec` (absolute
    /// path, so the passthrough cannot intercept) with `--disable-sandbox`
    /// as the only bypass, and the kernel forbids nested Seatbelt profiles.
    /// Inject the documented global flag for the manifest-touching
    /// subcommands; driver modes (scripts, REPL, compiler flags) pass
    /// through untouched. The outer RV profile still confines everything.
    static func swiftTransparencyShim(selfPath: String) -> String {
        """
        #!/bin/sh
        # RV nested-sandbox transparency for SwiftPM. See WorkspaceDeveloperHome.
        RV_SHIM_SELF=\(shSingleQuote(selfPath))
        RV_SHIM_DIR=${RV_SHIM_SELF%/*}
        RV_REAL=""
        RV_IFS=$IFS; IFS=:
        for RV_D in $PATH; do
            if [ "$RV_D" = "$RV_SHIM_DIR" ]; then continue; fi
            case "$RV_D" in /*) ;; *) continue;; esac
            RV_CAND="$RV_D/swift"
            if [ -x "$RV_CAND" ] && [ ! "$RV_CAND" -ef "$RV_SHIM_SELF" ]; then RV_REAL="$RV_CAND"; break; fi
        done
        IFS=$RV_IFS
        if [ -z "$RV_REAL" ]; then echo "swift: no Swift toolchain found on PATH" >&2; exit 127; fi
        case "$1" in
        build|run|test|package)
            RV_SUB=$1; shift
            exec "$RV_REAL" "$RV_SUB" --disable-sandbox "$@"
            ;;
        *)
            exec "$RV_REAL" "$@"
            ;;
        esac
        """
    }

    static let sandboxExecPassthrough = """
        #!/bin/sh
        # RV nested-sandbox transparency shim. The kernel forbids applying a
        # Seatbelt profile inside the cage, so drop the (unenforceable) inner
        # profile arguments and run the payload under the outer RV profile.
        while [ $# -gt 0 ]; do
            case "$1" in
            -p|-f|-n|-D)
                shift
                [ $# -gt 0 ] && shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                shift
                ;;
            *)
                break
                ;;
            esac
        done
        if [ $# -eq 0 ]; then
            echo "sandbox-exec: no command" >&2
            exit 64
        fi
        exec "$@"
        """
}

extension WorkspaceDeveloperHome {
    /// Tool-state directories that runtimes locate implicitly under `$HOME`
    /// and use read-mostly (toolchains, installed language versions).
    /// Linked from the RV home to the host originals so version-manager
    /// shims keep working without per-tool environment branches. Writable
    /// state (caches, registries) is intentionally NOT linked: it starts
    /// fresh inside the RV home. Each link is created only when the host
    /// original exists and the RV-home path is absent, so user state created
    /// inside the cage always wins.
    static let readOnlyToolStateLinks = [".rustup", ".pyenv", ".volta"]

    func linkReadOnlyToolState(hostHome: String) {
        let manager = FileManager.default
        for name in Self.readOnlyToolStateLinks {
            let source = "\(hostHome)/\(name)"
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: source, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                continue
            }
            let destination = "\(home)/\(name)"
            if manager.fileExists(atPath: destination) { continue }
            try? manager.createSymbolicLink(atPath: destination, withDestinationPath: source)
        }
    }

    /// Minimal commit identity so `git commit` works without inheriting the
    /// host gitconfig (which may carry credentials, helpers, and signing
    /// configuration that cannot work in the cage). Writes
    /// `<home>/.gitconfig` only when absent; never overwrites user state.
    /// Signing is disabled: no keys exist in the cage.
    func seedGitIdentity(hostHome: String) {
        let manager = FileManager.default
        let destination = "\(home)/.gitconfig"
        guard manager.fileExists(atPath: destination) == false else { return }
        guard let git = Self.hostGitExecutable() else { return }
        let name = Self.hostGlobalGitValue(git: git, key: "user.name", hostHome: hostHome)
        let email = Self.hostGlobalGitValue(git: git, key: "user.email", hostHome: hostHome)
        guard name != nil || email != nil else { return }
        var lines = ["[user]"]
        if let name {
            lines.append("\tname = \(gitconfigEscape(name))")
        }
        if let email {
            lines.append("\temail = \(gitconfigEscape(email))")
        }
        lines.append("[commit]")
        lines.append("\tgpgsign = false")
        lines.append("[tag]")
        lines.append("\tgpgsign = false")
        let content = lines.joined(separator: "\n") + "\n"
        manager.createFile(atPath: destination, contents: Data(content.utf8))
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination)
    }

    static func hostGitExecutable() -> String? {
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func hostGlobalGitValue(git: String, key: String, hostHome: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["config", "--global", "--get", key]
        process.environment = [
            "HOME": hostHome,
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false, value.count <= 256,
            value.contains("\0") == false,
            value.contains("\n") == false, value.contains("\r") == false
        else {
            return nil
        }
        return value
    }
}

func shSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func gitconfigEscape(_ value: String) -> String {
    let needsQuotes =
        value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.hasPrefix("\t") || value.hasSuffix("\t")
            || value.contains(";") || value.contains("#")
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return needsQuotes ? "\"\(escaped)\"" : escaped
}

func isUsableAbsolutePath(_ path: String) -> Bool {
    path.hasPrefix("/") && path.contains("\0") == false && path.contains("\n") == false
}

func fnv1aHex(_ value: String) -> String {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0100_0000_01B3
    }
    return String(format: "%016llx", hash)
}
