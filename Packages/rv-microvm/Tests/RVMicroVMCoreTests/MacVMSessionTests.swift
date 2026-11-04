import Foundation
import RVMicroVMCore
import Testing

@Suite("macOS guest sessions")
struct MacVMSessionTests {
    private let request = MacVMExecRequest(
        workspace: "/Users/me/app", arguments: ["/bin/sh", "-c", "echo 'quoted' \"$HOME\""],
        environment: ["PATH=/usr/bin:/bin", "TOKEN=s3cr=t"], terminal: true, rows: 30, columns: 100,
        relayPorts: [8080], sandboxProfile: "(version 1)\n(allow default)\n"
    )

    @Test("the request crosses sshd in one environment value and decodes exactly")
    func roundTrip() throws {
        let value = MacVMSession.encode(request)
        #expect(!value.contains("\n") && !value.contains(" "))
        #expect(MacVMSession.decode(value) == request)
        #expect(MacVMSession.decode("not base64!") == nil)
        #expect(MacVMSession.decode(Data("{}".utf8).base64EncodedString()) == nil)
    }

    /// A command must not reach sshd itself: sshd sessions run outside the
    /// command's sandbox (with Remote Login's disk access).
    @Test("every profile the session applies ends by denying sshd on loopback")
    func guardedProfile() {
        let profile = MacVMSession.guardedProfile("(version 1)\n(allow default)\n(allow network-outbound)\n")
        #expect(profile.hasPrefix("(version 1)\n(allow default)\n(allow network-outbound)\n"))
        #expect(profile.hasSuffix("(deny network-outbound (remote tcp \"localhost:22\"))\n"))
    }

    @Test("the agent's ssh never reads user config, never prompts, pins the host key, and has no escape character")
    func sshArguments() {
        for terminal in [true, false] {
            let arguments = MacVMSession.sshArguments(terminal: terminal)
            #expect(arguments.first == "/usr/bin/ssh")
            #expect(arguments.last == "\(MacVMAgent.user)@127.0.0.1")
            let joined = arguments.joined(separator: " ")
            for option in [
                "-F /dev/null", "-e none", "-i \(MacVMSession.keyPath)", "-o IdentitiesOnly=yes", "-o BatchMode=yes",
                "-o StrictHostKeyChecking=yes", "-o UserKnownHostsFile=\(MacVMSession.knownHostsPath)",
                "-o GlobalKnownHostsFile=/dev/null", "-o SendEnv=\(MacVMSession.variable)", "-o ControlMaster=no",
            ] {
                #expect(joined.contains(option), "\(option)")
            }
            #expect(arguments.contains(terminal ? "-tt" : "-T"))
        }
    }

    @Test("sshd accepts only the agent's key from loopback and always runs the session verb")
    func sshdConfiguration() {
        let config = MacVMSession.sshdConfiguration
        for line in [
            "PasswordAuthentication no", "KbdInteractiveAuthentication no", "PermitRootLogin no",
            "AllowUsers \(MacVMAgent.user)@127.0.0.1", "AuthorizedKeysFile \(MacVMSession.authorizedKeysPath)",
            "AcceptEnv \(MacVMSession.variable)", "ForceCommand \(MacVMAgent.installedPath) \(MacVMSession.verb)",
            "DisableForwarding yes", "PermitUserEnvironment no",
        ] {
            #expect(config.contains(line + "\n"), "\(line)")
        }
    }
}
