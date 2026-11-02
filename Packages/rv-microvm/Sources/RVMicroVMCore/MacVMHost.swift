import Foundation

/// `/var/db/dhcpd_leases` lookup for the setup boot, the only boot with a
/// network device. macOS writes MAC octets without leading zeros.
public enum DHCPLeases {
    public static let path = "/var/db/dhcpd_leases"

    public static func address(forMAC mac: String, in leases: String) -> String? {
        let wanted = canonical(mac)
        var address: String?
        var hardware: String?
        for line in leases.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line == "{" {
                address = nil
                hardware = nil
            } else if line.hasPrefix("ip_address=") {
                address = String(line.dropFirst("ip_address=".count))
            } else if line.hasPrefix("hw_address=") {
                hardware = line.dropFirst("hw_address=".count).split(separator: ",", maxSplits: 1).last.map(String.init)
            } else if line == "}", let hardware, canonical(hardware) == wanted, let address {
                return address
            }
        }
        return nil
    }

    private static func canonical(_ mac: String) -> [UInt8?] {
        mac.split(separator: ":").map { UInt8($0, radix: 16) }
    }
}

/// `runs/<pid>-<suffix>`: one clone per `rv-macvm run`, owned by that pid.
public enum MacVMRunDirectory {
    public static func name(pid: Int32) -> String {
        "\(pid)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    public static func owner(of name: String) -> Int32? {
        guard let dash = name.firstIndex(of: "-") else { return nil }
        return Int32(name[..<dash]).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Directories whose owning process is gone (a SIGKILLed run).
    public static func stale(_ names: [String], isAlive: (Int32) -> Bool) -> [String] {
        names.filter { name in owner(of: name).map { isAlive($0) == false } ?? false }
    }
}

/// The one-time setup `prepare` runs as root over SSH: install the agent
/// daemon from the read-only setup share, quiet the guest, close SSH.
public enum MacVMSetup {
    /// Set only in the environment of `prepare`'s ssh child, which passes it
    /// to `SSH_ASKPASS` (rv-macvm itself).
    public static let askpassVariable = "RV_MACVM_ASKPASS"

    /// The password to print when rv-macvm runs as `SSH_ASKPASS`. ssh passes
    /// only its prompt as the argument, so this keys on the environment.
    public static func askpassReply(environment: [String: String]) -> String? {
        guard let password = environment[askpassVariable], !password.isEmpty else { return nil }
        return password
    }

    /// A start that failed because another VM service still holds the disk
    /// or auxiliary storage lock (`VZErrorDomain` over `EAGAIN`).
    public static func isStorageStillLocked(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == "VZErrorDomain",
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        else { return false }
        return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EAGAIN)
    }

    public static let successMarker = "rv-macvm-setup-ok"
    public static let mountPoint = "/Volumes/rvsetup"
    public static let plistName = "\(MacVMAgent.launchDaemonLabel).plist"

    public static var script: String {
        let plist = "/Library/LaunchDaemons/\(plistName)"
        return """
        set -eu
        mkdir -p \(mountPoint)
        mount_virtiofs -r \(MacVMAgent.setupTag) \(mountPoint)
        install -d -o root -g wheel -m 755 /usr/local/libexec
        install -o root -g wheel -m 755 \(mountPoint)/\(MacVMAgent.executableName) \(MacVMAgent.installedPath)
        install -o root -g wheel -m 644 \(mountPoint)/\(plistName) \(plist)
        umount \(mountPoint)
        \(sessionSetup)
        launchctl bootstrap system \(plist)
        mdutil -a -i off >/dev/null 2>&1 || true
        pmset -a sleep 0 displaysleep 0 disksleep 0 >/dev/null 2>&1 || true
        softwareupdate --schedule off >/dev/null 2>&1 || true
        echo "\(successMarker) $(shasum -a 256 \(MacVMAgent.installedPath) | cut -d ' ' -f 1)"
        # Password logins are now off, so the guest shuts itself down once
        # this session has reported.
        nohup /bin/sh -c 'sleep 3; /sbin/shutdown -h now' </dev/null >/dev/null 2>&1 &

        """
    }

    /// The agent's sessions through the guest's own `sshd` (see
    /// `MacVMSession`): a root-only key, the guest's host key pinned for
    /// it, and an `sshd` drop-in that accepts only that key from loopback
    /// and always runs the session verb. Remote Login stays on: it is what
    /// gives `sshd`, and so the command, access to the workspace share.
    static var sessionSetup: String {
        let directory = (MacVMSession.keyPath as NSString).deletingLastPathComponent
        return """
        install -d -o root -g wheel -m 700 \(directory)
        rm -f \(MacVMSession.keyPath) \(MacVMSession.keyPath).pub
        ssh-keygen -q -t ed25519 -N '' -C rv-macvm-agent -f \(MacVMSession.keyPath)
        chmod 600 \(MacVMSession.keyPath)
        install -o root -g wheel -m 644 \(MacVMSession.keyPath).pub \(MacVMSession.authorizedKeysPath)
        rm -f \(MacVMSession.keyPath).pub
        echo "127.0.0.1 $(cut -d ' ' -f 1,2 /etc/ssh/ssh_host_ed25519_key.pub)" > \(MacVMSession.knownHostsPath)
        chmod 600 \(MacVMSession.knownHostsPath)
        cat > \(MacVMSession.sshdConfigPath) <<'RVSSHD'
        \(MacVMSession.sshdConfiguration)RVSSHD
        chmod 644 \(MacVMSession.sshdConfigPath)
        /usr/sbin/sshd -t
        """
    }

    public static var launchDaemonPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(MacVMAgent.launchDaemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(MacVMAgent.installedPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>/var/log/rv-macvm-agent.log</string>
        </dict>
        </plist>

        """
    }

    /// The agent sha256 the script printed after the marker.
    public static func agentHash(fromOutput output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix(successMarker + " ") {
            let hash = line.dropFirst(successMarker.count + 1).trimmingCharacters(in: .whitespaces)
            if hash.count == 64, hash.allSatisfy(\.isHexDigit) { return hash.lowercased() }
        }
        return nil
    }
}

extension MacVMExecRequest {
    /// The request `rv-macvm run` sends: macOS defaults plus the values rv
    /// forwarded as `RV_GUEST_<NAME>`. A nil size means no terminal.
    public static func make(
        _ options: RunOptions,
        host: [String: String],
        terminalSize: (rows: UInt16, columns: UInt16)?,
        profile: String
    ) -> MacVMExecRequest {
        MacVMExecRequest(
            workspace: options.workspace,
            arguments: options.command,
            environment: GuestEnvironment.macOS(
                forwarded: options.forwardedEnvironment, host: host, terminal: terminalSize != nil
            ),
            terminal: terminalSize != nil,
            rows: terminalSize?.rows ?? 0,
            columns: terminalSize?.columns ?? 0,
            relayPorts: options.relayPorts,
            sandboxProfile: profile
        )
    }
}
