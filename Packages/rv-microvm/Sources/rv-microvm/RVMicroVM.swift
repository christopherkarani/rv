import ArgumentParser
import Darwin
import Foundation
import RVMicroVMCore

@main
struct RVMicroVM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rv-microvm",
        abstract: "Run one command in a network-less Linux micro-VM (rv contained launch backend).",
        subcommands: [Prepare.self, Run.self, Status.self]
    )

    static var defaultRoot: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return "\(home)/.config/rv/microvm"
    }
}

struct RootOption: ParsableArguments {
    @Option(help: "Micro-VM state directory.")
    var root: String = RVMicroVM.defaultRoot

    var layout: MicroVMLayout { MicroVMLayout(root: URL(fileURLWithPath: root, isDirectory: true)) }

    func validate() throws {
        guard root.hasPrefix("/") else { throw ValidationError("--root must be an absolute path") }
    }
}

struct Prepare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download and cache the guest kernel, init filesystem, and optionally an image."
    )

    @OptionGroup var root: RootOption

    @Option(help: "OCI image to pull and unpack, e.g. alpine:3.20.")
    var image: String?

    @Option(help: "rv-guest-relay to install (default: next to this executable).")
    var relayBinary: String?

    func run() async throws {
        var reference: String?
        if let image {
            switch ImageReference.normalize(image) {
            case .failure(let error): throw ValidationError(error.description)
            case .success(let value): reference = value
            }
        }
        let relay = relayBinary.map { URL(fileURLWithPath: $0) } ?? siblingExecutable(MicroVMGuest.relayName)
        do {
            try await AssetPreparer(layout: root.layout).prepare(image: reference, relayBinary: relay)
        } catch {
            report("prepare failed: \(error)")
            throw ExitCode(1)
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report whether launches can start without network access. Exit 0 when ready."
    )

    @OptionGroup var root: RootOption

    @Option(help: "Also require this image to be prepared.")
    var image: String?

    func run() async throws {
        var reference: String?
        if let image {
            switch ImageReference.normalize(image) {
            case .failure(let error): throw ValidationError(error.description)
            case .success(let value): reference = value
            }
        }
        let problems = await AssetStatus(layout: root.layout).problems(image: reference)
        guard problems.isEmpty else {
            problems.forEach { print("not ready: \($0)") }
            throw ExitCode(1)
        }
        print("ready")
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a guest command in a fresh micro-VM; exits with the guest's status (125: could not start)."
    )

    @OptionGroup var root: RootOption

    @Option(help: "Prepared OCI image.")
    var image: String

    @Option(help: "Host directory shared read-write at the same path; the guest working directory.")
    var workspace: String

    @Option(help: "Virtual CPUs.")
    var cpus: Int = RunOptions.defaultCPUs

    @Option(help: "Guest memory in MiB.")
    var memoryMiB: Int = RunOptions.defaultMemoryMiB

    @Option(help: "Host loopback TCP port to expose at guest 127.0.0.1 (repeatable).")
    var relayPort: [Int] = []

    @Option(help: "Environment variable to copy from this process into the guest (repeatable).")
    var forwardEnv: [String] = []

    @Option(help: "Descriptor that receives --nonce once the guest command runs.")
    var handshakeFd: Int32?

    @Option(help: "Handshake nonce.")
    var nonce: String?

    @Argument(parsing: .postTerminator, help: "Guest command; the executable is an absolute path in the image.")
    var command: [String] = []

    func run() async throws {
        let validated = RunOptions.validate(
            root: root.root,
            image: image,
            workspace: workspace,
            cpus: cpus,
            memoryMiB: memoryMiB,
            relayPorts: relayPort,
            forwardedEnvironment: forwardEnv,
            command: command,
            handshakeDescriptor: handshakeFd,
            nonce: nonce,
            hostCPUs: ProcessInfo.processInfo.activeProcessorCount,
            hostMemoryMiB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        )
        let options: RunOptions
        switch validated {
        case .failure(let error):
            report(error.description)
            throw ExitCode(MicroVMExit.usage)
        case .success(let value):
            options = value
        }
        let status = await MicroVMRunner(options: options, hostEnvironment: ProcessInfo.processInfo.environment).run()
        throw ExitCode(status)
    }
}

func siblingExecutable(_ name: String) -> URL {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let path = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? executable
    return path.deletingLastPathComponent().appendingPathComponent(name)
}
