#if os(macOS)
import Darwin
import Dispatch
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

/// Real micro-VM launches through the workspace supervisor: protected
/// volume, PTY claim, per-runtime credentialed egress proxy relayed into the
/// guest, handshake, exit status, publish on close, and teardown on cancel.
///
/// Opt-in (`RV_MICROVM_E2E=1`): needs Apple silicon on macOS 26,
/// `Scripts/build-microvm.sh .build/debug`, and
/// `rv-microvm prepare --image alpine:3.20` in the default state root.
let microVMEndToEnd = ProcessInfo.processInfo.environment["RV_MICROVM_E2E"] == "1"

@Suite("Micro-VM workspace launch (end to end)", .serialized, .enabled(if: microVMEndToEnd, "set RV_MICROVM_E2E=1 after preparing alpine:3.20"))
struct MicroVMWorkspaceEndToEndTests {
    private let image = MicroVMLaunchOptions(image: "alpine:3.20")!

    @Test func guestRunsIsolatedReachesOnlyTheProxyAndPublishesOnClose() throws {
        let stub = try #require(E2EStubServer(reply: "PONG\n"))
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try "hello-from-host\n".write(to: tree.workspaceURL.appendingPathComponent("host.txt"), atomically: true, encoding: .utf8)
        try "outside\n".write(to: tree.siblingURL.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        let supervisor = try openE2EWorkspace(tree)
        let script = """
        echo "kernel=$(uname -s)"
        echo "uid=$(id -u)"
        echo "pwd=$(pwd)"
        echo "size=$(stty size)"
        echo "ifaces=$(ls /sys/class/net | tr '\\n' ' ')"
        if ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then echo net=reachable; else echo net=unreachable; fi
        echo "hostfile=$(cat host.txt)"
        if [ -e '\(tree.siblingURL.path)/secret.txt' ]; then echo sibling=visible; else echo sibling=absent; fi
        cred=${HTTPS_PROXY#http://}; cred=${cred%@*}; port=${HTTPS_PROXY##*:}
        ok=$(printf 'CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\\r\\nProxy-Authorization: Bearer %s\\r\\n\\r\\n' "$cred" | timeout 5 nc 127.0.0.1 "$port" | tr -d '\\r' | tr '\\n' '|')
        echo "allowed=$ok"
        bad=$(printf 'CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\\r\\n\\r\\n' | timeout 5 nc 127.0.0.1 "$port" | tr -d '\\r' | head -n1)
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

        let transcript = E2ETranscript()
        let client = UUID()
        try #require(supervisor.subscribeTerminal(runtime: running.id.rawValue, client: client) { notice in
            transcript.record(notice)
            return true
        }.get() == ())
        supervisor.activateTerminal(runtime: running.id.rawValue, client: client)
        let status = try #require(transcript.waitForExit(seconds: 90), "guest did not exit: \(transcript.text)")
        let output = transcript.text
        #expect(status == 7, "\(output)")
        #expect(output.contains("kernel=Linux"), "\(output)")
        #expect(output.contains("uid=0"), "\(output)")
        #expect(output.contains("pwd=\(posixRealpath(tree.workspaceURL.path) ?? "")"), "\(output)")
        #expect(output.contains("size=30 100"), "\(output)")
        #expect(output.contains("ifaces=lo "), "\(output)")
        #expect(output.contains("net=unreachable"), "\(output)")
        #expect(output.contains("hostfile=hello-from-host"), "\(output)")
        #expect(output.contains("sibling=absent"), "\(output)")
        #expect(output.contains("allowed=HTTP/1.1 200"), "\(output)")
        #expect(output.contains("PONG"), "\(output)")
        #expect(output.contains("anonymous=HTTP/1.1 407"), "\(output)")
        #expect(output.contains("\r\r\n") == false, "double newline translation")

        try supervisor.close().get()
        let published = tree.workspaceURL.appendingPathComponent("from-guest.txt")
        #expect((try? String(contentsOf: published, encoding: .utf8)) == "guest-wrote\n")
        #expect(microVMProcesses(workspace: tree.workspaceURL.path).isEmpty)
    }

    /// Mirrors Seatbelt's `workspaceControlDenies`: the guest cannot plant
    /// anything host git or rv later runs, and git keeps working.
    @Test func guestCannotPlantWorkspaceControlFiles() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let fm = FileManager.default
        let ws = tree.workspaceURL
        for dir in [".git/hooks", ".git/objects", ".rv", ".config/rv"] {
            try fm.createDirectory(at: ws.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "[core]\n\trepositoryformatversion = 0\n".write(to: ws.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/main\n".write(to: ws.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try "policy\n".write(to: ws.appendingPathComponent(".rv/policy"), atomically: true, encoding: .utf8)
        let supervisor = try openE2EWorkspace(tree)
        let script = """
        try() { if sh -c "$2" 2>/dev/null; then echo "$1=allowed"; else echo "$1=denied"; fi; }
        try hook 'echo evil > .git/hooks/pre-commit'
        try config 'echo "[core] fsmonitor = evil" >> .git/config'
        try renamegit 'mv .git .git-aside'
        try rmgit 'rm -rf .git'
        try rvwrite 'echo x > .rv/policy'
        try rvnew 'echo x > .rv/new'
        try cfgrv 'echo x > .config/rv/policy'
        try renamecfg 'mv .config .config-aside'
        try gitlock 'touch .git/index.lock && rm .git/index.lock'
        try gitobject 'mkdir -p .git/objects/ab && echo o > .git/objects/ab/cd'
        try cfgother 'mkdir .config/other && echo ok > .config/other/f'
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
        let transcript = E2ETranscript()
        let client = UUID()
        try #require(supervisor.subscribeTerminal(runtime: running.id.rawValue, client: client) { notice in
            transcript.record(notice)
            return true
        }.get() == ())
        supervisor.activateTerminal(runtime: running.id.rawValue, client: client)
        _ = try #require(transcript.waitForExit(seconds: 90), "guest did not exit: \(transcript.text)")
        let output = transcript.text
        for denied in ["hook", "config", "renamegit", "rmgit", "rvwrite", "rvnew", "cfgrv", "renamecfg"] {
            #expect(output.contains("\(denied)=denied"), "\(denied): \(output)")
        }
        for allowed in ["gitlock", "gitobject", "cfgother"] {
            #expect(output.contains("\(allowed)=allowed"), "\(allowed): \(output)")
        }

        try supervisor.close().get()
        #expect(fm.fileExists(atPath: ws.appendingPathComponent(".git/hooks/pre-commit").path) == false)
        #expect((try? String(contentsOf: ws.appendingPathComponent(".git/config"), encoding: .utf8))?.contains("fsmonitor") == false)
        #expect((try? String(contentsOf: ws.appendingPathComponent(".rv/policy"), encoding: .utf8)) == "policy\n")
        #expect(fm.fileExists(atPath: ws.appendingPathComponent(".git-aside").path) == false)
        #expect(fm.fileExists(atPath: ws.appendingPathComponent(".git/objects/ab/cd").path))
        #expect(fm.fileExists(atPath: ws.appendingPathComponent(".config/other/f").path))
    }

    /// Missing control paths: rv mounts read-only empty placeholders for the
    /// run and removes them afterwards, so nothing is planted and nothing
    /// is left behind.
    @Test func guestCannotCreateMissingControlPaths() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let ws = tree.workspaceURL
        try "src\n".write(to: ws.appendingPathComponent("main.c"), atomically: true, encoding: .utf8)
        let supervisor = try openE2EWorkspace(tree)
        let script = """
        try() { if sh -c "$2" 2>/dev/null; then echo "$1=allowed"; else echo "$1=denied"; fi; }
        try rvpolicy 'mkdir -p .rv && echo "allow = true" > .rv/policy.toml'
        try gitinit 'mkdir -p .git/hooks && echo evil > .git/hooks/post-checkout'
        try gitconfig 'echo "[core] fsmonitor = evil" > .git/config'
        try cfgrv 'mkdir -p .config/rv && echo x > .config/rv/policy.toml'
        try rmrv 'rmdir .rv'
        try normal 'echo ok > notes.txt'
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
        let transcript = E2ETranscript()
        let client = UUID()
        try #require(supervisor.subscribeTerminal(runtime: running.id.rawValue, client: client) { notice in
            transcript.record(notice)
            return true
        }.get() == ())
        supervisor.activateTerminal(runtime: running.id.rawValue, client: client)
        _ = try #require(transcript.waitForExit(seconds: 90), "guest did not exit: \(transcript.text)")
        let output = transcript.text
        for denied in ["rvpolicy", "gitinit", "gitconfig", "cfgrv", "rmrv"] {
            #expect(output.contains("\(denied)=denied"), "\(denied): \(output)")
        }
        #expect(output.contains("normal=allowed"), "\(output)")

        try supervisor.close().get()
        let fm = FileManager.default
        for leftover in [".rv", ".git", ".config"] {
            #expect(fm.fileExists(atPath: ws.appendingPathComponent(leftover).path) == false, "\(leftover) published")
        }
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
        #expect(microVMProcesses(workspace: tree.workspaceURL.path).isEmpty == false)
        _ = supervisor.cancel(running.id)
        #expect(e2eWait(seconds: 30) { microVMProcesses(workspace: tree.workspaceURL.path).isEmpty })
    }

    @Test func unpreparedImageFailsClosedBeforeTheHandshake() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try openE2EWorkspace(tree)
        defer { _ = supervisor.close() }
        let result = supervisor.launch(
            host: nil,
            command: try #require(IsolatedCommand(executable: "/bin/true")),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .discard,
            microVM: try #require(MicroVMLaunchOptions(image: "rv-never-prepared/none:0")),
            admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("runtime.jsonl"))
        )
        guard case .failure = result else {
            Issue.record("an unprepared image must not establish")
            return
        }
    }
}

private func openE2EWorkspace(_ tree: ContainmentTree) throws -> WorkspaceSessionSupervisor {
    let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
    return try WorkspaceSessionSupervisor.open(
        directory,
        lifecycleLog: .file(tree.rootURL.appendingPathComponent("workspace.jsonl")),
        reviewConfigDirectory: nil,
        denialRecorder: { _ in }
    ).get()
}

/// `rv-microvm run` processes sharing `workspace`.
private func microVMProcesses(workspace: String) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axww", "-o", "command="]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return ["ps failed"] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .map(String.init)
        .filter { $0.contains("rv-microvm run") && $0.contains("--workspace \(posixRealpath(workspace) ?? workspace) ") }
}

private func e2eWait(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return condition()
}

private final class E2ETranscript: Sendable {
    private let state = Mutex<(bytes: Data, exit: Int32?)>((Data(), nil))

    func record(_ notice: TerminalNotice) {
        state.withLock { state in
            switch notice {
            case .replay(_, let bytes), .output(_, let bytes):
                state.bytes.append(bytes)
            case .exited(let status):
                state.exit = status
            default:
                break
            }
        }
    }

    var text: String { state.withLock { String(decoding: $0.bytes, as: UTF8.self) } }

    func waitForExit(seconds: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let status = state.withLock({ $0.exit }) { return status }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }
}

/// Loopback TCP server that writes `reply` to every connection.
private final class E2EStubServer: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32
    private let reply: [UInt8]

    init?(reply: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, listen(fd, 16) == 0, named == 0 else {
            close(fd)
            return nil
        }
        listenFD = fd
        port = Int(UInt16(bigEndian: name.sin_port))
        self.reply = Array(reply.utf8)
        DispatchQueue.global().async { [self] in acceptLoop() }
    }

    deinit {
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            close(client)
        }
    }
}
#endif
