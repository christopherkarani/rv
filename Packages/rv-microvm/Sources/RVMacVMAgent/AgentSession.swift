import Darwin
import Foundation
import RVMicroVMCore
import Synchronization

public struct AgentConfiguration: Sendable {
    /// This executable; its `exec-as` verb starts every command.
    public var trampoline: String
    /// Guest user commands run as; nil keeps the agent's own (host tests).
    public var user: String?
    /// Makes the workspace share available at its path; returns an error.
    public var mountWorkspace: @Sendable (String) -> String?
    /// Connects one relayed connection to the host service on this port.
    public var connectRelay: @Sendable (Int) -> Int32?

    public init(
        trampoline: String,
        user: String?,
        mountWorkspace: @escaping @Sendable (String) -> String?,
        connectRelay: @escaping @Sendable (Int) -> Int32?
    ) {
        self.trampoline = trampoline
        self.user = user
        self.mountWorkspace = mountWorkspace
        self.connectRelay = connectRelay
    }
}

/// One exec session on one host connection: `exec`, then `started` or
/// `failure`, output while the command runs, and one `exit`. If the host
/// goes away first, the command's process group is killed.
public enum AgentSession {
    /// After the command exits, how long to keep reading output its
    /// background processes may still write before they are killed.
    static let drainMilliseconds: Int32 = 300
    /// After the kill, how long to wait for already-written output to reach
    /// the host. Only a stalled host connection takes this long.
    static let deliverySeconds = 30
    /// How long a signal waits for the `session` verb to start under `sshd`.
    static let sessionStartSeconds: TimeInterval = 5

    public static func serve(_ channel: MacVMChannel, configuration: AgentConfiguration) {
        let request: MacVMExecRequest
        do {
            guard case .exec(let received)? = try channel.receive() else {
                channel.send(.failure("a session must start with an exec request"))
                return
            }
            request = received
        } catch {
            channel.send(.failure(error.description))
            return
        }
        if let problem = request.validated() {
            channel.send(.failure(problem))
            return
        }
        if let problem = configuration.mountWorkspace(request.workspace) {
            channel.send(.failure("workspace share: \(problem)"))
            return
        }
        let relays: LoopbackRelays
        switch LoopbackRelays.start(ports: request.relayPorts, connect: configuration.connectRelay) {
        case .failure(let message):
            channel.send(.failure(message.description))
            return
        case .success(let started):
            relays = started
        }
        defer { relays.stop() }
        let child: GuestChild
        switch GuestChild.spawn(request, trampoline: configuration.trampoline, user: configuration.user) {
        case .failure(let message):
            channel.send(.failure(message.description))
            return
        case .success(let spawned):
            child = spawned
        }
        channel.send(.started)
        run(child, channel: channel, configuration: configuration)
    }

    private static func run(_ child: GuestChild, channel: MacVMChannel, configuration: AgentConfiguration) {
        let output = DispatchGroup()
        let pumping: [Bool]
        if let master = child.master {
            pumping = [pump(master, into: channel, as: MacVMFrame.output, group: output)]
        } else {
            pumping = [
                pump(child.stdoutPipe!, into: channel, as: MacVMFrame.output, group: output),
                pump(child.stderrPipe!, into: channel, as: MacVMFrame.errorOutput, group: output),
            ]
        }
        if pumping.contains(false) {
            // Output the host would never see: stop rather than truncate silently.
            channel.send(.errorOutput(Data("rv-macvm-agent: cannot read the command's output\n".utf8)))
            _ = kill(-child.pid, SIGKILL)
        }
        let input = DispatchGroup()
        let stdinClosed = Mutex(false)
        let exited = Mutex(false)
        input.enter()
        Thread.detachNewThread {
            let closed = forwardInput(
                channel: channel, child: child, configuration: configuration,
                hasExited: { exited.withLock { $0 } }
            )
            stdinClosed.withLock { $0 = closed }
            input.leave()
        }

        var status: Int32 = 0
        while waitpid(child.pid, &status, 0) < 0, errno == EINTR {}
        exited.withLock { $0 = true }
        if output.wait(timeout: .now() + .milliseconds(Int(drainMilliseconds))) == .timedOut {
            // Background processes still hold the terminal or pipes.
            stopLeftovers(child, configuration: configuration)
        }
        stopLeftovers(child, configuration: configuration)
        // Everything written is delivered before `exit`, which the host
        // treats as the end of output. Each pump owns its descriptor, so a
        // pump that outlives this wait never reads a recycled one.
        _ = output.wait(timeout: .now() + .seconds(deliverySeconds))
        channel.send(.exit(GuestChild.shellStatus(status)))
        channel.shutdown()
        input.wait()
        let open = stdinClosed.withLock { $0 } ? [child.master] : [child.master, child.stdinPipe]
        (open + [child.stdoutPipe, child.stderrPipe]).compactMap { $0 }.forEach { close($0) }
    }

    /// Sends `number` to the command's process group, which the `session`
    /// verb leads (it ignores the signal; the command does not). In a guest
    /// the verb runs under `sshd`, so it is found as the guest user's
    /// group-leading process running this executable, once it has a child:
    /// it ignores the signals before it spawns the command, so a signal
    /// sent earlier would end the session instead. `started` comes before
    /// ssh has connected, so an early signal waits for that.
    private static func deliver(
        _ number: Int32, child: GuestChild, configuration: AgentConfiguration, hasExited: () -> Bool
    ) {
        guard SessionVerb.forwardedSignals.contains(number) else { return }
        guard let user = configuration.user else {
            _ = kill(-child.pid, number)
            return
        }
        guard let entry = getpwnam(user) else { return }
        let deadline = Date().addingTimeInterval(sessionStartSeconds)
        while !hasExited() {
            let leaders = SessionVerb.processes(PROC_UID_ONLY, entry.pointee.pw_uid).filter {
                getpgid($0) == $0 && executablePath($0) == configuration.trampoline
                    && !SessionVerb.processes(PROC_PPID_ONLY, UInt32($0)).isEmpty
            }
            leaders.forEach { _ = kill(-$0, number) }
            guard leaders.isEmpty, Date() < deadline else { return }
            usleep(20_000)
        }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(cString: path)
    }

    /// Kills the command's process group and, in a guest, every process of
    /// the guest user: a process that left the group (`setsid`) would
    /// otherwise keep the terminal or pipes open. One exec runs per VM, so
    /// the guest user's processes are all this command's.
    private static func stopLeftovers(_ child: GuestChild, configuration: AgentConfiguration) {
        _ = kill(-child.pid, SIGKILL)
        guard let user = configuration.user else { return }
        // kill(-1) as the guest user signals all of that user's processes
        // except the sender.
        let sweep = Process()
        sweep.executableURL = URL(fileURLWithPath: configuration.trampoline)
        sweep.arguments = [ExecAs.verb, user, "--", "/bin/kill", "-KILL", "-1"]
        sweep.environment = ["PATH": "/usr/bin:/bin"]
        sweep.standardInput = FileHandle.nullDevice
        sweep.standardOutput = FileHandle.nullDevice
        sweep.standardError = FileHandle.nullDevice
        guard (try? sweep.run()) != nil else { return }
        sweep.waitUntilExit()
    }

    /// Copies `descriptor` to the host as `frame`s until end of file. The
    /// pump reads its own duplicate and closes it when done. False when it
    /// could not start.
    private static func pump(
        _ descriptor: Int32,
        into channel: MacVMChannel,
        as frame: @escaping @Sendable (Data) -> MacVMFrame,
        group: DispatchGroup
    ) -> Bool {
        let descriptor = dup(descriptor)
        guard descriptor >= 0 else { return false }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        group.enter()
        Thread.detachNewThread {
            defer {
                close(descriptor)
                group.leave()
            }
            var buffer = [UInt8](repeating: 0, count: 32_768)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return }
                if !channel.send(frame(Data(buffer[0..<count]))) { return }
            }
        }
        return true
    }

    /// Host frames until the connection ends. An end before the command
    /// exits means the host is gone: kill the group. After it exits the
    /// pid may be reused, so nothing is killed. True when this closed the
    /// stdin pipe.
    private static func forwardInput(
        channel: MacVMChannel, child: GuestChild, configuration: AgentConfiguration, hasExited: () -> Bool
    ) -> Bool {
        var stdinPipe = child.stdinPipe
        while true {
            let frame: MacVMFrame?
            do { frame = try channel.receive() } catch { frame = nil }
            guard let frame else {
                if !hasExited() { _ = kill(-child.pid, SIGKILL) }
                return stdinPipe == nil && child.stdinPipe != nil
            }
            switch frame {
            case .input(let data):
                if let master = child.master {
                    _ = writeAll(master, data.isEmpty ? Data([0x04]) : data)
                } else if let pipe = stdinPipe {
                    if data.isEmpty || !writeAll(pipe, data) {
                        close(pipe)
                        stdinPipe = nil
                    }
                }
            case .resize(let rows, let columns):
                if let master = child.master { GuestChild.resize(master, rows: rows, columns: columns) }
            case .signal(let number):
                deliver(number, child: child, configuration: configuration, hasExited: hasExited)
            default:
                continue
            }
        }
    }
}
