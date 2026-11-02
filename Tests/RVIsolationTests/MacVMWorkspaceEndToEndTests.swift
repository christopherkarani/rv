#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Real macOS guest launches through the workspace supervisor: a fresh
/// clone of a prepared image, no network interface, the protected volume at
/// the same path, the credentialed egress proxy relayed to guest loopback,
/// rv's workspace control rules enforced by Seatbelt in the guest,
/// handshake, exit status, publish on close, and teardown on cancel.
///
/// Opt-in (`RV_MACVM_E2E=1`): needs Apple silicon on macOS 27,
/// `Scripts/build-microvm.sh .build/debug`, and
/// `rv-macvm prepare --image dev` (or `RV_MACVM_E2E_IMAGE`) in the default
/// state root. Each test boots one guest (about 30-60 s).
let macVMEndToEnd = ProcessInfo.processInfo.environment["RV_MACVM_E2E"] == "1"
let macVMEndToEndImage = ProcessInfo.processInfo.environment["RV_MACVM_E2E_IMAGE"] ?? "dev"

@Suite("macOS guest workspace launch (end to end)", .serialized, .enabled(if: macVMEndToEnd, "set RV_MACVM_E2E=1 after rv-macvm prepare --image dev"))
struct MacVMWorkspaceEndToEndTests {
    private let image = MicroVMLaunchOptions(image: macVMEndToEndImage, guest: .macOS)!
    private let bootAndRunSeconds: TimeInterval = 300

    @Test func guestRunsIsolatedReachesOnlyTheProxyAndPublishesOnClose() throws {
        let stub = try #require(E2EStubServer(reply: "PONG\n"))
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try "hello-from-host\n".write(to: tree.workspaceURL.appendingPathComponent("host.txt"), atomically: true, encoding: .utf8)
        try "outside\n".write(to: tree.siblingURL.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        let supervisor = try openE2EWorkspace(tree)
        let script = """
        echo "os=$(sw_vers -productName)"
        echo "user=$(id -un)"
        echo "pwd=$(pwd)"
        echo "size=$(stty size)"
        # macOS keeps its built-in virtual interfaces (en*, anpi*) without a
        # NIC; what matters is that none has an address and there is no route.
        if ifconfig | grep -E 'inet6? ' | grep -vqE 'inet (127[.]0[.]0[.]1) |inet6 (::1|fe80:)'; then echo nic=addressed; else echo nic=none; fi
        # `route get` exits 0 even when it prints "not in table".
        if netstat -rn | grep -q '^default'; then echo route=default; else echo route=none; fi
        if nc -z -G 2 -w 2 1.1.1.1 443 >/dev/null 2>&1; then echo net=reachable; else echo net=unreachable; fi
        # sshd sessions run outside the sandbox: the command must not reach it.
        case "$(nc -vz -G 2 127.0.0.1 22 2>&1)" in *"not permitted"*) echo sshd=denied ;; *) echo sshd=reachable ;; esac
        echo "hostfile=$(cat host.txt)"
        if [ -e '\(tree.siblingURL.path)/secret.txt' ]; then echo sibling=visible; else echo sibling=absent; fi
        cred=${HTTPS_PROXY#http://}; cred=${cred%@*}; port=${HTTPS_PROXY##*:}
        ok=$(printf 'CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\\r\\nProxy-Authorization: Bearer %s\\r\\n\\r\\n' "$cred" | nc -w 5 127.0.0.1 "$port" | tr -d '\\r' | tr '\\n' '|')
        echo "allowed=$ok"
        bad=$(printf 'CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\\r\\n\\r\\n' | nc -w 5 127.0.0.1 "$port" | tr -d '\\r' | head -n1)
        echo "anonymous=$bad"
        echo guest-wrote > from-guest.txt
        exit 7
        """
        let running = try supervisor.launch(
            host: nil,
            command: try #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", script])),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .pseudoTerminal(rows: 30, columns: 100),
            microVM: image,
            admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("runtime.jsonl"))
        ).get()
        #expect(running.session.backend == .microvm)

        let output = try runToExit(supervisor, running.id.rawValue, expect: 7)
        #expect(output.contains("os=macOS"), "\(output)")
        #expect(output.contains("user=rv"), "\(output)")
        #expect(output.contains("pwd=\(posixRealpath(tree.workspaceURL.path) ?? "")"), "\(output)")
        #expect(output.contains("size=30 100"), "\(output)")
        #expect(output.contains("nic=none"), "\(output)")
        #expect(output.contains("route=none"), "\(output)")
        #expect(output.contains("net=unreachable"), "\(output)")
        #expect(output.contains("sshd=denied"), "\(output)")
        #expect(output.contains("hostfile=hello-from-host"), "\(output)")
        #expect(output.contains("sibling=absent"), "\(output)")
        #expect(output.contains("allowed=HTTP/1.1 200"), "\(output)")
        #expect(output.contains("PONG"), "\(output)")
        #expect(output.contains("anonymous=HTTP/1.1 407"), "\(output)")

        try supervisor.close().get()
        let published = tree.workspaceURL.appendingPathComponent("from-guest.txt")
        #expect((try? String(contentsOf: published, encoding: .utf8)) == "guest-wrote\n")
        #expect(macVMProcesses(workspace: tree.workspaceURL.path).isEmpty)
    }

    /// The guest applies the host cage's `workspaceControlDenies`, for both
    /// existing and missing control paths; ordinary git writes still work.
    @Test func guestCannotPlantWorkspaceControlFiles() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let fm = FileManager.default
        let ws = tree.workspaceURL
        for dir in [".git/hooks", ".git/objects"] {
            try fm.createDirectory(at: ws.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "[core]\n\trepositoryformatversion = 0\n".write(to: ws.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/main\n".write(to: ws.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        let supervisor = try openE2EWorkspace(tree)
        let script = """
        try() { if sh -c "$2" 2>/dev/null; then echo "$1=allowed"; else echo "$1=denied"; fi; }
        try hook 'echo evil > .git/hooks/pre-commit'
        try config 'echo "[core] fsmonitor = evil" >> .git/config'
        try renamegit 'mv .git .git-aside'
        try rmgit 'rm -rf .git'
        try rvnew 'mkdir -p .rv && echo "allow = true" > .rv/policy.toml'
        try cfgnew 'mkdir -p .config/rv && echo x > .config/rv/policy.toml'
        try gitlock 'touch .git/index.lock && rm .git/index.lock'
        try gitobject 'mkdir -p .git/objects/ab && echo o > .git/objects/ab/cd'
        try normal 'echo ok > notes.txt'
        # No way out of the sandbox to write those paths: setuid exec and
        # launchd jobs (which would run unsandboxed) must both be refused.
        for setuid in "/usr/bin/sudo -n /usr/bin/true" "/usr/bin/crontab -l"; do
          case "$($setuid 2>&1)" in *"not permitted"*) echo "setuid=denied" ;; *) echo "setuid=allowed: $setuid" ;; esac
        done
        /bin/launchctl submit -l dev.rv.e2e-escape -- /usr/bin/touch "$PWD/.git/hooks/escaped" 2>/dev/null
        /bin/launchctl bootstrap user/$(id -u) /dev/null 2>/dev/null
        sleep 2
        if [ -e .git/hooks/escaped ]; then echo launchd=escaped; else echo launchd=denied; fi
        """
        let running = try supervisor.launch(
            host: nil,
            command: try #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", script])),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .pseudoTerminal(rows: 24, columns: 80),
            microVM: image,
            admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("runtime.jsonl"))
        ).get()
        let output = try runToExit(supervisor, running.id.rawValue, expect: nil)
        for denied in ["hook", "config", "renamegit", "rmgit", "rvnew", "cfgnew", "launchd"] {
            #expect(output.contains("\(denied)=denied"), "\(denied): \(output)")
        }
        #expect(output.components(separatedBy: "setuid=denied").count == 3, "\(output)")
        #expect(!output.contains("setuid=allowed"), "\(output)")
        for allowed in ["gitlock", "gitobject", "normal"] {
            #expect(output.contains("\(allowed)=allowed"), "\(allowed): \(output)")
        }

        try supervisor.close().get()
        #expect(fm.fileExists(atPath: ws.appendingPathComponent(".git/hooks/pre-commit").path) == false)
        #expect((try? String(contentsOf: ws.appendingPathComponent(".git/config"), encoding: .utf8))?.contains("fsmonitor") == false)
        #expect(fm.fileExists(atPath: ws.appendingPathComponent(".git-aside").path) == false)
        #expect(fm.fileExists(atPath: ws.appendingPathComponent(".rv").path) == false)
        #expect(fm.fileExists(atPath: ws.appendingPathComponent(".config").path) == false)
        #expect(fm.fileExists(atPath: ws.appendingPathComponent(".git/objects/ab/cd").path))
        #expect(fm.fileExists(atPath: ws.appendingPathComponent("notes.txt").path))
    }

    @Test func cancelTearsDownTheVM() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try openE2EWorkspace(tree)
        defer { _ = supervisor.close() }
        let running = try supervisor.launch(
            host: nil,
            command: try #require(IsolatedCommand(executable: "/bin/sleep", arguments: ["600"])),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .discard,
            microVM: image,
            admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("runtime.jsonl"))
        ).get()
        let helpers = macVMProcesses(workspace: tree.workspaceURL.path)
        let pid = try #require(helpers.first.flatMap { Int32($0.split(separator: " ").first ?? "") }, "\(helpers)")
        _ = supervisor.cancel(running.id)
        #expect(e2eWait(seconds: 60) { macVMProcesses(workspace: tree.workspaceURL.path).isEmpty })
        // A cancel SIGKILLs rv-macvm, so its clone stays behind until the
        // next `status` (which rv runs before every launch) sweeps it.
        // rv-macvm finds its state root from HOME, so look where it does.
        let home = try #require(ProcessInfo.processInfo.environment["HOME"])
        let runs = URL(fileURLWithPath: MicroVMHelper.stateRoot(home: home, guest: .macOS)).appendingPathComponent("runs")
        func clones() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []).filter { $0.hasPrefix("\(pid)-") }
        }
        #expect(clones().count == 1, "the killed run's clone: \(clones())")
        let helper = try #require(MicroVMHelper.locate(workspace: tree.workspaceURL.path, guest: .macOS))
        let status = Process()
        status.executableURL = URL(fileURLWithPath: helper)
        status.arguments = ["status", "--image", macVMEndToEndImage]
        status.standardOutput = FileHandle.nullDevice
        status.standardError = FileHandle.nullDevice
        try status.run()
        status.waitUntilExit()
        #expect(clones().isEmpty, "\(clones())")
    }

    @Test func unpreparedImageFailsClosedBeforeTheHandshake() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try openE2EWorkspace(tree)
        defer { _ = supervisor.close() }
        let result = supervisor.launch(
            host: nil,
            command: try #require(IsolatedCommand(executable: "/usr/bin/true")),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .discard,
            microVM: try #require(MicroVMLaunchOptions(image: "rv-never-prepared", guest: .macOS)),
            admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("runtime.jsonl"))
        )
        guard case .failure = result else {
            Issue.record("an unprepared image must not establish")
            return
        }
    }

    private func runToExit(_ supervisor: WorkspaceSessionSupervisor, _ runtime: UUID, expect status: Int32?) throws -> String {
        let transcript = E2ETranscript()
        let client = UUID()
        try #require(supervisor.subscribeTerminal(runtime: runtime, client: client) { notice in
            transcript.record(notice)
            return true
        }.get() == ())
        supervisor.activateTerminal(runtime: runtime, client: client)
        let exit = try #require(transcript.waitForExit(seconds: bootAndRunSeconds), "guest did not exit: \(transcript.text)")
        if let status { #expect(exit == status, "\(transcript.text)") }
        return transcript.text
    }
}

/// `rv-macvm run` processes sharing `workspace`, as "PID COMMAND".
private func macVMProcesses(workspace: String) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axww", "-o", "pid=,command="]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return ["ps failed"] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.contains("rv-macvm run") && $0.contains("--workspace \(posixRealpath(workspace) ?? workspace) ") }
}
#endif
