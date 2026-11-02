import Foundation
import Testing
@testable import RVMicroVMCore

private func request(
    workspace: String = "/Users/dev/project",
    arguments: [String] = ["/bin/sh", "-c", "true"],
    environment: [String] = ["PATH=/usr/bin:/bin"],
    relayPorts: [Int] = [],
    profile: String = "(version 1)\n(allow default)\n"
) -> MacVMExecRequest {
    MacVMExecRequest(
        workspace: workspace, arguments: arguments, environment: environment,
        terminal: true, rows: 24, columns: 80, relayPorts: relayPorts, sandboxProfile: profile
    )
}

@Suite("macOS guest agent protocol")
struct MacVMProtocolTests {
    @Test("every frame round-trips, also when bytes arrive one at a time")
    func roundTrip() throws {
        let frames: [MacVMFrame] = [
            .exec(request()), .input(Data("ls\n".utf8)), .input(Data()), .resize(rows: 50, columns: 132),
            .signal(SIGTERM), .started, .output(Data([0, 255, 10])), .errorOutput(Data("oops".utf8)),
            .exit(7), .failure("mount failed"),
        ]
        let wire = frames.reduce(into: Data()) { $0.append($1.encoded()) }
        var whole = MacVMFrameDecoder()
        whole.append(wire)
        var decoded: [MacVMFrame] = []
        while let frame = try whole.next() { decoded.append(frame) }
        #expect(decoded == frames)

        var trickle = MacVMFrameDecoder()
        var trickled: [MacVMFrame] = []
        for byte in wire {
            trickle.append(Data([byte]))
            while let frame = try trickle.next() { trickled.append(frame) }
        }
        #expect(trickled == frames)
    }

    @Test("an oversized length is refused before buffering the payload")
    func oversized() {
        var decoder = MacVMFrameDecoder()
        var header = Data([MacVMFrame.Kind.output.rawValue])
        withUnsafeBytes(of: UInt32(MacVMFrame.maxPayloadBytes + 1).bigEndian) { header.append(contentsOf: $0) }
        decoder.append(header)
        #expect(throws: MacVMProtocolError.oversized(MacVMFrame.maxPayloadBytes + 1)) { try decoder.next() }
    }

    @Test("unknown kinds and malformed payloads are refused")
    func malformed() {
        var unknown = MacVMFrameDecoder()
        unknown.append(Data([99, 0, 0, 0, 0]))
        #expect(throws: MacVMProtocolError.unknownKind(99)) { try unknown.next() }

        var shortResize = MacVMFrameDecoder()
        shortResize.append(Data([MacVMFrame.Kind.resize.rawValue, 0, 0, 0, 1, 0]))
        #expect(throws: MacVMProtocolError.malformed("resize")) { try shortResize.next() }

        var badExec = MacVMFrameDecoder()
        badExec.append(Data([MacVMFrame.Kind.exec.rawValue, 0, 0, 0, 2]) + Data("{}".utf8))
        #expect(throws: MacVMProtocolError.malformed("exec")) { try badExec.next() }
    }

    @Test("a valid exec request passes")
    func validExec() {
        #expect(request(relayPorts: [8080, 9000]).validated() == nil)
        // The private volume mounts at the project's own path, wherever it is.
        for path in ["/Users/me/code/app", "/Volumes/Work/app", "/private/var/folders/x/T/ws", "/opt/src/app", "/Users/me/Library-tools", "/Users/rvx/app"] {
            #expect(request(workspace: path).validated() == nil, "\(path)")
        }
        // The command applies its own environment as the guest user.
        #expect(request(environment: ["DYLD_LIBRARY_PATH=/opt/lib"]).validated() == nil)
    }

    @Test("exec requests the agent must refuse", arguments: [
        (request(workspace: "relative"), "workspace"),
        (request(workspace: "/"), "workspace"),
        (request(workspace: "/usr/local/libexec"), "system"),
        (request(workspace: "/Library/LaunchDaemons"), "system"),
        (request(workspace: "/private/etc/sudoers.d"), "system"),
        (request(workspace: "/System"), "system"),
        // Mounting over a parent hides every system directory under it.
        (request(workspace: "/private"), "system"),
        (request(workspace: "/var"), "system"),
        (request(workspace: "/private/var"), "system"),
        (request(workspace: "/Users"), "system"),
        (request(workspace: "/Users/rv"), "system"),
        (request(workspace: "/Users/rv/project"), "system"),
        // The guest volume is case-insensitive.
        (request(workspace: "/ETC/x"), "system"),
        (request(workspace: "/library/LaunchDaemons"), "system"),
        // Only canonical paths: no empty or `.` components, no trailing `/`.
        (request(workspace: "//etc/x"), "workspace"),
        (request(workspace: "/./etc/x"), "workspace"),
        (request(workspace: "/Users/me/app/"), "workspace"),
        (request(workspace: "/Users/me/../../etc"), "workspace"),
        (request(arguments: []), "arguments"),
        (request(arguments: ["sh"]), "arguments"),
        (request(arguments: ["/bin/sh", "a\0b"]), "NUL"),
        (request(environment: ["NOEQUALS"]), "environment"),
        (request(environment: ["1BAD=x"]), "environment"),
        // ssh and execve cannot carry more; refuse it up front.
        (request(environment: ["BIG=" + String(repeating: "x", count: 200_000)]), "too large"),
        (request(relayPorts: [0]), "relay"),
        (request(relayPorts: [80, 80]), "relay"),
        (request(relayPorts: Array(1...9)), "relay"),
        (request(profile: ""), "sandbox"),
    ])
    func invalidExec(candidate: MacVMExecRequest, mentions: String) throws {
        let problem = try #require(candidate.validated())
        #expect(problem.contains(mentions), "\(problem)")
    }
}

@Suite("macOS guest images")
struct MacVMImageTests {
    @Test("image names are short lowercase slugs", arguments: [
        ("dev", true), ("xcode-26", true), ("a", true),
        ("", false), ("-dev", false), ("Dev", false), ("dev/../x", false), ("dev.img", false),
        (String(repeating: "a", count: 64), false),
    ])
    func names(name: String, valid: Bool) {
        #expect((MacVMImageName.validate(name) != nil) == valid)
    }

    @Test("layout keeps each image's files together and runs apart")
    func layout() throws {
        let layout = MacVMLayout(root: URL(fileURLWithPath: "/state/macvm"))
        let name = try #require(MacVMImageName.validate("dev"))
        #expect(layout.disk(name).path == "/state/macvm/images/dev/disk.img")
        #expect(layout.auxiliaryStorage(name).path == "/state/macvm/images/dev/aux.img")
        #expect(layout.record(name).path == "/state/macvm/images/dev/image.json")
        #expect(layout.runs.path == "/state/macvm/runs")
    }

    @Test("the image record round-trips and refuses unknown versions")
    func record() throws {
        let record = MacVMImageRecord(
            hardwareModel: Data([1, 2, 3]), osVersion: "27.2", osBuild: "26B123",
            agentSHA256: String(repeating: "a", count: 64), user: "rv"
        )
        let decoded = try JSONDecoder().decode(MacVMImageRecord.self, from: try JSONEncoder().encode(record))
        #expect(decoded == record)
        let future = Data(#"{"version":2,"hardwareModel":"AQID","osVersion":"27.2","osBuild":"x","agentSHA256":"a","user":"rv"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MacVMImageRecord.self, from: future) }
    }

    @Test("an image whose agent is not this rv's says how to update it")
    func staleAgent() throws {
        let name = try #require(MacVMImageName.validate("dev"))
        let record = MacVMImageRecord(
            hardwareModel: Data([1]), osVersion: "27.2", osBuild: "26B123",
            agentSHA256: String(repeating: "a", count: 64), user: "rv"
        )
        #expect(record.agentUpdateNote(image: name, currentAgentSHA256: String(repeating: "a", count: 64)) == nil)
        let note = try #require(record.agentUpdateNote(image: name, currentAgentSHA256: String(repeating: "b", count: 64)))
        #expect(note.contains("rv-macvm prepare --image dev --replace"), "\(note)")
    }

    @Test("run options accept an image name instead of an OCI reference")
    func runOptions() throws {
        let options = try RunOptions.validate(
            root: "/state", image: "dev", workspace: "/w", cpus: 4, memoryMiB: 8192,
            relayPorts: [8080], forwardedEnvironment: ["TOKEN"], command: ["/usr/bin/xcodebuild"],
            handshakeDescriptor: nil, nonce: nil, hostCPUs: 8, hostMemoryMiB: 16384,
            imageNormalizer: MacVMImageName.normalize, minimumMemoryMiB: MacVMRun.minimumMemoryMiB
        ).get()
        #expect(options.image == "dev")
        let small = RunOptions.validate(
            root: "/state", image: "dev", workspace: "/w", cpus: 4, memoryMiB: 2048,
            relayPorts: [], forwardedEnvironment: [], command: ["/bin/sh"],
            handshakeDescriptor: nil, nonce: nil, hostCPUs: 8, hostMemoryMiB: 16384,
            imageNormalizer: MacVMImageName.normalize, minimumMemoryMiB: MacVMRun.minimumMemoryMiB
        )
        guard case .failure(.memoryOutOfRange) = small else {
            Issue.record("2 GiB is below the macOS guest minimum: \(small)")
            return
        }
    }

    @Test("the macOS guest environment uses macOS defaults and forwarded values win")
    func environment() {
        let env = GuestEnvironment.macOS(
            forwarded: ["TOKEN", "PATH", "MISSING"],
            host: ["RV_GUEST_TOKEN": "t", "RV_GUEST_PATH": "/opt/bin", "TOKEN": "host-copy"],
            terminal: true
        )
        #expect(env.contains("TOKEN=t"))
        #expect(env.contains("PATH=/opt/bin"))
        #expect(env.contains("HOME=/Users/\(MacVMAgent.user)"))
        #expect(env.contains("USER=\(MacVMAgent.user)"))
        #expect(env.contains("TERM=xterm-256color"))
        #expect(env.filter { $0.hasPrefix("PATH=") }.count == 1)
        #expect(env.contains { $0.hasPrefix("MISSING=") } == false)
    }
}

@Suite("macOS guest host helpers")
struct MacVMHostHelperTests {
    /// The installer VM's service can hold the auxiliary storage's lock for
    /// a moment after the install finishes.
    @Test("only a storage lock that is still held is worth retrying a boot for")
    func storageLocked() {
        let eagain = NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
        let locked = NSError(domain: "VZErrorDomain", code: 2, userInfo: [NSUnderlyingErrorKey: eagain])
        #expect(MacVMSetup.isStorageStillLocked(locked))
        #expect(!MacVMSetup.isStorageStillLocked(NSError(domain: "VZErrorDomain", code: 2)))
        let other = NSError(domain: "VZErrorDomain", code: 2, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))])
        #expect(!MacVMSetup.isStorageStillLocked(other))
        #expect(!MacVMSetup.isStorageStillLocked(NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))))
    }

    /// ssh runs `SSH_ASKPASS` with only the prompt as its argument.
    @Test("askpass answers whatever prompt ssh passes, only when rv-macvm set the password")
    func askpass() {
        let env = [MacVMSetup.askpassVariable: "s3cret"]
        #expect(MacVMSetup.askpassReply(environment: env) == "s3cret")
        #expect(MacVMSetup.askpassReply(environment: [:]) == nil)
        #expect(MacVMSetup.askpassReply(environment: [MacVMSetup.askpassVariable: ""]) == nil)
    }

    @Test("DHCP leases match a MAC whatever its leading zeros")
    func leases() {
        let leases = """
        {
        \tname=other
        \tip_address=192.168.64.2
        \thw_address=1,aa:bb:cc:dd:ee:ff
        \tlease=0x6a0f0000
        }
        {
        \tname=rv
        \tip_address=192.168.64.7
        \thw_address=1,6e:3:a:0:1b:c
        \tlease=0x6a0f0001
        }
        """
        #expect(DHCPLeases.address(forMAC: "6e:03:0a:00:1b:0c", in: leases) == "192.168.64.7")
        #expect(DHCPLeases.address(forMAC: "AA:BB:CC:DD:EE:FF", in: leases) == "192.168.64.2")
        #expect(DHCPLeases.address(forMAC: "11:22:33:44:55:66", in: leases) == nil)
    }

    @Test("run directories are owned by a pid; only dead owners are swept")
    func runOwner() {
        #expect(MacVMRunDirectory.owner(of: "4242-5f3a") == 4242)
        #expect(MacVMRunDirectory.owner(of: "x-1") == nil)
        #expect(MacVMRunDirectory.owner(of: "-1") == nil)
        let name = MacVMRunDirectory.name(pid: 77)
        #expect(MacVMRunDirectory.owner(of: name) == 77)
        #expect(MacVMRunDirectory.stale(["1-a", "2-b", "junk", "3-c"], isAlive: { $0 == 2 }) == ["1-a", "3-c"])
    }

    @Test("the setup script installs the agent daemon from the setup share and reports its hash")
    func setupScript() {
        let script = MacVMSetup.script
        #expect(script.hasPrefix("set -eu\n"))
        #expect(script.contains("mount_virtiofs -r \(MacVMAgent.setupTag) "))
        #expect(script.contains(MacVMAgent.installedPath))
        #expect(script.contains("/Library/LaunchDaemons/\(MacVMAgent.launchDaemonLabel).plist"))
        // Remote Login stays on: sshd is how commands reach the workspace.
        #expect(!script.contains("com.openssh.sshd"))
        #expect(script.contains("/sbin/shutdown -h now"))
        // Commands start through sshd with a root-only key and a pinned host key.
        #expect(script.contains("ssh-keygen -q -t ed25519 -N '' -C rv-macvm-agent -f \(MacVMSession.keyPath)"))
        #expect(script.contains("install -o root -g wheel -m 644 \(MacVMSession.keyPath).pub \(MacVMSession.authorizedKeysPath)"))
        #expect(script.contains("> \(MacVMSession.knownHostsPath)"))
        #expect(script.contains("cat > \(MacVMSession.sshdConfigPath) <<'RVSSHD'\n\(MacVMSession.sshdConfiguration)RVSSHD\n"))
        #expect(script.contains("/usr/sbin/sshd -t"))
        #expect(!script.contains("TCC.db"))
        // It reaches the guest only after a 25 GB install: parse it here.
        let parse = Process()
        parse.executableURL = URL(fileURLWithPath: "/bin/sh")
        parse.arguments = ["-n"]
        let input = Pipe()
        parse.standardInput = input
        #expect((try? parse.run()) != nil)
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        parse.waitUntilExit()
        #expect(parse.terminationStatus == 0)
        #expect(script.contains(MacVMSetup.successMarker))
        let plist = MacVMSetup.launchDaemonPlist
        #expect(plist.contains("<string>\(MacVMAgent.launchDaemonLabel)</string>"))
        #expect(plist.contains("<string>\(MacVMAgent.installedPath)</string>"))
        #expect(plist.contains("<key>KeepAlive</key>"))
        #expect(MacVMSetup.agentHash(fromOutput: "noise\n\(MacVMSetup.successMarker) \(String(repeating: "b", count: 64))\n")
            == String(repeating: "b", count: 64))
        #expect(MacVMSetup.agentHash(fromOutput: "no marker") == nil)
    }

    @Test("the exec request carries the macOS environment, relays and profile")
    func execRequest() throws {
        let options = try RunOptions.validate(
            root: "/state", image: "dev", workspace: "/Users/dev/p", cpus: 4, memoryMiB: 8192,
            relayPorts: [8080], forwardedEnvironment: ["TOKEN"], command: ["/usr/bin/swift", "build"],
            handshakeDescriptor: nil, nonce: nil, hostCPUs: 8, hostMemoryMiB: 16384,
            imageNormalizer: MacVMImageName.normalize, minimumMemoryMiB: MacVMRun.minimumMemoryMiB
        ).get()
        let request = MacVMExecRequest.make(
            options, host: ["RV_GUEST_TOKEN": "t"], terminalSize: (40, 120), profile: "(version 1)"
        )
        #expect(request.arguments == ["/usr/bin/swift", "build"])
        #expect(request.workspace == "/Users/dev/p")
        #expect(request.terminal && request.rows == 40 && request.columns == 120)
        #expect(request.relayPorts == [8080])
        #expect(request.environment.contains("TOKEN=t"))
        #expect(request.validated() == nil)
        let piped = MacVMExecRequest.make(options, host: [:], terminalSize: nil, profile: "(version 1)")
        #expect(piped.terminal == false)
        #expect(piped.environment.contains { $0.hasPrefix("TERM=") } == false)
    }
}
