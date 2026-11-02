import Foundation
import Testing
@testable import RVMicroVMCore

private func validate(
    root: String = "/state",
    image: String = "alpine:3.20",
    workspace: String = "/Users/dev/project",
    cpus: Int = 2,
    memoryMiB: Int = 1024,
    relayPorts: [Int] = [],
    env: [String] = [],
    command: [String] = ["/bin/sh"],
    fd: Int32? = nil,
    nonce: String? = nil
) -> Result<RunOptions, MicroVMOptionError> {
    RunOptions.validate(
        root: root, image: image, workspace: workspace, cpus: cpus, memoryMiB: memoryMiB,
        relayPorts: relayPorts, forwardedEnvironment: env, command: command,
        handshakeDescriptor: fd, nonce: nonce, hostCPUs: 8, hostMemoryMiB: 16384
    )
}

private func failure(_ result: Result<RunOptions, MicroVMOptionError>) -> MicroVMOptionError? {
    if case .failure(let error) = result { return error }
    return nil
}

@Suite("RunOptions")
struct RunOptionsTests {
    @Test("accepts a complete request and normalizes the image")
    func acceptsComplete() throws {
        let options = try validate(
            relayPorts: [8080, 9090], env: ["HTTPS_PROXY", "TERM"],
            command: ["/usr/bin/env", "bash"], fd: 3, nonce: "abc123"
        ).get()
        #expect(options.image == "docker.io/library/alpine:3.20")
        #expect(options.handshake == RunOptions.Handshake(descriptor: 3, nonce: "abc123"))
        #expect(options.layout.root.path == "/state")
        #expect(options.command == ["/usr/bin/env", "bash"])
    }

    @Test("refuses relative paths and missing commands")
    func refusesRelative() {
        #expect(failure(validate(root: "state")) == .rootMustBeAbsolute)
        #expect(failure(validate(workspace: "project")) == .workspaceMustBeAbsolute)
        #expect(failure(validate(command: [])) == .commandMissing)
        #expect(failure(validate(command: ["sh"])) == .commandMustBeAbsolute("sh"))
    }

    @Test("refuses NUL anywhere")
    func refusesNUL() {
        #expect(failure(validate(command: ["/bin/sh", "a\0b"])) == .containsNUL)
        #expect(failure(validate(env: ["A\0"])) == .containsNUL)
    }

    @Test("bounds cpus and memory by the host")
    func boundsResources() {
        #expect(failure(validate(cpus: 0)) == .cpusOutOfRange(0, maximum: 8))
        #expect(failure(validate(cpus: 9)) == .cpusOutOfRange(9, maximum: 8))
        #expect(failure(validate(memoryMiB: 128)) == .memoryOutOfRange(128, minimum: 256, maximum: 16384))
        #expect(failure(validate(memoryMiB: 16385)) == .memoryOutOfRange(16385, minimum: 256, maximum: 16384))
    }

    @Test("validates relay ports")
    func relayPorts() {
        #expect(failure(validate(relayPorts: [0])) == .invalidRelayPort(0))
        #expect(failure(validate(relayPorts: [65536])) == .invalidRelayPort(65536))
        #expect(failure(validate(relayPorts: [80, 80])) == .duplicateRelayPort(80))
        #expect(failure(validate(relayPorts: Array(1...9))) == .tooManyRelayPorts(9))
    }

    @Test("validates forwarded names")
    func forwardedNames() {
        #expect(failure(validate(env: ["1BAD"])) == .invalidEnvironmentName("1BAD"))
        #expect(failure(validate(env: ["A-B"])) == .invalidEnvironmentName("A-B"))
        #expect(failure(validate(env: ["A", "A"])) == .duplicateEnvironmentName("A"))
    }

    @Test("handshake needs both a descriptor and a nonce")
    func handshake() {
        #expect(failure(validate(fd: 3)) == .handshakeIncomplete)
        #expect(failure(validate(nonce: "abc")) == .handshakeIncomplete)
        #expect(failure(validate(fd: 2, nonce: "abc")) == .invalidHandshakeDescriptor(2))
        #expect(failure(validate(fd: 3, nonce: "a b")) == .invalidNonce)
        #expect(failure(validate(fd: 3, nonce: "")) == .invalidNonce)
    }
}

@Suite("ImageReference")
struct ImageReferenceTests {
    @Test(
        "normalizes Docker-style references",
        arguments: [
            ("alpine", "docker.io/library/alpine:latest"),
            ("alpine:3.20", "docker.io/library/alpine:3.20"),
            ("node:22-bookworm", "docker.io/library/node:22-bookworm"),
            ("org/tool:v1", "docker.io/org/tool:v1"),
            ("ghcr.io/org/tool", "ghcr.io/org/tool:latest"),
            ("localhost:5000/team/img:dev", "localhost:5000/team/img:dev"),
            ("docker.io/library/alpine:3.20", "docker.io/library/alpine:3.20"),
            (
                "alpine@sha256:" + String(repeating: "a", count: 64),
                "docker.io/library/alpine@sha256:" + String(repeating: "a", count: 64)
            ),
        ]
    )
    func normalizes(input: String, expected: String) throws {
        #expect(try ImageReference.normalize(input).get() == expected)
    }

    @Test(
        "rejects malformed references",
        arguments: ["", "Alpine", "a b", "alpine:", "alpine:-x", "/alpine", "org//img", "alpine@sha256:abc", "img:tag/x"]
    )
    func rejects(input: String) {
        #expect(throws: MicroVMOptionError.self) { try ImageReference.normalize(input).get() }
    }
}

@Suite("GuestEnvironment")
struct GuestEnvironmentTests {
    @Test("image env, then defaults for unset names, then forwarded host values")
    func layering() {
        let env = GuestEnvironment.build(
            image: ["PATH=/opt/node/bin:/usr/bin", "NODE_VERSION=22", "garbage", "1X=y"],
            forwarded: ["HTTPS_PROXY", "MISSING", "LANG"],
            host: [
                "RV_GUEST_HTTPS_PROXY": "http://u:p@127.0.0.1:4000", "RV_GUEST_LANG": "en_US.UTF-8",
                "LANG": "ignored-unprefixed", "RV_GUEST_SECRET": "nope",
            ],
            terminal: true
        )
        #expect(env == [
            "PATH=/opt/node/bin:/usr/bin",
            "NODE_VERSION=22",
            "HOME=/root",
            "LANG=en_US.UTF-8",
            "TERM=xterm-256color",
            "HTTPS_PROXY=http://u:p@127.0.0.1:4000",
        ])
    }

    @Test("never forwards a host value that was not named")
    func onlyNamed() {
        let env = GuestEnvironment.build(image: [], forwarded: [], host: ["RV_GUEST_AWS_SECRET_ACCESS_KEY": "x"], terminal: false)
        #expect(env == ["PATH=\(MicroVMGuest.defaultPath)", "HOME=/root", "LANG=C.UTF-8"])
    }
}

@Suite("RelayPlan")
struct RelayPlanTests {
    @Test("maps each port to host and guest sockets")
    func plan() throws {
        let plan = try RelayPlan.make(ports: [4000, 5000], hostDirectory: "/tmp/rvmvm.abc").get()
        #expect(plan.entries.map(\.hostSocket) == ["/tmp/rvmvm.abc/p4000.sock", "/tmp/rvmvm.abc/p5000.sock"])
        #expect(plan.guestArguments == ["/.rv/rv-guest-relay", "4000=/run/rv/p4000.sock", "5000=/run/rv/p5000.sock"])
    }

    @Test("an empty plan still starts the idle relay")
    func empty() throws {
        #expect(try RelayPlan.make(ports: [], hostDirectory: "/tmp/x").get().guestArguments == ["/.rv/rv-guest-relay"])
    }

    @Test("refuses socket paths longer than sun_path")
    func tooLong() {
        let dir = "/" + String(repeating: "d", count: 100)
        #expect(throws: MicroVMOptionError.self) { try RelayPlan.make(ports: [1], hostDirectory: dir).get() }
    }
}

@Suite("Guest command")
struct GuestCommandTests {
    @Test("terminal launches wait for a window size through the guest helper")
    func terminalWrap() {
        #expect(MicroVMGuest.commandArguments(["/bin/sh", "-l"], terminal: true)
            == ["/.rv/rv-guest-relay", "--exec-sized", "/bin/sh", "-l"])
        #expect(MicroVMGuest.commandArguments(["/bin/sh", "-l"], terminal: false) == ["/bin/sh", "-l"])
    }
}

@Suite("Layout and exit codes")
struct LayoutTests {
    @Test("rootfs cache is keyed by manifest digest hex only")
    func rootfsKey() {
        let layout = MicroVMLayout(root: URL(fileURLWithPath: "/s"))
        let hex = String(repeating: "b", count: 64)
        #expect(layout.rootfs(forDigest: "sha256:\(hex)")?.path == "/s/rootfs/\(hex).ext4")
        #expect(layout.rootfs(forDigest: "sha256:../../etc") == nil)
        #expect(layout.rootfs(forDigest: "sha512:\(hex)") == nil)
        #expect(layout.initfs.lastPathComponent == "vminit-\(MicroVMPins.initImageTag).ext4")
    }

    @Test("init image tag matches the pinned reference")
    func pins() {
        #expect(MicroVMPins.initImageReference.hasSuffix(":\(MicroVMPins.initImageTag)"))
    }

    @Test("guest statuses clamp to 0...255")
    func exitStatus() {
        #expect(MicroVMExit.status(fromGuest: 0) == 0)
        #expect(MicroVMExit.status(fromGuest: 130) == 130)
        #expect(MicroVMExit.status(fromGuest: 300) == 255)
        #expect(MicroVMExit.status(fromGuest: -1) == 128)
    }
}

@Suite("BridgeBudget")
struct BridgeBudgetTests {
    @Test("refuses bridges beyond the limit and frees a slot on release")
    func limit() {
        let budget = BridgeBudget(limit: 2)
        #expect(budget.tryAcquire())
        #expect(budget.tryAcquire())
        #expect(budget.tryAcquire() == false)
        budget.release()
        #expect(budget.tryAcquire())
        #expect(budget.tryAcquire() == false)
    }

    @Test("the shared relay budget is bounded")
    func defaultLimit() {
        #expect(BridgeBudget.relayLimit == 128)
    }
}

@Suite("WorkspaceControlMounts")
struct WorkspaceControlMountTests {
    private func plan(_ kinds: [String: WorkspaceControlMounts.Kind]) -> Result<[WorkspaceControlMounts.Mount], WorkspaceControlMounts.Refusal> {
        WorkspaceControlMounts.plan(workspace: "/w") { kinds[$0] ?? .absent }
    }

    @Test("a git repo with rv config: control paths read-only, entries pinned, parents first")
    func repo() throws {
        let mounts = try plan([
            ".git": .directory, ".git/hooks": .directory, ".git/config": .file,
            ".rv": .directory, ".config": .directory, ".config/rv": .directory,
        ]).get()
        #expect(mounts == [
            .init(path: "/w/.git", readOnly: false),
            .init(path: "/w/.git/hooks", readOnly: true),
            .init(path: "/w/.git/config", readOnly: true),
            .init(path: "/w/.rv", readOnly: true),
            .init(path: "/w/.config", readOnly: false),
            .init(path: "/w/.config/rv", readOnly: true),
        ])
    }

    @Test("a worktree gitfile is read-only; nothing under it is probed")
    func gitfile() throws {
        let mounts = try plan([".git": .file, ".git/hooks": .directory]).get()
        #expect(mounts == [.init(path: "/w/.git", readOnly: true)])
    }

    @Test("an empty .git or .config (rv's placeholder in a plain folder) is read-only whole")
    func emptyPlaceholders() throws {
        let mounts = try plan([".git": .emptyDirectory, ".rv": .emptyDirectory, ".config": .emptyDirectory]).get()
        #expect(mounts == [
            .init(path: "/w/.git", readOnly: true),
            .init(path: "/w/.rv", readOnly: true),
            .init(path: "/w/.config", readOnly: true),
        ])
    }

    @Test("an empty hooks placeholder inside a real repo is read-only")
    func emptyHooks() throws {
        let mounts = try plan([".git": .directory, ".git/hooks": .emptyDirectory, ".git/config": .file]).get()
        #expect(mounts == [
            .init(path: "/w/.git", readOnly: false),
            .init(path: "/w/.git/hooks", readOnly: true),
            .init(path: "/w/.git/config", readOnly: true),
        ])
    }

    @Test("absent paths add no mounts")
    func absent() throws {
        #expect(try plan([:]).get().isEmpty)
    }

    @Test("a symlinked control path is refused: sharing it would follow the link out of the workspace")
    func symlink() {
        #expect(plan([".git": .symlink]) == .failure(.unsupported("/w/.git")))
        #expect(plan([".config": .directory, ".config/rv": .symlink]) == .failure(.unsupported("/w/.config/rv")))
    }

    @Test("other file types are refused")
    func other() {
        #expect(plan([".rv": .other]) == .failure(.unsupported("/w/.rv")))
    }
}
