import Containerization
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Darwin
import Foundation
import RVMicroVMCore
import Synchronization

/// One guest command in one fresh micro-VM.
///
/// The VM has no network interface. Its root filesystem is a clonefile copy
/// of the cached image rootfs, discarded on exit. The workspace is the only
/// writable host path; it is shared at the same absolute path. Loopback
/// services named by `--relay-port` are reachable at guest 127.0.0.1 on the
/// same port and nothing else on the host is.
///
/// Exit status is the guest's. Anything that fails before the guest command
/// starts exits `MicroVMExit.couldNotEstablish` without writing the handshake.
struct MicroVMRunner {
    let options: RunOptions
    let hostEnvironment: [String: String]

    private static let readyTimeout: Duration = .seconds(20)

    func run() async -> Int32 {
        // Belt and braces with SO_NOSIGPIPE: a dropped relay peer must never kill the VM.
        signal(SIGPIPE, SIG_IGN)
        var cleanup = Cleanup()
        let status: Int32
        do {
            status = try await launch(&cleanup)
        } catch let error as SetupError {
            report(error.description)
            status = MicroVMExit.couldNotEstablish
        } catch {
            report("micro-VM failed: \(error)")
            status = MicroVMExit.couldNotEstablish
        }
        await cleanup.run()
        return status
    }

    private func launch(_ cleanup: inout Cleanup) async throws -> Int32 {
        let layout = options.layout
        // Installed before anything boots: a termination signal during VM
        // startup must stop the container and run Cleanup, not kill us with
        // the VM still up.
        let interrupt = InterruptState()
        let signals = AsyncSignalHandler.create(notify: [SIGTERM, SIGHUP, SIGINT, SIGWINCH])
        let forwarder = Task {
            for await signal in signals.signals { await interrupt.handle(signal) }
        }
        defer { forwarder.cancel() }
        let problems = await AssetStatus(layout: layout).problems(image: nil)
        guard problems.isEmpty else {
            throw SetupError("\(problems.joined(separator: "; ")); run `rv-microvm prepare --image \(options.image)`")
        }
        let (image, cachedRootfs): (Containerization.Image, URL)
        do {
            (image, cachedRootfs) = try await AssetStatus(layout: layout).cachedRootfs(options.image)
        } catch {
            throw SetupError("\(error); run `rv-microvm prepare --image \(options.image)`")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: options.workspace, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SetupError("workspace \(options.workspace) is not a directory")
        }
        sweepStaleContainers(layout)
        let controlMounts: [WorkspaceControlMounts.Mount]
        switch WorkspaceControlMounts.plan(workspace: options.workspace, kind: { lstatKind("\(options.workspace)/\($0)") }) {
        case .failure(let refusal): throw SetupError(refusal.description)
        case .success(let value): controlMounts = value
        }

        let workspaceTag = try Mount.share(source: options.workspace, destination: options.workspace).tagHash

        let relayDirectory = try makePrivateDirectory()
        cleanup.add { try? FileManager.default.removeItem(atPath: relayDirectory) }
        let plan: RelayPlan
        switch RelayPlan.make(ports: options.relayPorts, hostDirectory: relayDirectory) {
        case .failure(let error): throw SetupError(error.description)
        case .success(let value): plan = value
        }
        let relay: HostRelay
        switch HostRelay.start(plan) {
        case .failure(let error): throw SetupError(error.description)
        case .success(let value): relay = value
        }
        cleanup.add { relay.stop() }

        let id = "rv-\(getpid())-\(String(UInt32.random(in: 0...UInt32.max), radix: 16))"
        let containerDirectory = layout.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: containerDirectory, withIntermediateDirectories: true)
        cleanup.add { try? FileManager.default.removeItem(at: containerDirectory) }
        let rootfs = containerDirectory.appendingPathComponent("rootfs.ext4")
        guard clonefile(cachedRootfs.path, rootfs.path, 0) == 0 else {
            throw SetupError("cannot clone root filesystem: \(String(cString: strerror(errno)))")
        }

        var manager = try ContainerManager(
            kernel: Kernel(path: layout.kernel, platform: .linuxArm),
            initfs: .block(format: "ext4", source: layout.initfs.path, destination: "/", options: ["ro"]),
            root: layout.store
        )
        let ready = ReadyLatch()
        let relayErrors = CapturedOutput()
        let container = try await manager.create(
            id,
            image: image,
            rootfs: .block(
                format: "ext4",
                source: rootfs.path,
                destination: "/",
                runtimeOptions: ["vzDiskImageSynchronizationMode=fsync"]
            ),
            networking: false,
            vm: VMResources(cpus: options.cpus, memoryInBytes: UInt64(options.memoryMiB).mib())
        ) { config in
            // The container's init process is the guest relay. It runs as
            // root so it can reach the vminitd-created sockets for any image
            // user, and it binds guest loopback only.
            config.process.arguments = plan.guestArguments
            config.process.environmentVariables = ["PATH=\(MicroVMGuest.defaultPath)"]
            config.process.workingDirectory = "/"
            config.process.user = User()
            config.process.terminal = false
            config.process.stdout = ready
            config.process.stderr = relayErrors
            config.hostname = MicroVMGuest.hostname
            let workspaceShare = Mount.share(source: options.workspace, destination: options.workspace)
            config.mounts.append(workspaceShare)
            // Control paths are binds from the workspace share's in-VM
            // mount, not extra shares: Containerization's single-file mounts
            // share the file's parent and drop any other share of that
            // directory, which would silently remove a pin (or the workspace).
            for mount in controlMounts {
                config.mounts.append(.any(
                    type: "none",
                    source: "/run/virtiofs/\(workspaceTag)\(mount.path.dropFirst(options.workspace.count))",
                    destination: mount.path,
                    options: mount.readOnly ? ["bind", "ro"] : ["bind"]
                ))
            }
            config.mounts.append(.share(source: layout.guestTools.path, destination: MicroVMGuest.toolsMount, options: ["ro"]))
            for entry in plan.entries {
                config.sockets.append(
                    UnixSocketConfiguration(
                        source: URL(fileURLWithPath: entry.hostSocket),
                        destination: URL(fileURLWithPath: entry.guestSocket),
                        direction: .into
                    )
                )
            }
        }
        try await container.create()
        cleanup.addAsync { try? await container.stop() }
        try interrupt.check()
        try await container.start()
        try interrupt.check()
        guard await waitReady(ready) else {
            let detail = relayErrors.text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SetupError("guest relay did not start\(detail.isEmpty ? "" : ": \(detail)")")
        }
        try interrupt.check()

        let imageConfig = try await image.config(for: guestPlatform).config
        let terminal = isatty(STDIN_FILENO) == 1 ? try Terminal(descriptor: STDIN_FILENO) : nil
        var process = imageConfig.map { LinuxProcessConfiguration(from: $0) } ?? LinuxProcessConfiguration()
        process.arguments = MicroVMGuest.commandArguments(options.command, terminal: terminal != nil)
        process.environmentVariables = GuestEnvironment.build(
            image: imageConfig?.env ?? [],
            forwarded: options.forwardedEnvironment,
            host: hostEnvironment,
            terminal: terminal != nil
        )
        process.workingDirectory = options.workspace
        if let terminal {
            process.terminal = true
            process.stdin = terminal
            process.stdout = terminal
        } else {
            process.stdin = DescriptorReader(handle: .standardInput)
            process.stdout = DescriptorWriter(handle: .standardOutput)
            process.stderr = DescriptorWriter(handle: .standardError)
        }
        let guest = try await container.exec("rv-guest", configuration: process)
        // Establish before the guest command runs, like the Seatbelt
        // launcher writing its nonce before exec: a failed handshake must
        // never follow agent activity.
        try writeHandshake()
        do {
            try await guest.start()
        } catch {
            throw SetupError("guest command \(options.command[0]) did not start: \(error)")
        }
        cleanup.addAsync { try? await guest.delete() }
        if let terminal {
            makeRaw(STDIN_FILENO)
            cleanup.add { terminal.tryReset() }
            if let size = try? terminal.size { try? await guest.resize(to: size) }
        }

        await interrupt.attach(guest: guest, terminal: terminal)
        let exit = try await guest.wait()
        return MicroVMExit.status(fromGuest: exit.exitCode)
    }

    private func waitReady(_ latch: ReadyLatch) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await latch.wait() }
            group.addTask {
                try? await Task.sleep(for: Self.readyTimeout)
                latch.fail()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Tells the supervisor the guest command is running inside the VM.
    private func writeHandshake() throws {
        guard let handshake = options.handshake else { return }
        let bytes = Array(handshake.nonce.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(handshake.descriptor, $0.baseAddress! + offset, bytes.count - offset) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw SetupError("cannot write handshake: \(String(cString: strerror(errno)))") }
            offset += written
        }
        close(handshake.descriptor)
    }

    /// Short private directory for the host relay sockets. The state root is
    /// usually too deep for AF_UNIX's 104-byte path limit.
    private func makePrivateDirectory() throws -> String {
        RelayDirectories.sweep(in: "/tmp", isAlive: { kill($0, 0) == 0 || errno != ESRCH })
        var template = Array("\(RelayDirectories.prefix)\(getpid()).XXXXXX".utf8CString)
        guard let created = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw SetupError("cannot create relay directory: \(String(cString: strerror(errno)))")
        }
        return String(cString: created)
    }

    /// Removes container directories left by runs that were SIGKILLed.
    private func sweepStaleContainers(_ layout: MicroVMLayout) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: layout.containers.path) else { return }
        for name in names {
            let parts = name.split(separator: "-")
            guard parts.count == 3, parts[0] == "rv", let pid = pid_t(parts[1]) else { continue }
            if kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: layout.containers.appendingPathComponent(name))
            }
        }
    }
}

/// Full raw mode, output processing included: the guest pty already
/// translated newlines, and a second ONLCR on the host would send "\r\r\n".
/// (`Terminal.setraw()` deliberately keeps OPOST.)
private func makeRaw(_ descriptor: Int32) {
    var attributes = termios()
    guard tcgetattr(descriptor, &attributes) == 0 else { return }
    cfmakeraw(&attributes)
    _ = tcsetattr(descriptor, TCSANOW, &attributes)
}

/// Signal routing across the launch: before the guest command exists a
/// terminating signal is only recorded (and turned into a launch failure at
/// the next checkpoint); afterwards it is forwarded to the guest.
final class InterruptState: Sendable {
    private struct State {
        var interrupted: Int32?
        var guest: LinuxProcess?
        var terminal: Terminal?
    }

    private let state = Mutex<State>(State())

    func check() throws {
        if let signal = state.withLock({ $0.interrupted }) {
            throw SetupError("interrupted by signal \(signal) before the guest command started")
        }
    }

    func attach(guest: LinuxProcess, terminal: Terminal?) async {
        let pending = state.withLock { state -> Int32? in
            state.guest = guest
            state.terminal = terminal
            return state.interrupted
        }
        if let pending { try? await guest.kill(Signal(rawValue: pending)) }
    }

    func handle(_ signal: Int32) async {
        let (guest, terminal) = state.withLock { state -> (LinuxProcess?, Terminal?) in
            if signal != SIGWINCH, state.guest == nil { state.interrupted = signal }
            return (state.guest, state.terminal)
        }
        guard let guest else { return }
        if signal == SIGWINCH {
            if let terminal, let size = try? terminal.size { try? await guest.resize(to: size) }
        } else {
            try? await guest.kill(Signal(rawValue: signal))
        }
    }
}

struct SetupError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Teardown steps, run in reverse order of registration.
struct Cleanup {
    private enum Step {
        case sync(() -> Void)
        case async(@Sendable () async -> Void)
    }

    private var steps: [Step] = []

    mutating func add(_ step: @escaping () -> Void) { steps.append(.sync(step)) }
    mutating func addAsync(_ step: @escaping @Sendable () async -> Void) { steps.append(.async(step)) }

    func run() async {
        for step in steps.reversed() {
            switch step {
            case .sync(let body): body()
            case .async(let body): await body()
            }
        }
    }
}

/// Type of `path` without following a final symlink.
private func lstatKind(_ path: String) -> WorkspaceControlMounts.Kind {
    var info = stat()
    // Only "does not exist" is absent; any other failure refuses (fail closed).
    guard lstat(path, &info) == 0 else { return errno == ENOENT ? .absent : .other }
    switch info.st_mode & S_IFMT {
    case S_IFDIR:
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return .other }
        return entries.isEmpty ? .emptyDirectory : .directory
    case S_IFREG: return .file
    case S_IFLNK: return .symlink
    default: return .other
    }
}
