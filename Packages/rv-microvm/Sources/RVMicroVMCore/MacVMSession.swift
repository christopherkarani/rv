import Foundation

/// How a guest command starts. TCC treats the workspace share as a network
/// volume, and an unattended guest can grant access to one only through
/// Remote Login: provisioning gives `sshd` Full Disk Access, while a
/// LaunchDaemon and everything it starts are denied. So the agent starts
/// each command with `ssh` to the guest's own `sshd` on loopback, as the
/// guest user, and `sshd` runs the agent's `session` verb, which applies
/// the request and runs the command under `sandbox-exec`.
///
/// The request travels in one environment value (`SendEnv`/`AcceptEnv`),
/// never in argv or on disk.
public enum MacVMSession {
    public static let verb = "session"
    public static let variable = "RV_MACVM_SESSION"
    /// Root-only key; its public half is the only key `sshd` accepts.
    public static let keyPath = "/var/root/.rv-macvm/session_key"
    /// The guest's own host key, pinned at prepare.
    public static let knownHostsPath = "/var/root/.rv-macvm/known_hosts"
    public static let authorizedKeysPath = "/etc/ssh/rv_macvm_authorized_keys"
    public static let sshdConfigPath = "/etc/ssh/sshd_config.d/000-rv-macvm.conf"
    /// The encoded request rides in one ssh environment request and then
    /// in `execve` of the session; both cap far below the frame limit.
    public static let maxEncodedBytes = 128 * 1024

    public static func encode(_ request: MacVMExecRequest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return ((try? encoder.encode(request)) ?? Data()).base64EncodedString()
    }

    public static func decode(_ value: String) -> MacVMExecRequest? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONDecoder().decode(MacVMExecRequest.self, from: data)
    }

    /// `profile` with a final rule that keeps the command away from `sshd`,
    /// whose sessions run outside the command's sandbox. Seatbelt applies
    /// the last matching rule, so no earlier allow can undo it.
    public static func guardedProfile(_ profile: String) -> String {
        let separator = profile.hasSuffix("\n") ? "" : "\n"
        return profile + separator + "(deny network-outbound (remote tcp \"localhost:22\"))\n"
    }

    /// The agent's `ssh` to the guest's `sshd`. `-e none`: host input never
    /// reaches ssh's escape commands.
    public static func sshArguments(terminal: Bool) -> [String] {
        [
            "/usr/bin/ssh", "-F", "/dev/null", "-e", "none", "-i", keyPath,
            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "SendEnv=\(variable)",
            "-o", "ControlMaster=no", "-o", "LogLevel=ERROR",
            terminal ? "-tt" : "-T", "\(MacVMAgent.user)@127.0.0.1",
        ]
    }

    /// Included before Apple's defaults, so its values win. Run boots have
    /// no network interface, so loopback is the only way in.
    public static var sshdConfiguration: String {
        """
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitRootLogin no
        AllowUsers \(MacVMAgent.user)@127.0.0.1
        AuthorizedKeysFile \(authorizedKeysPath)
        AcceptEnv \(variable)
        ForceCommand \(MacVMAgent.installedPath) \(verb)
        DisableForwarding yes
        PermitUserEnvironment no

        """
    }
}
