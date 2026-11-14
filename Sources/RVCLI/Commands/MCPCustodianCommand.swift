import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVMCP

/// What `rv mcp custodian install` puts on a Linux host, and how
/// `uninstall` takes it away again (docs/security/mcp-linux-custodian.md).
/// The plan is data; `MCPCustodianSetup.run` carries it out, one audited
/// step at a time, and stops at the first that fails.
enum MCPCustodianSetup {
    static let account = MCPCustodianSocket.account
    /// Root's own copy of the custodian and the libraries shipped beside it.
    static let directory = "/usr/local/libexec/rv"
    static let binary = directory + "/rv-mcp-custodian"
    static let keyUnit = "/etc/systemd/system/rv-mcp-custodian.service"
    static let presenceUnit = "/etc/systemd/system/rv-mcp-presence.service"
    static let pamFile = "/etc/pam.d/\(MCPCustodianSocket.pamService)"
    static let state = "/var/lib/rv-mcp-custodian"
    static let units = ["rv-mcp-custodian.service", "rv-mcp-presence.service"]
    /// First line of every file this writes, so `uninstall` and a second
    /// `install` only ever replace their own.
    static let marker = "# Written by `rv mcp custodian install`; removed by `rv mcp custodian uninstall`."

    /// The key daemon: its own account, no capabilities, no network, no
    /// view of anyone's home, and nothing writable but its state.
    static let keyUnitText = """
        \(marker)
        [Unit]
        Description=rv MCP approvals key custodian
        Documentation=https://github.com/christopherkarani/rv/blob/main/docs/security/mcp-linux-custodian.md

        [Service]
        Type=simple
        ExecStart=\(binary) serve
        User=\(account)
        Group=\(account)
        StateDirectory=rv-mcp-custodian
        StateDirectoryMode=0700
        RuntimeDirectory=rv-mcp-custodian
        RuntimeDirectoryMode=0755
        UMask=0077
        Restart=on-failure
        RestartSec=1
        NoNewPrivileges=yes
        CapabilityBoundingSet=
        AmbientCapabilities=
        PrivateNetwork=yes
        PrivateDevices=yes
        PrivateTmp=yes
        ProtectSystem=strict
        ProtectHome=yes
        ProtectProc=invisible
        ProcSubset=pid
        ProtectKernelTunables=yes
        ProtectKernelModules=yes
        ProtectKernelLogs=yes
        ProtectControlGroups=yes
        ProtectClock=yes
        ProtectHostname=yes
        RestrictAddressFamilies=AF_UNIX
        RestrictNamespaces=yes
        RestrictRealtime=yes
        RestrictSUIDSGID=yes
        LockPersonality=yes
        MemoryDenyWriteExecute=yes
        SystemCallArchitectures=native
        SystemCallFilter=@system-service
        SystemCallFilter=~@privileged @resources
        SystemCallErrorNumber=EPERM

        [Install]
        WantedBy=multi-user.target

        """

    /// The presence helper: root, because checking another account's
    /// password needs it, with only the capabilities PAM modules use, a
    /// read-only system and no way to gain more.
    static let presenceUnitText = """
        \(marker)
        [Unit]
        Description=rv MCP approvals presence helper (PAM)
        Documentation=https://github.com/christopherkarani/rv/blob/main/docs/security/mcp-linux-custodian.md
        After=rv-mcp-custodian.service

        [Service]
        Type=simple
        ExecStart=\(binary) presence
        RuntimeDirectory=rv-mcp-presence
        RuntimeDirectoryMode=0755
        UMask=0077
        Restart=on-failure
        RestartSec=1
        NoNewPrivileges=yes
        CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE CAP_SETUID CAP_SETGID CAP_AUDIT_WRITE CAP_CHOWN CAP_FOWNER
        PrivateDevices=yes
        PrivateTmp=yes
        ProtectSystem=full
        ProtectHome=read-only
        ProtectKernelTunables=yes
        ProtectKernelModules=yes
        ProtectKernelLogs=yes
        ProtectControlGroups=yes
        ProtectClock=yes
        ProtectHostname=yes
        RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
        RestrictNamespaces=yes
        RestrictRealtime=yes
        RestrictSUIDSGID=yes
        LockPersonality=yes
        MemoryDenyWriteExecute=yes
        SystemCallArchitectures=native

        [Install]
        WantedBy=multi-user.target

        """

    /// The PAM service: the distribution's own authentication and account
    /// stacks, so the owner proves presence the way they log in.
    static func pamText(include: (auth: String, account: String)) -> String {
        """
        \(marker)
        auth     include  \(include.auth)
        account  include  \(include.account)

        """
    }

    /// Which stacks this distribution has: `common-auth` and
    /// `common-account` (Debian, Ubuntu, SUSE), or `system-auth` (Fedora,
    /// RHEL, Arch). Nil when it has neither.
    static func pamInclude(exists: (String) -> Bool) -> (auth: String, account: String)? {
        if exists("/etc/pam.d/common-auth"), exists("/etc/pam.d/common-account") { return ("common-auth", "common-account") }
        if exists("/etc/pam.d/system-auth") { return ("system-auth", "system-auth") }
        return nil
    }

    /// One change to the host.
    enum Step: Equatable {
        case run([String])
        /// A command whose failure is not one (stopping a unit that is not loaded).
        case attempt([String])
        case installFile(from: String, to: String, mode: mode_t)
        case writeFile(String, contents: String, mode: mode_t)
        case removeFile(String)
        case removeTree(String)

        var summary: String {
            switch self {
            case .run(let command), .attempt(let command): command.joined(separator: " ")
            case .installFile(let from, let to, _): "install \(from) as \(to)"
            case .writeFile(let path, _, _): "write \(path)"
            case .removeFile(let path): "remove \(path)"
            case .removeTree(let path): "remove \(path) and everything in it"
            }
        }
    }

    /// What the host is like, as far as the plan needs to know.
    struct Host {
        var isRoot: Bool
        var hasSystemd: Bool
        /// The custodian binary beside this rv, or nil.
        var source: String?
        /// Shared libraries shipped beside it (a release's Swift runtime),
        /// which it loads from its own directory.
        var libraries: [String] = []
        var pam: (auth: String, account: String)?
        var accountExists: Bool
        var nologin: String
        /// Whether a file is there and is not one this wrote.
        var isForeign: (String) -> Bool
    }

    struct Refusal: Error, Equatable {
        var message: String
    }

    static func installPlan(_ host: Host) -> Result<[Step], Refusal> {
        guard host.isRoot else {
            return .failure(Refusal(message: "this changes the system: run it as root (sudo rv mcp custodian install)"))
        }
        guard host.hasSystemd else {
            return .failure(Refusal(message: "this host does not run systemd, which starts and confines the custodian; "
                + "nothing was installed"))
        }
        guard let source = host.source else {
            return .failure(Refusal(message: "rv-mcp-custodian is not installed beside rv; reinstall rv"))
        }
        guard let pam = host.pam else {
            return .failure(Refusal(message: "this host has no PAM stack to include (/etc/pam.d/common-auth or "
                + "system-auth), so the owner's presence could not be checked; nothing was installed"))
        }
        for path in [keyUnit, presenceUnit, pamFile] where host.isForeign(path) {
            return .failure(Refusal(message: "\(path) exists and was not written by rv; nothing was installed"))
        }
        var steps: [Step] = []
        if host.accountExists == false {
            steps.append(.run([
                "useradd", "--system", "--user-group", "--no-create-home", "--home-dir", "/nonexistent", "--shell",
                host.nologin, account,
            ]))
        }
        steps += host.libraries.sorted().map {
            .installFile(from: $0, to: directory + "/" + ($0 as NSString).lastPathComponent, mode: 0o755)
        }
        steps += [
            .installFile(from: source, to: binary, mode: 0o755),
            .writeFile(pamFile, contents: pamText(include: pam), mode: 0o644),
            .writeFile(keyUnit, contents: keyUnitText, mode: 0o644),
            .writeFile(presenceUnit, contents: presenceUnitText, mode: 0o644),
            .run(["systemctl", "daemon-reload"]),
            .run(["systemctl", "enable"] + units),
            // Restart, not start: a second install replaces a running binary.
            .run(["systemctl", "restart"] + units),
        ]
        return .success(steps)
    }

    /// Everything `install` made, in reverse. The keys stay unless `purge`:
    /// removing them voids every grant and signature made with them.
    static func uninstallPlan(_ host: Host, purge: Bool) -> Result<[Step], Refusal> {
        guard host.isRoot else {
            return .failure(Refusal(message: "this changes the system: run it as root (sudo rv mcp custodian uninstall)"))
        }
        for path in [keyUnit, presenceUnit, pamFile] where host.isForeign(path) {
            return .failure(Refusal(message: "\(path) was not written by rv; nothing was removed"))
        }
        var steps: [Step] = []
        if host.hasSystemd { steps.append(.attempt(["systemctl", "disable", "--now"] + units)) }
        steps += [.removeFile(keyUnit), .removeFile(presenceUnit)]
        if host.hasSystemd { steps.append(.run(["systemctl", "daemon-reload"])) }
        steps += [.removeFile(pamFile), .removeTree(directory)]
        if purge {
            steps.append(.removeTree(state))
            if host.accountExists { steps.append(.run(["userdel", account])) }
        }
        return .success(steps)
    }

    // MARK: - Carrying it out

    static func liveHost() -> Host {
        let files = FileManager.default
        let home = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        let beside = home?.appendingPathComponent("rv-mcp-custodian").path
        let siblings = home.flatMap { try? files.contentsOfDirectory(atPath: $0.path) } ?? []
        return Host(
            isRoot: geteuid() == 0,
            hasSystemd: files.fileExists(atPath: "/run/systemd/system"),
            source: beside.flatMap { files.isExecutableFile(atPath: $0) ? $0 : nil },
            // `lib*.so`: the runtime a release stages, not a build's test bundles.
            libraries: siblings.filter { $0.hasPrefix("lib") && ($0.hasSuffix(".so") || $0.contains(".so.")) }.compactMap { name in
                home?.appendingPathComponent(name).path
            },
            pam: pamInclude { files.fileExists(atPath: $0) },
            accountExists: getpwnam(account) != nil,
            nologin: files.isExecutableFile(atPath: "/usr/sbin/nologin") ? "/usr/sbin/nologin" : "/sbin/nologin",
            isForeign: { path in
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return files.fileExists(atPath: path)
                }
                return text.hasPrefix(marker) == false
            })
    }

    /// Carries out `steps`, writing each to `log` (and the system log)
    /// before it runs. Nil when all were done, else what stopped it.
    static func run(_ steps: [Step], log: (String) -> Void) -> String? {
        for step in steps {
            log(step.summary)
            audit(step.summary)
            if let failure = perform(step) {
                audit("failed: \(step.summary): \(failure)")
                return "\(step.summary): \(failure)"
            }
        }
        return nil
    }

    /// The system log's authentication facility: where sudo's own record is.
    static func audit(_ message: String) {
        #if os(Linux)
        withVaList([("rv mcp custodian: " + message) as NSString]) { vsyslog(LOG_AUTHPRIV | LOG_NOTICE, "%s", $0) }
        #endif
    }

    private static func perform(_ step: Step) -> String? {
        switch step {
        case .run(let command), .attempt(let command):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
            process.environment = ["PATH": "/usr/sbin:/usr/bin:/sbin:/bin"]
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return "could not be run" }
            process.waitUntilExit()
            if case .attempt = step { return nil }
            return process.terminationStatus == 0 ? nil : "exit \(process.terminationStatus)"
        case .installFile(let from, let to, let mode):
            guard let data = FileManager.default.contents(atPath: from) else { return "cannot read \(from)" }
            return replaceFile(data, at: to, mode: mode)
        case .writeFile(let path, let contents, let mode):
            return replaceFile(Data(contents.utf8), at: path, mode: mode)
        case .removeFile(let path):
            return unlink(path) == 0 || errno == ENOENT ? nil : String(cString: strerror(errno))
        case .removeTree(let path):
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            do { try FileManager.default.removeItem(atPath: path) } catch { return "\(error.localizedDescription)" }
            return nil
        }
    }

    /// A root-owned file, replaced whole: written beside its place and
    /// renamed over it, so a running daemon never executes half a binary.
    private static func replaceFile(_ data: Data, at path: String, mode: mode_t) -> String? {
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        } catch { return "cannot create \(directory)" }
        let temporary = path + ".rv-new"
        _ = unlink(temporary)
        let fd = open(temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { return String(cString: strerror(errno)) }
        let written = data.withUnsafeBytes { bytes -> Bool in
            var sent = 0
            while sent < bytes.count {
                guard let base = bytes.baseAddress else { return false }
                let count = write(fd, base + sent, bytes.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
        let finished = written && fchmod(fd, mode) == 0 && fsync(fd) == 0
        close(fd)
        guard finished, rename(temporary, path) == 0 else {
            let failure = String(cString: strerror(errno))
            _ = unlink(temporary)
            return failure
        }
        return nil
    }
}

struct MCPCustodian: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "custodian",
        abstract: "Install or remove the approvals key custodian (Linux; needs root).",
        subcommands: [MCPCustodianInstall.self, MCPCustodianUninstall.self, MCPCustodianStatus.self],
        defaultSubcommand: MCPCustodianStatus.self)
}

struct MCPCustodianInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the custodian: a system account, two systemd services and a PAM service.")

    func run() async throws {
        let ctx = CommandContext.current(command: "mcp custodian install", json: false, robot: false, plain: true, noColor: true)
        #if os(Linux)
        switch MCPCustodianSetup.installPlan(MCPCustodianSetup.liveHost()) {
        case .failure(let refusal): try ctx.fail("rv mcp custodian install: \(refusal.message)\n")
        case .success(let steps):
            if let failure = MCPCustodianSetup.run(steps, log: { ctx.writeStdout("  \($0)\n") }) {
                try ctx.fail(
                    "rv mcp custodian install: stopped at \(failure). Run `sudo rv mcp custodian uninstall` to undo "
                        + "what was done\n")
            }
            ctx.writeStdout(
                "installed. MCP approvals and mcp.json trust are signed by the custodian from now on; signing asks "
                    + "for your login password. `rv mcp trust` signs your mcp.json with its key\n")
        }
        #else
        try ctx.fail("rv mcp custodian install: Linux only; on macOS the custodian is RVApprovals.app\n")
        #endif
    }
}

struct MCPCustodianUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "Remove the custodian. The keys stay unless --purge.")

    @Flag(help: "Also delete every account's approvals key and the custodian's account. Voids all grants and signatures.")
    var purge = false

    func run() async throws {
        let ctx = CommandContext.current(command: "mcp custodian uninstall", json: false, robot: false, plain: true, noColor: true)
        #if os(Linux)
        switch MCPCustodianSetup.uninstallPlan(MCPCustodianSetup.liveHost(), purge: purge) {
        case .failure(let refusal): try ctx.fail("rv mcp custodian uninstall: \(refusal.message)\n")
        case .success(let steps):
            if let failure = MCPCustodianSetup.run(steps, log: { ctx.writeStdout("  \($0)\n") }) {
                try ctx.fail("rv mcp custodian uninstall: stopped at \(failure)\n")
            }
            ctx.writeStdout(purge
                ? "removed, keys included\n"
                : "removed. The keys are kept in \(MCPCustodianSetup.state); --purge deletes them\n")
        }
        #else
        try ctx.fail("rv mcp custodian uninstall: Linux only\n")
        #endif
    }
}

struct MCPCustodianStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Say whether the custodian is installed and answering.")

    func run() async throws {
        let ctx = CommandContext.current(command: "mcp custodian status", json: false, robot: false, plain: true, noColor: true)
        #if os(Linux)
        ctx.writeStdout(MCPCustodianStatusText.describe(MCPCustodianSocketClient.shared) + "\n")
        #else
        ctx.writeStdout("the approvals custodian on macOS is RVApprovals.app; see `rv doctor`\n")
        #endif
    }
}

#if os(Linux)
enum MCPCustodianStatusText {
    static func describe(_ client: MCPCustodianSocketClient) -> String {
        guard client.isInstalled else {
            return "not installed: MCP approvals and mcp.json trust are unavailable. Install with "
                + "`sudo rv mcp custodian install`"
        }
        switch client.transport(scope: "/", terminal: { nil })(.status) {
        case .status(.enrolled)?: return "installed and answering; this account has an approvals key"
        case .status(.notEnrolled)?:
            return "installed and answering; this account has no approvals key yet (`rv mcp trust` makes one)"
        default:
            return "installed but not answering (systemctl status rv-mcp-custodian rv-mcp-presence)"
        }
    }
}
#endif
