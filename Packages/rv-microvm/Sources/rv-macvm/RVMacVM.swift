import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import RVMicroVMCore

@main
struct RVMacVM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rv-macvm",
        abstract: "Run one command in a network-less macOS VM (rv contained launch backend).",
        subcommands: [Prepare.self, Status.self, Run.self]
    )

    /// `prepare` runs this binary as ssh's `SSH_ASKPASS`, which passes only
    /// a prompt: answer before argument parsing.
    static func main() async {
        // A guest that keeps sending after the host proxy closed must give EPIPE, not kill the host.
        signal(SIGPIPE, SIG_IGN)
        if let password = MacVMSetup.askpassReply(environment: ProcessInfo.processInfo.environment) {
            print(password)
            Darwin.exit(0)
        }
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }

    static var defaultRoot: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return "\(home)/.config/rv/macvm"
    }
}

struct MacRootOption: ParsableArguments {
    @Option(help: "macOS VM state directory (must be on APFS).")
    var root: String = RVMacVM.defaultRoot

    var layout: MacVMLayout { MacVMLayout(root: URL(fileURLWithPath: root, isDirectory: true)) }

    func validate() throws {
        guard root.hasPrefix("/") else { throw ValidationError("--root must be an absolute path") }
    }
}

func imageName(_ raw: String) throws -> MacVMImageName {
    guard let name = MacVMImageName.validate(raw) else {
        throw ValidationError("--image must be 1-63 lowercase letters, digits or '-': \(raw)")
    }
    return name
}

struct Prepare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build a macOS guest image unattended (downloads about 26 GB unless --ipsw is a local file)."
    )

    @OptionGroup var root: MacRootOption

    @Option(help: "Name for the image.")
    var image: String

    @Option(help: "Restore image: a local .ipsw path or an https URL (default: Apple's latest supported).")
    var ipsw: String?

    @Option(help: "Guest disk size in GiB (sparse).")
    var diskGib: Int = 80

    @Option(help: "Virtual CPUs for installation and setup.")
    var cpus: Int = MacVMRun.defaultCPUs

    @Option(name: .customLong("memory-mib"), help: "Guest memory in MiB for installation and setup.")
    var memoryMiB: Int = MacVMRun.defaultMemoryMiB

    @Option(help: "rv-macvm-agent to install (default: next to this executable).")
    var agent: String?

    @Flag(help: "Keep a downloaded restore image in the cache.")
    var keepIpsw = false

    @Flag(help: "Rebuild an existing image; the old one is replaced only once the new one is ready.")
    var replace = false

    func run() async throws {
        let name = try imageName(image)
        guard (40...2048).contains(diskGib) else { throw ValidationError("--disk-gib must be 40...2048") }
        do {
            try await MacVMPreparer(
                layout: root.layout, name: name, ipsw: ipsw, diskGiB: diskGib, cpus: cpus, memoryMiB: memoryMiB,
                agent: agent.map { URL(fileURLWithPath: $0) } ?? siblingExecutable(MacVMAgent.executableName),
                keepIPSW: keepIpsw, replace: replace
            ).prepare()
        } catch {
            report("prepare failed: \(error)")
            throw ExitCode(1)
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report whether an image is prepared. Exit 0 when ready."
    )

    @OptionGroup var root: MacRootOption

    @Option(help: "Image to check.")
    var image: String

    @Option(help: "The rv-macvm-agent this rv installs (default: next to this executable).")
    var agent: String?

    @Flag(help: "Not ready unless the image runs that agent.")
    var requireCurrentAgent = false

    func run() async throws {
        let name = try imageName(image)
        let layout = root.layout
        // rv runs this before every --macvm launch: a good moment to delete
        // the clones of runs that were killed (a cancel is a SIGKILL).
        MacVMRuns.sweep(in: layout.runs)
        var problems: [String] = []
        for file in [layout.disk(name), layout.auxiliaryStorage(name)] where !FileManager.default.fileExists(atPath: file.path) {
            problems.append("missing \(file.path)")
        }
        var note: String?
        if let data = try? Data(contentsOf: layout.record(name)) {
            if let record = try? JSONDecoder().decode(MacVMImageRecord.self, from: data) {
                let agentURL = agent.map { URL(fileURLWithPath: $0) } ?? siblingExecutable(MacVMAgent.executableName)
                if let current = try? fileSHA256(agentURL) {
                    note = record.agentUpdateNote(image: name, currentAgentSHA256: current)
                } else if requireCurrentAgent {
                    problems.append("cannot read the guest agent at \(agentURL.path)")
                }
            } else {
                problems.append("unreadable \(layout.record(name).path)")
            }
        } else {
            problems.append("image \(name) is not prepared; run: rv-macvm prepare --image \(name)")
        }
        if requireCurrentAgent, let note { problems.append(note) }
        guard problems.isEmpty else {
            problems.forEach { print("not ready: \($0)") }
            throw ExitCode(1)
        }
        print("ready")
        if let note { report(note) }
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a guest command in a fresh macOS VM; exits with the guest's status (125: could not start)."
    )

    @OptionGroup var root: MacRootOption

    @Option(help: "Prepared image name.")
    var image: String

    @Option(help: "Host directory shared read-write at the same path; the guest working directory.")
    var workspace: String

    @Option(help: "Virtual CPUs.")
    var cpus: Int = MacVMRun.defaultCPUs

    @Option(name: .customLong("memory-mib"), help: "Guest memory in MiB.")
    var memoryMiB: Int = MacVMRun.defaultMemoryMiB

    @Option(help: "Host loopback TCP port to expose at guest 127.0.0.1 (repeatable).")
    var relayPort: [Int] = []

    @Option(help: "Environment variable to pass into the guest; its value is read from RV_GUEST_<NAME> (repeatable).")
    var forwardEnv: [String] = []

    @Option(help: "Descriptor that receives --nonce once the guest is configured.")
    var handshakeFd: Int32?

    @Option(help: "Handshake nonce.")
    var nonce: String?

    @Argument(parsing: .postTerminator, help: "Guest command; the executable is an absolute path in the guest.")
    var command: [String] = []

    func run() async throws {
        let validated = RunOptions.validate(
            root: root.root, image: image, workspace: workspace, cpus: cpus, memoryMiB: memoryMiB,
            relayPorts: relayPort, forwardedEnvironment: forwardEnv, command: command,
            handshakeDescriptor: handshakeFd, nonce: nonce,
            hostCPUs: ProcessInfo.processInfo.activeProcessorCount,
            hostMemoryMiB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
            imageNormalizer: MacVMImageName.normalize,
            minimumMemoryMiB: MacVMRun.minimumMemoryMiB
        )
        let options: RunOptions
        switch validated {
        case .failure(let error):
            report(error.description)
            throw ExitCode(MicroVMExit.usage)
        case .success(let value):
            options = value
        }
        throw ExitCode(await MacVMRunner(options: options, hostEnvironment: ProcessInfo.processInfo.environment).run())
    }
}

func fileSHA256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

func siblingExecutable(_ name: String) -> URL {
    let path = Bundle.main.executableURL?.resolvingSymlinksInPath()
        ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return path.deletingLastPathComponent().appendingPathComponent(name)
}
