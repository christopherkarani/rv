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

    /// Why a VM image is not ready to launch. `message` is the text
    /// `rv workspace run` prints; `rv box` words it its own way.
    enum Unready: Error, Equatable {
        /// `rv-microvm` / `rv-macvm` is not next to rv.
        case helperMissing(MicroVMGuest)
        /// A macOS image is built only on request (about 26 GB).
        case notPrepared(MicroVMLaunchOptions)
        /// Preparing the image failed with the helper's exit status.
        case prepareFailed(MicroVMLaunchOptions, status: Int32)
        /// The helper could not be started at all.
        case helperUnstartable(path: String, detail: String)

        var message: String {
            switch self {
            case .helperMissing(.linux):
                "VM launches need \(MicroVMHelper.executableName(for: .linux)) next to rv; reinstall rv or run Scripts/build-microvm.sh"
            case .helperMissing(.macOS):
                // Releases built with an SDK older than macOS 27 leave it out.
                "macOS VM launches need \(MicroVMHelper.executableName(for: .macOS)) next to rv, and this rv was built without it; "
                    + "build it with Scripts/build-microvm.sh using the macOS 27 SDK"
            case .notPrepared(let options):
                "macOS image \(options.image) is not prepared; build it once with: \(prepareInstruction(options))"
            case .prepareFailed(let options, let status) where options.guest == .macOS:
                "macOS image \(options.image) could not be prepared (\(MicroVMHelper.executableName(for: .macOS)) exit \(status))"
            case .prepareFailed(let options, let status):
                "micro-VM image \(options.image) could not be prepared (rv-microvm exit \(status))"
            case .helperUnstartable(let path, let detail):
                "cannot start \(path): \(detail)"
            }
        }
    }

    /// Cheap offline check first; for Linux, download and unpack only when
    /// it fails. `prepare` reports its own progress on stderr. A macOS
    /// image's status warns on stderr when its guest agent is not this rv's.
    static func ensurePrepared(_ options: MicroVMLaunchOptions, project: String) throws {
        do throws(Unready) {
            try ensureReady(options, project: project)
        } catch {
            throw ValidationError(error.message)
        }
    }

    /// `ensurePrepared` with the reason kept as a value.
    static func ensureReady(_ options: MicroVMLaunchOptions, project: String) throws(Unready) {
        guard let helper = MicroVMHelper.locate(workspace: project, guest: options.guest) else {
            throw .helperMissing(options.guest)
        }
        let warns = options.guest == .macOS
        if try run(helper, statusArguments(image: options.image), output: false, errors: warns) == 0 { return }
        guard preparesImplicitly(options) else {
            throw .notPrepared(options)
        }
        let status = try run(helper, prepareArguments(image: options.image), output: true, errors: true)
        guard status == 0 else {
            throw .prepareFailed(options, status: status)
        }
    }

    /// What `prepare` found or did.
    enum Prepared: Equatable {
        /// `status` said the image is ready; nothing was built.
        case alreadyReady
        /// The image was built or pulled now.
        case built
    }

    /// Builds or pulls the image now, in the foreground, with the helper's
    /// progress on stderr (`rv box setup mac`). An image that is already
    /// ready is left alone: the helper refuses to prepare over one.
    static func prepare(
        _ options: MicroVMLaunchOptions, project: String, willBuild: () -> Void = {}
    ) throws(Unready) -> Prepared {
        try prepare(
            options, helper: MicroVMHelper.locate(workspace: project, guest: options.guest), willBuild: willBuild,
            runHelper: { (helper: String, arguments: [String], output: Bool, errors: Bool) throws(Unready) -> Int32 in
                try run(helper, arguments, output: output, errors: errors)
            })
    }

    /// `prepare` with the helper run passed in: `(path, arguments, show
    /// stdout, show stderr) -> exit status`.
    static func prepare(
        _ options: MicroVMLaunchOptions, helper: String?, willBuild: () -> Void,
        runHelper: (String, [String], Bool, Bool) throws(Unready) -> Int32
    ) throws(Unready) -> Prepared {
        guard let helper else { throw .helperMissing(options.guest) }
        if try runHelper(helper, statusArguments(image: options.image), false, options.guest == .macOS) == 0 {
            return .alreadyReady
        }
        willBuild()
        let status = try runHelper(helper, prepareArguments(image: options.image), true, true)
        guard status == 0 else {
            throw .prepareFailed(options, status: status)
        }
        return .built
    }

    /// `output` and `errors` choose which of the helper's streams reach rv's stderr.
    private static func run(_ helper: String, _ arguments: [String], output: Bool, errors: Bool) throws(Unready) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output ? FileHandle.standardError : FileHandle.nullDevice
        process.standardError = errors ? FileHandle.standardError : FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw .helperUnstartable(path: helper, detail: error.localizedDescription)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
