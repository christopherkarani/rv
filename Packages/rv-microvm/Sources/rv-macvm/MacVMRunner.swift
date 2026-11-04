import Darwin
import Foundation
import RVMicroVMCore
@preconcurrency import Virtualization

/// `rv-macvm run`: clone a prepared image, boot it with no network device,
/// relay the requested loopback ports, and run one command through the
/// guest agent. Exits with the guest's status; 125 when nothing ran.
struct MacVMRunner {
    /// SBPL the agent applies around the command; rv builds it from the
    /// same rules as its host cage. Read from the environment, not argv.
    static let profileVariable = "RV_MACVM_GUEST_PROFILE"
    /// Apple allows two macOS guests per host.
    static let concurrentLimit = 2

    let options: RunOptions
    let hostEnvironment: [String: String]

    func run() async -> Int32 {
        do {
            return try await execute()
        } catch let error as SetupError {
            report(error.description)
        } catch {
            report("\(error.localizedDescription)")
        }
        return MicroVMExit.couldNotEstablish
    }

    private func execute() async throws -> Int32 {
        guard let profile = hostEnvironment[Self.profileVariable], !profile.isEmpty else {
            throw SetupError("\(Self.profileVariable) is not set; rv supplies the guest sandbox profile")
        }
        let layout = MacVMLayout(root: options.layout.root)
        guard let name = MacVMImageName.validate(options.image) else { throw SetupError("invalid image name \(options.image)") }
        // One handle on the image directory for the record and both clones:
        // a `prepare --replace` swap mid-way cannot mix two images.
        let image = open(layout.image(name).path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard image >= 0 else { throw SetupError("image \(name) is not prepared; run: rv-macvm prepare --image \(name)") }
        defer { close(image) }
        let record = try loadRecord(image, name)
        guard let model = VZMacHardwareModel(dataRepresentation: record.hardwareModel), model.isSupported else {
            throw SetupError("this Mac cannot run image \(name) (macOS \(record.osVersion))")
        }

        let run: MacVMRunClaim
        switch MacVMRuns.claim(in: layout.runs, limit: Self.concurrentLimit) {
        case .failure(let error): throw SetupError(error.description)
        case .success(let claimed): run = claimed
        }
        defer { run.release() }
        let disk = run.directory.appendingPathComponent(MacVMLayout.diskName)
        let auxiliary = run.directory.appendingPathComponent(MacVMLayout.auxiliaryStorageName)
        try cloneFile(at: image, MacVMLayout.diskName, to: disk)
        try cloneFile(at: image, MacVMLayout.auxiliaryStorageName, to: auxiliary)

        let spec = MachineSpec(
            hardwareModel: model, auxiliaryStorage: auxiliary, disk: disk,
            cpus: options.cpus, memoryMiB: options.memoryMiB,
            shares: [.init(tag: MacVMAgent.workspaceTag, path: options.workspace, readOnly: false)],
            networkMAC: nil
        )
        let machine = Machine(try spec.configuration())
        let budget = BridgeBudget()
        for port in options.relayPorts {
            machine.listen(port: UInt32(port)) { connection in bridgeToLoopback(connection, port: port, budget: budget) }
        }

        // Established once the guest is fully configured and before it boots
        // (about 30 s; the supervisor waits 45). Nothing guest-side has run.
        try writeHandshake()
        do {
            try await machine.start()
        } catch {
            throw SetupError("the macOS guest did not start: \(error.localizedDescription)")
        }
        do {
            let status = try await runCommand(machine, profile: profile)
            await machine.stop()
            return status
        } catch {
            await machine.stop()
            throw error
        }
    }

    private func loadRecord(_ image: Int32, _ name: MacVMImageName) throws -> MacVMImageRecord {
        let descriptor = openat(image, MacVMLayout.recordName, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SetupError("image \(name) is not prepared; run: rv-macvm prepare --image \(name)")
        }
        do {
            // readToEnd throws on a read error (say, image.json is a directory);
            // readDataToEndOfFile would raise an uncatchable exception instead.
            let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).readToEnd() ?? Data()
            return try JSONDecoder().decode(MacVMImageRecord.self, from: data)
        } catch {
            throw SetupError("image \(name) has an unreadable image.json; prepare it again")
        }
    }

    private func connectAgent(_ machine: Machine) async throws -> VZVirtioSocketConnection {
        let deadline = Date().addingTimeInterval(TimeInterval(MacVMRun.agentTimeoutSeconds))
        while true {
            if let connection = try? await machine.connect(port: MacVMAgent.controlPort) { return connection }
            guard Date() < deadline else {
                throw SetupError("the guest agent did not answer within \(MacVMRun.agentTimeoutSeconds) s")
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func runCommand(_ machine: Machine, profile: String) async throws -> Int32 {
        let connection = try await connectAgent(machine)
        defer { connection.close() }
        let descriptor = dup(connection.fileDescriptor)
        guard descriptor >= 0 else { throw SetupError("cannot use the agent connection") }
        defer { close(descriptor) }
        let channel = MacVMChannel(descriptor: descriptor)

        let terminal = isatty(STDIN_FILENO) == 1
        let request = MacVMExecRequest.make(
            options, host: hostEnvironment, terminalSize: terminal ? terminalSize() : nil, profile: profile
        )
        channel.send(.exec(request))
        switch try channel.receive() {
        case .started?:
            break
        case .failure(let message)?:
            throw SetupError("guest agent: \(message)")
        default:
            throw SetupError("the guest agent closed the session before starting the command")
        }

        let restore = terminal ? makeRaw(STDIN_FILENO) : nil
        defer { if var saved = restore { tcsetattr(STDIN_FILENO, TCSANOW, &saved) } }
        forwardInput(to: channel)
        let signals = forwardSignals(to: channel, terminal: terminal)
        defer { signals.forEach { $0.cancel() } }

        while let frame = try channel.receive() {
            switch frame {
            case .output(let data): _ = writeAll(STDOUT_FILENO, data)
            case .errorOutput(let data): _ = writeAll(STDERR_FILENO, data)
            case .exit(let status): return MicroVMExit.status(fromGuest: status)
            default: continue
            }
        }
        // The command ran, so 125 would misreport; 255 is "lost".
        report("lost the guest agent connection")
        return 255
    }

    private func forwardInput(to channel: MacVMChannel) {
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                if count <= 0 {
                    channel.send(.input(Data()))
                    return
                }
                if !channel.send(.input(Data(buffer[0..<count]))) { return }
            }
        }
    }

    private func forwardSignals(to channel: MacVMChannel, terminal: Bool) -> [DispatchSourceSignal] {
        [SIGWINCH, SIGTERM, SIGHUP, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                if number == SIGWINCH {
                    if terminal, let size = terminalSize() { channel.send(.resize(rows: size.rows, columns: size.columns)) }
                } else {
                    channel.send(.signal(number))
                }
            }
            source.resume()
            return source
        }
    }

    private func writeHandshake() throws {
        guard let handshake = options.handshake else { return }
        guard writeAll(handshake.descriptor, Data(handshake.nonce.utf8)) else {
            throw SetupError("cannot write handshake: \(String(cString: strerror(errno)))")
        }
        close(handshake.descriptor)
    }
}

func terminalSize() -> (rows: UInt16, columns: UInt16)? {
    var size = winsize()
    guard ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0 else { return nil }
    return (size.ws_row, size.ws_col)
}

/// Raw mode for a guest terminal; returns the settings to restore.
func makeRaw(_ descriptor: Int32) -> termios? {
    var saved = termios()
    guard tcgetattr(descriptor, &saved) == 0 else { return nil }
    var raw = saved
    cfmakeraw(&raw)
    tcsetattr(descriptor, TCSANOW, &raw)
    return saved
}
