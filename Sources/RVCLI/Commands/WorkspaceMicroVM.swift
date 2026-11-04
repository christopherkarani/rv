import ArgumentParser
import Foundation
import RVIsolation

/// `rv workspace run --microvm`: option validation and image preparation.
///
/// The workspace host launches the VM; this side only makes sure the image
/// is cached first, so the launch itself never touches the network.
enum WorkspaceMicroVM {
    static func options(image: String?, macOSImage: String?, cpus: Int?, memoryMiB: Int?) throws -> MicroVMLaunchOptions? {
        switch (image, macOSImage) {
        case (nil, nil):
            if cpus != nil || memoryMiB != nil {
                throw ValidationError("--cpus and --memory-mib require --microvm or --macvm")
            }
            return nil
        case (.some, .some):
            throw ValidationError("--microvm and --macvm are mutually exclusive")
        case (let image?, nil):
            guard let options = MicroVMLaunchOptions(image: image, cpus: cpus, memoryMiB: memoryMiB) else {
                throw ValidationError(
                    "--microvm needs an image reference; --cpus must be \(MicroVMLaunchOptions.cpuRange.lowerBound)-\(MicroVMLaunchOptions.cpuRange.upperBound) and --memory-mib \(MicroVMLaunchOptions.memoryRangeMiB.lowerBound) or more"
                )
            }
            return options
        case (nil, let name?):
            guard let options = MicroVMLaunchOptions(image: name, guest: .macOS, cpus: cpus, memoryMiB: memoryMiB) else {
                throw ValidationError(
                    "--macvm needs a prepared image name (1-\(MicroVMLaunchOptions.macOSImageNameBytes) lowercase letters, digits or '-'); --cpus must be \(MicroVMLaunchOptions.cpuRange.lowerBound)-\(MicroVMLaunchOptions.cpuRange.upperBound) and --memory-mib \(MicroVMLaunchOptions.macOSMinimumMemoryMiB) or more"
                )
            }
            return options
        }
    }

    static func statusArguments(image: String) -> [String] { ["status", "--image", image] }
    static func prepareArguments(image: String) -> [String] { ["prepare", "--image", image] }

    /// A Linux image is pulled on first use. A macOS image is a ~26 GB
    /// download plus an install, so it is only ever built on request.
    static func preparesImplicitly(_ options: MicroVMLaunchOptions) -> Bool { options.guest == .linux }

    static func prepareInstruction(_ options: MicroVMLaunchOptions) -> String {
        ([MicroVMHelper.executableName(for: options.guest)] + prepareArguments(image: options.image)).joined(separator: " ")
    }

    /// Cheap offline check first; for Linux, download and unpack only when
    /// it fails. `prepare` reports its own progress on stderr. A macOS
    /// image's status warns on stderr when its guest agent is not this rv's.
    static func ensurePrepared(_ options: MicroVMLaunchOptions, project: String) throws {
        let name = MicroVMHelper.executableName(for: options.guest)
        guard let helper = MicroVMHelper.locate(workspace: project, guest: options.guest) else {
            switch options.guest {
            case .linux:
                throw ValidationError("VM launches need \(name) next to rv; reinstall rv or run Scripts/build-microvm.sh")
            case .macOS:
                // Releases built with an SDK older than macOS 27 leave it out.
                throw ValidationError(
                    "macOS VM launches need \(name) next to rv, and this rv was built without it; "
                        + "build it with Scripts/build-microvm.sh using the macOS 27 SDK"
                )
            }
        }
        let warns = options.guest == .macOS
        if try run(helper, statusArguments(image: options.image), output: false, errors: warns) == 0 { return }
        guard preparesImplicitly(options) else {
            throw ValidationError(
                "macOS image \(options.image) is not prepared; build it once with: \(prepareInstruction(options))"
            )
        }
        let status = try run(helper, prepareArguments(image: options.image), output: true, errors: true)
        guard status == 0 else {
            throw ValidationError("micro-VM image \(options.image) could not be prepared (rv-microvm exit \(status))")
        }
    }

    /// `output` and `errors` choose which of the helper's streams reach rv's stderr.
    private static func run(_ helper: String, _ arguments: [String], output: Bool, errors: Bool) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output ? FileHandle.standardError : FileHandle.nullDevice
        process.standardError = errors ? FileHandle.standardError : FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ValidationError("cannot start \(helper): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
