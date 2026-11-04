import Darwin
import Foundation
import RVMicroVMCore
import Synchronization
@preconcurrency import Virtualization

struct SetupError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func report(_ message: String) {
    FileHandle.standardError.write(Data("rv-macvm: \(message)\n".utf8))
}

/// What one macOS guest boots with.
struct MachineSpec {
    struct Share {
        let tag: String
        let path: String
        let readOnly: Bool
    }

    let hardwareModel: VZMacHardwareModel
    let auxiliaryStorage: URL
    let disk: URL
    let cpus: Int
    let memoryMiB: Int
    let shares: [Share]
    /// Only the setup boot has a network device (NAT, for one SSH session).
    let networkMAC: VZMACAddress?

    func configuration() throws -> VZVirtualMachineConfiguration {
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        // A fresh identity per boot: concurrent clones must not share one.
        platform.machineIdentifier = VZMacMachineIdentifier()
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxiliaryStorage)

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = cpus
        configuration.memorySize = UInt64(memoryMiB) << 20
        let attachment = try VZDiskImageStorageDeviceAttachment(
            url: disk, readOnly: false, cachingMode: .automatic, synchronizationMode: .full
        )
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.directorySharingDevices = shares.map { share in
            let device = VZVirtioFileSystemDeviceConfiguration(tag: share.tag)
            device.share = VZSingleDirectoryShare(
                directory: VZSharedDirectory(url: URL(fileURLWithPath: share.path, isDirectory: true), readOnly: share.readOnly)
            )
            return device
        }
        if let networkMAC {
            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
            network.macAddress = networkMAC
            configuration.networkDevices = [network]
        } else {
            configuration.networkDevices = []
        }
        try configuration.validate()
        return configuration
    }
}

/// A running guest. Every Virtualization call happens on `queue`.
final class Machine: NSObject, VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "rv-macvm.machine")
    private let machine: VZVirtualMachine
    private let stopped = DispatchSemaphore(value: 0)
    private let listeners = Mutex<[UInt32: @Sendable (VZVirtioSocketConnection) -> Void]>([:])
    private let socketListener = VZVirtioSocketListener()

    init(_ configuration: VZVirtualMachineConfiguration) {
        machine = VZVirtualMachine(configuration: configuration, queue: queue)
        super.init()
        queue.sync {
            machine.delegate = self
            socketListener.delegate = self
        }
    }

    var virtualMachine: VZVirtualMachine { machine }
    func onQueue<T>(_ body: () throws -> T) rethrows -> T { try queue.sync(execute: body) }

    func start(_ startOptions: VZMacOSVirtualMachineStartOptions = VZMacOSVirtualMachineStartOptions()) async throws {
        nonisolated(unsafe) let options = startOptions
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.machine.start(options: options) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
    }

    /// Hard stop; the clone is discarded, so nothing needs flushing.
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard self.machine.canStop else { return continuation.resume() }
                self.machine.stop { _ in continuation.resume() }
            }
        }
    }

    /// True if the guest shut itself down within `seconds`.
    func waitStopped(seconds: Int) -> Bool {
        stopped.wait(timeout: .now() + .seconds(seconds)) == .success
    }

    func connect(port: UInt32) async throws -> VZVirtioSocketConnection {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ConnectionBox, Error>) in
            queue.async {
                guard let device = self.machine.socketDevices.first as? VZVirtioSocketDevice else {
                    return continuation.resume(throwing: SetupError("the guest has no socket device"))
                }
                device.connect(toPort: port) { result in
                    continuation.resume(with: result.map(ConnectionBox.init))
                }
            }
        }.connection
    }

    /// Guest connections to host vsock `port` go to `handler`.
    func listen(port: UInt32, handler: @escaping @Sendable (VZVirtioSocketConnection) -> Void) {
        listeners.withLock { $0[port] = handler }
        queue.sync {
            (machine.socketDevices.first as? VZVirtioSocketDevice)?.setSocketListener(socketListener, forPort: port)
        }
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        guard let handler = listeners.withLock({ $0[connection.destinationPort] }) else { return false }
        nonisolated(unsafe) let accepted = connection
        Thread.detachNewThread { handler(accepted) }
        return true
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        stopped.signal()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        report("guest stopped: \(error.localizedDescription)")
        stopped.signal()
    }
}

/// A connection handed from the machine queue to the caller, who then owns it.
struct ConnectionBox: @unchecked Sendable {
    let connection: VZVirtioSocketConnection
}

/// Bridges one vsock connection to host `127.0.0.1:port`. The connection
/// object stays alive until both directions end.
func bridgeToLoopback(_ connection: VZVirtioSocketConnection, port: Int, budget: BridgeBudget) {
    defer { connection.close() }
    guard budget.tryAcquire() else { return }
    defer { budget.release() }
    let guest = dup(connection.fileDescriptor)
    guard guest >= 0 else { return }
    guard let upstream = connectLoopback(port: port) else {
        close(guest)
        return
    }
    SocketBridge.bridge(client: guest, upstream: upstream)
}

/// clonefile(2): copy-on-write, so a run costs only what the guest writes.
/// Clones `name` in the directory open as `directory`.
func cloneFile(at directory: Int32, _ name: String, to destination: URL) throws {
    guard clonefileat(directory, name, AT_FDCWD, destination.path, 0) == 0 else {
        throw SetupError("cannot clone the image's \(name): \(String(cString: strerror(errno))) (the state root must be on APFS)")
    }
}
