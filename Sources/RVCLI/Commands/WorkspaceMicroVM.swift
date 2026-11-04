import ArgumentParser
import Foundation
import RVIsolation

/// `rv workspace run --microvm`: option validation and image preparation.
///
/// The workspace host launches the VM; this side only makes sure the image
/// is cached first, so the launch itself never touches the network.
enum WorkspaceMicroVM {
    static func options(image: String?, cpus: Int?, memoryMiB: Int?) throws -> MicroVMLaunchOptions? {
        guard let image else {
            if cpus != nil || memoryMiB != nil {
                throw ValidationError("--cpus and --memory-mib require --microvm")
            }
            return nil
        }
        guard let options = MicroVMLaunchOptions(image: image, cpus: cpus, memoryMiB: memoryMiB) else {
            throw ValidationError(
                "--microvm needs an image reference; --cpus must be \(MicroVMLaunchOptions.cpuRange.lowerBound)-\(MicroVMLaunchOptions.cpuRange.upperBound) and --memory-mib \(MicroVMLaunchOptions.memoryRangeMiB.lowerBound) or more"
            )
        }
        return options
    }

    static func statusArguments(image: String) -> [String] { ["status", "--image", image] }
    static func prepareArguments(image: String) -> [String] { ["prepare", "--image", image] }

    /// Cheap offline check first; download and unpack only when it fails.
    /// `prepare` reports its own progress on stderr.
    static func ensurePrepared(_ options: MicroVMLaunchOptions, project: String) throws {
        guard let helper = MicroVMHelper.locate(workspace: project) else {
            throw ValidationError(
                "micro-VM launches need \(MicroVMHelper.executableName) next to rv; reinstall rv or run Scripts/build-microvm.sh"
            )
        }
        if try run(helper, statusArguments(image: options.image), quiet: true) == 0 { return }
        let status = try run(helper, prepareArguments(image: options.image), quiet: false)
        guard status == 0 else {
            throw ValidationError("micro-VM image \(options.image) could not be prepared (rv-microvm exit \(status))")
        }
    }

    private static func run(_ helper: String, _ arguments: [String], quiet: Bool) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = quiet ? FileHandle.nullDevice : FileHandle.standardError
        process.standardError = quiet ? FileHandle.nullDevice : FileHandle.standardError
        do {
            try process.run()
        } catch {
            throw ValidationError("cannot start \(helper): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
