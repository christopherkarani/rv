import Foundation
import RVDomain
import Testing
@testable import RVIsolation

@Suite("Micro-VM launch")
struct MicroVMLaunchTests {
    private let command = IsolatedCommand(executable: "/bin/sh", arguments: ["-c", "echo hi"])!

    @Test("options validate image, cpus and memory")
    func optionsValidate() {
        #expect(MicroVMLaunchOptions(image: "alpine:3.20") != nil)
        #expect(MicroVMLaunchOptions(image: "ghcr.io/org/tool@sha256:" + String(repeating: "a", count: 64), cpus: 4, memoryMiB: 4096) != nil)
        #expect(MicroVMLaunchOptions(image: "") == nil)
        #expect(MicroVMLaunchOptions(image: "a b") == nil)
        #expect(MicroVMLaunchOptions(image: "-flag") == nil)
        #expect(MicroVMLaunchOptions(image: String(repeating: "a", count: 513)) == nil)
        #expect(MicroVMLaunchOptions(image: "alpine", cpus: 0) == nil)
        #expect(MicroVMLaunchOptions(image: "alpine", cpus: 65) == nil)
        #expect(MicroVMLaunchOptions(image: "alpine", memoryMiB: 255) == nil)
    }

    @Test("options decode strictly")
    func optionsDecode() throws {
        let decoder = JSONDecoder()
        let good = try decoder.decode(MicroVMLaunchOptions.self, from: Data(#"{"image":"alpine","cpus":2}"#.utf8))
        #expect(good == MicroVMLaunchOptions(image: "alpine", cpus: 2))
        #expect(throws: DecodingError.self) {
            try decoder.decode(MicroVMLaunchOptions.self, from: Data(#"{"image":"alpine","extra":1}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(MicroVMLaunchOptions.self, from: Data(#"{"image":"alpine","cpus":0}"#.utf8))
        }
    }

    @Test("contained prepare yields a micro-VM request pinned to the resolved workspace")
    func prepareContained() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let options = try #require(MicroVMLaunchOptions(image: "alpine:3.20"))
        let request = try prepareMicroVM(tree.contained, command, options: options).get()
        let resolved = posixRealpath(tree.workspaceURL.path) ?? tree.workspaceURL.path
        #expect(request.family == .microvm)
        #expect(request.containedWorkspacePath == resolved)
        #expect(request.microVMProfile == MicroVMProfile(workspacePath: resolved, options: options))
        #expect(request.seatbeltProfile == nil)
        #expect(request.legacyAgentIntegration == false)
    }

    @Test("non-contained plans are refused")
    func prepareObserved() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let options = try #require(MicroVMLaunchOptions(image: "alpine"))
        #expect(throws: IsolationApplyError.profileNotApplicable) {
            try prepareMicroVM(tree.observed, command, options: options).get()
        }
    }

    @Test("resource profiles that grant host paths are refused before anything runs")
    func refusesHostPathGrants() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let options = try #require(MicroVMLaunchOptions(image: "alpine"))
        let grants: [RuntimeResourceProfile] = [
            RuntimeResourceProfile(id: "r", projects: [], readFiles: ["/etc/hosts"]),
            RuntimeResourceProfile(id: "t", projects: [], readTrees: ["/usr/share"]),
            RuntimeResourceProfile(id: "w", projects: [], writeTrees: ["/tmp"]),
            RuntimeResourceProfile(
                id: "c", projects: [],
                credentials: [.init(source: "/x", destination: ".x")]
            ),
            RuntimeResourceProfile(
                id: "l", projects: [],
                executableLinks: [.init(name: "tool", target: "/usr/bin/true")]
            ),
        ]
        for profile in grants {
            switch prepareMicroVM(tree.contained, command, options: options, resourceProfile: profile) {
            case .success:
                Issue.record("profile \(profile.id) must be refused")
            case .failure(let error):
                guard case .resourceStagingFailed(let detail) = error else {
                    Issue.record("profile \(profile.id): \(error)")
                    continue
                }
                #expect(detail.contains(profile.id))
                #expect(detail.contains("/") == false, "detail must not echo host paths: \(detail)")
            }
        }
    }

    @Test("environment and secrets profiles are allowed")
    func allowsEnvironmentProfiles() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let options = try #require(MicroVMLaunchOptions(image: "alpine"))
        let profile = RuntimeResourceProfile(
            id: "env", projects: [],
            environment: [.init(name: "MODE", literalValue: "ci")],
            secrets: ["API_TOKEN"]
        )
        let request = try prepareMicroVM(tree.contained, command, options: options, resourceProfile: profile).get()
        #expect(request.resources?.profile == profile)
    }

    @Test("spawn argv for a terminal launch runs rv-microvm under the claim helper")
    func spawnCommandTerminal() throws {
        let options = try #require(MicroVMLaunchOptions(image: "alpine:3.20", cpus: 4, memoryMiB: 4096))
        let spawn = microVMSpawnCommand(
            helper: "/opt/rv/rv-microvm",
            claim: (path: "/opt/rv/rv-pty-claim", slave: "/dev/ttys009"),
            profile: MicroVMProfile(workspacePath: "/Volumes/ws/project", options: options),
            stateRoot: "/Users/dev/.config/rv/microvm",
            relayPorts: [41000, 41001],
            forwardedNames: ["HTTPS_PROXY", "API_TOKEN"],
            nonce: "abc123",
            command: command
        )
        #expect(spawn.path == "/opt/rv/rv-pty-claim")
        #expect(spawn.arguments == [
            "/opt/rv/rv-pty-claim", "/dev/ttys009", "/opt/rv/rv-microvm", "run",
            "--root", "/Users/dev/.config/rv/microvm",
            "--image", "alpine:3.20",
            "--workspace", "/Volumes/ws/project",
            "--cpus", "4", "--memory-mib", "4096",
            "--relay-port", "41000", "--relay-port", "41001",
            "--forward-env", "HTTPS_PROXY", "--forward-env", "API_TOKEN",
            "--handshake-fd", "3", "--nonce", "abc123",
            "--", "/bin/sh", "-c", "echo hi",
        ])
    }

    @Test("spawn argv without a terminal starts rv-microvm directly and omits unset sizes")
    func spawnCommandDiscard() throws {
        let options = try #require(MicroVMLaunchOptions(image: "alpine"))
        let spawn = microVMSpawnCommand(
            helper: "/opt/rv/rv-microvm", claim: nil,
            profile: MicroVMProfile(workspacePath: "/w", options: options),
            stateRoot: "/s", relayPorts: [], forwardedNames: [], nonce: "n", command: command
        )
        #expect(spawn.path == "/opt/rv/rv-microvm")
        #expect(spawn.arguments == [
            "/opt/rv/rv-microvm", "run", "--root", "/s", "--image", "alpine", "--workspace", "/w",
            "--handshake-fd", "3", "--nonce", "n", "--", "/bin/sh", "-c", "echo hi",
        ])
    }

    #if os(macOS)
    @Test("guest values travel in the helper environment, never argv, and host secrets stay behind")
    func runtimeEnvironment() throws {
        let profile = RuntimeResourceProfile(
            id: "env", projects: [],
            environment: [
                .init(name: "MODE", literalValue: "ci"),
                .init(name: "REGION", hostVariable: "AWS_REGION"),
                .init(name: "PATH", literalValue: "/evil"),
            ]
        )
        let built = microVMRuntimeEnvironment(
            hostEnvironment: [
                "HOME": "/Users/dev", "PATH": "/opt/homebrew/bin:/usr/bin",
                "AWS_REGION": "eu-west-1", "AWS_SECRET_ACCESS_KEY": "host-secret",
            ],
            resources: RuntimeResourceManifest(profile),
            egressProxyPort: 41000,
            egressProxyCredential: EgressProxyCredential(rawValue: "cafe01"),
            keychain: [
                (name: "API_TOKEN", value: "tok"),
                (name: "HOME", value: "/nope"),
                (name: "EXTRA_PROXY", value: "x"),
            ]
        )
        let entries = Dictionary(uniqueKeysWithValues: built.environment.map { entry -> (String, String) in
            let parts = entry.split(separator: "=", maxSplits: 1)
            return (String(parts[0]), String(parts[1]))
        })
        #expect(entries["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(entries["HOME"] == "/Users/dev")
        #expect(entries["RV_GUEST_HTTPS_PROXY"] == "http://cafe01@127.0.0.1:41000")
        #expect(entries["RV_GUEST_MODE"] == "ci")
        #expect(entries["RV_GUEST_REGION"] == "eu-west-1")
        #expect(entries["RV_GUEST_API_TOKEN"] == "tok")
        #expect(entries["RV_GUEST_AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(entries["RV_GUEST_EXTRA_PROXY"] == nil)
        // Guest values never steer the entitled helper under their own names.
        #expect(Set(entries.keys) == [
            "PATH", "HOME", "RV_GUEST_HTTPS_PROXY", "RV_GUEST_HTTP_PROXY", "RV_GUEST_https_proxy",
            "RV_GUEST_http_proxy", "RV_GUEST_NO_PROXY", "RV_GUEST_no_proxy",
            "RV_GUEST_MODE", "RV_GUEST_REGION", "RV_GUEST_API_TOKEN",
        ])
        #expect(Set(built.forwardedNames) == [
            "HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy", "NO_PROXY", "no_proxy",
            "MODE", "REGION", "API_TOKEN",
        ])
        #expect(built.forwardedNames.contains("PATH") == false)
        #expect(built.forwardedNames.contains("HOME") == false)
    }

    @Test("a staged secret replaces a profile value of the same name, as in the Seatbelt cage")
    func stagedSecretWins() {
        let profile = RuntimeResourceProfile(
            id: "secret-shadow", projects: [],
            environment: [.init(name: "ANTHROPIC_API_KEY", hostVariable: "ANTHROPIC_API_KEY")]
        )
        let built = microVMRuntimeEnvironment(
            hostEnvironment: ["HOME": "/h", "ANTHROPIC_API_KEY": "real-host-key"],
            resources: RuntimeResourceManifest(profile),
            egressProxyPort: nil, egressProxyCredential: nil,
            keychain: [(name: "ANTHROPIC_API_KEY", value: "rv-placeholder")]
        )
        #expect(built.environment.filter { $0.hasPrefix("RV_GUEST_ANTHROPIC_API_KEY=") } == [
            "RV_GUEST_ANTHROPIC_API_KEY=rv-placeholder",
        ])
        #expect(built.forwardedNames == ["ANTHROPIC_API_KEY"])
        #expect(built.environment.contains { $0.contains("real-host-key") } == false)
    }

    @Test("no proxy port means no proxy variables (fail closed)")
    func noProxyWithoutPort() {
        let built = microVMRuntimeEnvironment(
            hostEnvironment: ["HOME": "/h"], resources: nil,
            egressProxyPort: nil, egressProxyCredential: nil, keychain: []
        )
        #expect(built.forwardedNames.isEmpty)
        #expect(built.environment.contains { $0.contains("PROXY=") } == false)
    }

    #endif

    @Test("state root lives under the rv config directory")
    func stateRoot() {
        #expect(MicroVMHelper.stateRoot(home: "/Users/dev") == "/Users/dev/.config/rv/microvm")
    }

    @Test("established micro-VM runs report their session")
    func establishedSession() {
        let session = RuntimeSession(
            id: RuntimeSessionID(), workspaceSessionID: WorkspaceSessionID(), host: nil,
            workspace: WorkingDirectory(validating: "/w")!, backend: .microvm,
            startedAt: Date(), child: nil
        )
        let result = IsolatedRunResult(established: .microvm(session), exitStatus: 0)
        #expect(result.session == session)
    }
}

@Suite("Micro-VM control placeholders")
struct MicroVMControlPlaceholderTests {
    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mvm-ph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exists(_ url: URL, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(relative).path)
    }

    @Test("a plain folder gets empty .git, .rv and .config placeholders, removed after the last run")
    func plainFolder() throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let registry = MicroVMControlPlaceholders()
        try registry.acquire(workspace: ws.path).get()
        #expect(exists(ws, ".git") && exists(ws, ".rv") && exists(ws, ".config"))
        // Children are not needed: an empty placeholder is mounted read-only whole.
        #expect(exists(ws, ".git/hooks") == false && exists(ws, ".config/rv") == false)
        try registry.acquire(workspace: ws.path).get()
        registry.release(workspace: ws.path)
        #expect(exists(ws, ".rv"), "a second run still holds the placeholders")
        registry.release(workspace: ws.path)
        #expect(exists(ws, ".git") == false && exists(ws, ".rv") == false && exists(ws, ".config") == false)
    }

    @Test("a repo gets only the missing children, and real paths are never touched")
    func repo() throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let fm = FileManager.default
        try fm.createDirectory(at: ws.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: ws.appendingPathComponent(".config/nvim"), withIntermediateDirectories: true)
        let registry = MicroVMControlPlaceholders()
        try registry.acquire(workspace: ws.path).get()
        #expect(exists(ws, ".git/hooks") && exists(ws, ".git/config") && exists(ws, ".config/rv") && exists(ws, ".rv"))
        registry.release(workspace: ws.path)
        #expect(exists(ws, ".git/hooks") == false && exists(ws, ".git/config") == false)
        #expect(exists(ws, ".config/rv") == false && exists(ws, ".rv") == false)
        #expect(exists(ws, ".git/objects") && exists(ws, ".config/nvim"))
    }

    @Test("two acquires on a plain folder leave .git empty with no children")
    func secondAcquireKeepsEmptyGitEmpty() throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let registry = MicroVMControlPlaceholders()
        try registry.acquire(workspace: ws.path).get()
        try registry.acquire(workspace: ws.path).get()
        #expect(exists(ws, ".git") && exists(ws, ".config"))
        #expect(exists(ws, ".git/hooks") == false && exists(ws, ".git/config") == false && exists(ws, ".config/rv") == false)
    }

    @Test("a later run re-creates control children under a placeholder .git another runtime filled")
    func secondAcquireReensuresChildren() throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let registry = MicroVMControlPlaceholders()
        try registry.acquire(workspace: ws.path).get()
        #expect(exists(ws, ".git/hooks") == false)
        // A Seatbelt run (or the host) writes into the placeholder while run A holds it.
        try "ref: refs/heads/main\n".write(to: ws.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try registry.acquire(workspace: ws.path).get()
        #expect(exists(ws, ".git/hooks") && exists(ws, ".git/config"), "run B must get children to pin")
        registry.release(workspace: ws.path)
        registry.release(workspace: ws.path)
        #expect(exists(ws, ".git/hooks") == false && exists(ws, ".git/config") == false)
        #expect(exists(ws, ".git/HEAD"))
    }

    @Test("a placeholder that gained content is left in place")
    func nonEmptyStays() throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let registry = MicroVMControlPlaceholders()
        try registry.acquire(workspace: ws.path).get()
        try "host edit\n".write(to: ws.appendingPathComponent(".rv/policy.toml"), atomically: true, encoding: .utf8)
        registry.release(workspace: ws.path)
        #expect(exists(ws, ".rv/policy.toml"))
        #expect(exists(ws, ".git") == false)
    }

    @Test("a symlinked control path refuses the launch and leaves nothing behind")
    func symlinkRefused() throws {
        let ws = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createSymbolicLink(atPath: ws.appendingPathComponent(".config").path, withDestinationPath: "/tmp")
        let registry = MicroVMControlPlaceholders()
        guard case .failure = registry.acquire(workspace: ws.path) else {
            Issue.record("a symlinked .config must refuse")
            return
        }
        #expect(exists(ws, ".git") == false && exists(ws, ".rv") == false)
    }
}

@Suite("macOS guest launch")
struct MacOSGuestLaunchTests {
    private let command = IsolatedCommand(executable: "/usr/bin/swift", arguments: ["build"])!

    @Test("macOS guests take a prepared image name and at least 4 GiB")
    func options() {
        #expect(MicroVMLaunchOptions(image: "dev", guest: .macOS)?.guest == .macOS)
        #expect(MicroVMLaunchOptions(image: "xcode-26", guest: .macOS, cpus: 4, memoryMiB: 8192) != nil)
        #expect(MicroVMLaunchOptions(image: "Dev", guest: .macOS) == nil)
        #expect(MicroVMLaunchOptions(image: "alpine:3.20", guest: .macOS) == nil)
        #expect(MicroVMLaunchOptions(image: "dev", guest: .macOS, memoryMiB: 2048) == nil)
        #expect(MicroVMLaunchOptions(image: "alpine:3.20")?.guest == .linux)
    }

    @Test("the guest round-trips on the wire; absent means Linux; unknown guests are refused")
    func codec() throws {
        let options = try #require(MicroVMLaunchOptions(image: "dev", guest: .macOS, cpus: 4))
        let decoded = try JSONDecoder().decode(MicroVMLaunchOptions.self, from: try JSONEncoder().encode(options))
        #expect(decoded == options)
        let linux = try JSONDecoder().decode(MicroVMLaunchOptions.self, from: Data(#"{"image":"alpine"}"#.utf8))
        #expect(linux.guest == .linux)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MicroVMLaunchOptions.self, from: Data(#"{"image":"dev","guest":"windows"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MicroVMLaunchOptions.self, from: Data(#"{"image":"Dev","guest":"macOS"}"#.utf8))
        }
    }

    @Test("each guest has its own helper and state root")
    func helpers() {
        #expect(MicroVMHelper.executableName(for: .linux) == "rv-microvm")
        #expect(MicroVMHelper.executableName(for: .macOS) == "rv-macvm")
        #expect(MicroVMHelper.stateRoot(home: "/Users/dev", guest: .macOS) == "/Users/dev/.config/rv/macvm")
        #expect(MicroVMHelper.stateRoot(home: "/Users/dev", guest: .linux) == "/Users/dev/.config/rv/microvm")
    }

    @Test("the guest sandbox profile is the host cage's workspace control rules")
    func guestProfile() {
        let profile = macOSGuestSandboxProfile(workspacePath: "/Users/dev/p")
        // LaunchServices would start an opened app outside the sandbox, and an
        // Apple event can make a running app (System Events) run a shell command there.
        #expect(profile.hasPrefix("(version 1)\n(allow default)\n(deny lsopen)\n(deny appleevent-send)\n"))
        #expect(profile.hasSuffix(workspaceControlDenies(workspacePath: "/Users/dev/p")))
    }

    #if os(macOS)
    /// Runs a command, optionally under the guest profile, and kills it after
    /// `timeout` seconds (a consent prompt must not hang CI). Stderr goes to a
    /// file so no read can block.
    private func launchProbe(
        _ arguments: [String], profile: String?, errorFile: URL, timeout: TimeInterval = 15
    ) throws -> (status: Int32, error: String, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: profile == nil ? arguments[0] : "/usr/bin/sandbox-exec")
        process.arguments = profile.map { ["-p", $0] + arguments } ?? Array(arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorFile)
        defer { try? errors.close() }
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let error = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
        return (process.terminationStatus, error, timedOut)
    }

    /// Setuid binaries fail on their own too (no crontab, no password), so
    /// only sandbox-exec's own refusal proves the exec was blocked.
    @Test("the guest profile refuses to exec setuid binaries")
    func guestProfileRefusesSetuid() throws {
        let scratch = try #require(posixRealpath(NSTemporaryDirectory()))
        let directory = URL(fileURLWithPath: scratch).appendingPathComponent("rv-guest-setuid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = macOSGuestSandboxProfile(workspacePath: directory.path)
        let errors = directory.appendingPathComponent("err")
        #expect(try launchProbe(["/usr/bin/true"], profile: profile, errorFile: errors).status == 0)
        for setuid in [["/usr/bin/crontab", "-l"], ["/usr/bin/sudo", "-n", "/usr/bin/true"]] {
            let result = try launchProbe(setuid, profile: profile, errorFile: errors)
            #expect(result.status == 71 && result.error.contains("Operation not permitted"), "\(setuid): \(result)")
        }
    }

    /// The guest profile allows everything but the control paths, so it
    /// must not leave a way to start a process outside the sandbox: such a
    /// process could write `.git/hooks`. Each launchd, LaunchServices and
    /// Apple event route runs once unsandboxed as a control, and only if
    /// that control writes its marker (within ~10 s) does the probe mean
    /// anything: then the route runs under the profile, where it must not.
    /// A route whose control fails here (no GUI login session, no
    /// Automation consent) is skipped with a visible warning, not a failure.
    @Test("nothing under the guest profile can start an unsandboxed process")
    func guestProfileHasNoEscape() throws {
        let scratch = try #require(posixRealpath(NSTemporaryDirectory()))
        let directory = URL(fileURLWithPath: scratch).appendingPathComponent("rv-guest-escape-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = macOSGuestSandboxProfile(workspacePath: directory.path)
        let domain = "gui/\(getuid())"
        let base = "dev.rv.guest-escape-probe-\(getpid())"
        var jobs: [String] = []
        defer {
            for label in jobs {
                for job in [["bootout", "\(domain)/\(label)"], ["remove", label]] {
                    let cleanup = Process()
                    cleanup.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    cleanup.arguments = job
                    cleanup.standardError = FileHandle.nullDevice
                    if (try? cleanup.run()) != nil { cleanup.waitUntilExit() }
                }
            }
        }
        /// The routes, each writing its own marker if its process runs.
        func routes(_ tag: String) throws -> [(name: String, arguments: [String], marker: URL)] {
            func marker(_ name: String) -> URL { directory.appendingPathComponent("\(tag)-\(name)") }
            let bootstrapped = "\(base)-\(tag)-bootstrap"
            let submitted = "\(base)-\(tag)-submit"
            jobs += [bootstrapped, submitted]
            let plist = directory.appendingPathComponent("\(bootstrapped).plist")
            let job: [String: Any] = [
                "Label": bootstrapped, "ProgramArguments": ["/usr/bin/touch", marker("bootstrap").path], "RunAtLoad": true,
            ]
            try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)
            let app = directory.appendingPathComponent("\(tag)-probe.app")
            let executable = app.appendingPathComponent("Contents/MacOS/probe")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n/usr/bin/touch '\(marker("open").path)'\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let info: [String: Any] = [
                "CFBundleExecutable": "probe", "CFBundleIdentifier": "\(base)-\(tag)-open", "CFBundlePackageType": "APPL",
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            return [
                ("launchctl bootstrap", ["/bin/launchctl", "bootstrap", domain, plist.path], marker("bootstrap")),
                ("launchctl submit", ["/bin/launchctl", "submit", "-l", submitted, "--", "/usr/bin/touch", marker("submit").path], marker("submit")),
                ("open", ["/usr/bin/open", "-g", "-j", app.path], marker("open")),
                (
                    "osascript",
                    ["/usr/bin/osascript", "-e", "tell application \"System Events\" to do shell script \"/usr/bin/touch '\(marker("osascript").path)'\""],
                    marker("osascript")
                ),
            ]
        }
        func appears(_ marker: URL, within seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            repeat {
                if FileManager.default.fileExists(atPath: marker.path) { return true }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
            return FileManager.default.fileExists(atPath: marker.path)
        }
        let errors = directory.appendingPathComponent("err")
        let controls = try routes("control")
        let probes = try routes("sandboxed")
        for (control, probe) in zip(controls, probes) {
            _ = try launchProbe(control.arguments, profile: nil, errorFile: errors)
            guard appears(control.marker, within: 10) else {
                Issue.record(
                    "skipped \(control.name): unsandboxed it started nothing here (no GUI login session or consent?), so its probe would prove nothing",
                    severity: .warning
                )
                continue
            }
            _ = try launchProbe(probe.arguments, profile: profile, errorFile: errors)
            // A negative result needs a fixed wait; the control's own latency is unknown, so allow 3 s.
            #expect(!appears(probe.marker, within: 3), "\(probe.name) escaped the sandbox")
        }
    }
    #endif

    @Test("a macOS launch hands rv-macvm the guest profile in its environment, not argv")
    func helperEnvironment() throws {
        let options = try #require(MicroVMLaunchOptions(image: "dev", guest: .macOS, memoryMiB: 8192))
        let profile = MicroVMProfile(workspacePath: "/Users/dev/p", options: options)
        let environment = microVMHelperEnvironment(["PATH=/usr/bin:/bin", "RV_GUEST_TOKEN=t"], profile: profile)
        let entry = try #require(environment.first { $0.hasPrefix("\(MicroVMHelper.guestProfileVariable)=") })
        #expect(entry == "\(MicroVMHelper.guestProfileVariable)=\(macOSGuestSandboxProfile(workspacePath: "/Users/dev/p"))")
        #expect(environment.contains("RV_GUEST_TOKEN=t"))
        let spawn = microVMSpawnCommand(
            helper: "/opt/rv/rv-macvm", claim: nil, profile: profile, stateRoot: "/s",
            relayPorts: [41000], forwardedNames: ["TOKEN"], nonce: "n", command: command
        )
        #expect(spawn.arguments.contains { $0.contains("allow default") } == false)
        #expect(spawn.arguments.prefix(8) == ["/opt/rv/rv-macvm", "run", "--root", "/s", "--image", "dev", "--workspace", "/Users/dev/p"])
        #expect(spawn.arguments.contains("--memory-mib"))

        let linux = MicroVMProfile(workspacePath: "/w", options: try #require(MicroVMLaunchOptions(image: "alpine")))
        #expect(microVMHelperEnvironment(["PATH=/usr/bin"], profile: linux) == ["PATH=/usr/bin"])
    }
}
