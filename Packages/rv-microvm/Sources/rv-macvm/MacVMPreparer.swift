import Darwin
import Foundation
import RVMicroVMCore
import Synchronization
@preconcurrency import Virtualization

/// `rv-macvm prepare`: build one image unattended.
///
/// 1. Restore image: a local IPSW, a URL, or Apple's latest supported one.
/// 2. Install it into a fresh disk with `VZMacOSInstaller`.
/// 3. First boot with Apple's guest provisioning (user `rv`, a random
///    password held only in this process, SSH on) and a NAT network
///    device, the only boot that has one.
/// 4. One SSH session installs the agent daemon from a read-only share
///    and the key-only `sshd` session path, and the guest shuts down. The
///    password is discarded.
/// 5. `image.json` is written last and the staging directory renamed into
///    place (swapped with the old image for `--replace`), so a half-built
///    image is never visible to `run`.
struct MacVMPreparer {
    /// Approximate installed size; used for the free-space check.
    static let installedBytes: Int64 = 30 << 30

    let layout: MacVMLayout
    let name: MacVMImageName
    let ipsw: String?
    let diskGiB: Int
    let cpus: Int
    let memoryMiB: Int
    let agent: URL
    let keepIPSW: Bool
    let replace: Bool

    func prepare() async throws {
        let fm = FileManager.default
        guard replace || !fm.fileExists(atPath: layout.image(name).path) else {
            throw SetupError("image \(name) already exists at \(layout.image(name).path); pass --replace to rebuild it")
        }
        guard fm.isExecutableFile(atPath: agent.path) else {
            throw SetupError("guest agent not found at \(agent.path); build it with Scripts/build-microvm.sh")
        }
        try fm.createDirectory(at: layout.cache, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.images, withIntermediateDirectories: true)
        sweepStaging()

        let (restoreURL, downloaded) = try await restoreImage()
        defer { if downloaded, !keepIPSW { try? fm.removeItem(at: restoreURL) } }
        let restore = try await loadRestoreImage(restoreURL)
        guard let requirements = restore.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw SetupError("this Mac cannot run macOS \(versionString(restore.operatingSystemVersion)) guests")
        }
        guard restore.operatingSystemVersion.majorVersion >= 27 else {
            throw SetupError("unattended setup needs a macOS 27 or later restore image (got \(versionString(restore.operatingSystemVersion)))")
        }

        let staging = layout.images.appendingPathComponent(".staging-\(MacVMRunDirectory.name(pid: getpid()))", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: staging) } }
        let disk = staging.appendingPathComponent("disk.img")
        let auxiliary = staging.appendingPathComponent("aux.img")
        try createSparseDisk(disk, gib: diskGiB)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: auxiliary, hardwareModel: requirements.hardwareModel, options: [])

        let cpus = max(self.cpus, requirements.minimumSupportedCPUCount)
        let memoryMiB = max(self.memoryMiB, Int(requirements.minimumSupportedMemorySize >> 20))
        report("installing macOS \(versionString(restore.operatingSystemVersion)) (\(restore.buildVersion))")
        try await install(restoreURL, spec: MachineSpec(
            hardwareModel: requirements.hardwareModel, auxiliaryStorage: auxiliary, disk: disk,
            cpus: cpus, memoryMiB: memoryMiB, shares: [], networkMAC: nil
        ))

        let setupShare = staging.appendingPathComponent("setup", isDirectory: true)
        try fm.createDirectory(at: setupShare, withIntermediateDirectories: true)
        try fm.copyItem(at: agent, to: setupShare.appendingPathComponent(MacVMAgent.executableName))
        try Data(MacVMSetup.launchDaemonPlist.utf8).write(to: setupShare.appendingPathComponent(MacVMSetup.plistName))
        let agentHash = try fileSHA256(agent)
        report("first boot: provisioning user \(MacVMAgent.user) and installing the rv guest agent")
        let installedHash = try await provision(spec: MachineSpec(
            hardwareModel: requirements.hardwareModel, auxiliaryStorage: auxiliary, disk: disk,
            cpus: cpus, memoryMiB: memoryMiB,
            shares: [.init(tag: MacVMAgent.setupTag, path: setupShare.path, readOnly: true)],
            networkMAC: VZMACAddress.randomLocallyAdministered()
        ))
        guard installedHash == agentHash else {
            throw SetupError("the agent installed in the guest (\(installedHash)) does not match \(agent.path) (\(agentHash))")
        }
        try fm.removeItem(at: setupShare)

        let record = MacVMImageRecord(
            hardwareModel: requirements.hardwareModel.dataRepresentation,
            osVersion: versionString(restore.operatingSystemVersion),
            osBuild: restore.buildVersion,
            agentSHA256: agentHash,
            user: MacVMAgent.user
        )
        try JSONEncoder().encode(record).write(to: staging.appendingPathComponent("image.json"))
        try commit(staging)
        committed = true
        report("image \(name) is ready")
    }

    /// Moves `staging` into place. An existing image is swapped out in one
    /// step, so `run` sees the old image or the new one, never neither, and
    /// the old one is then deleted with the staging directory. Runs already
    /// started use their own clones.
    private func commit(_ staging: URL) throws {
        let image = layout.image(name)
        guard FileManager.default.fileExists(atPath: image.path) else {
            try FileManager.default.moveItem(at: staging, to: image)
            return
        }
        guard replace else { throw SetupError("image \(name) appeared while preparing; pass --replace to rebuild it") }
        guard renamex_np(staging.path, image.path, UInt32(RENAME_SWAP)) == 0 else {
            throw SetupError("cannot swap in the new image: \(String(cString: strerror(errno)))")
        }
        try? FileManager.default.removeItem(at: staging)
    }

    /// Staging directories of prepares that died (each can hold ~30 GB).
    private func sweepStaging() {
        let prefix = ".staging-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.images.path)) ?? []
        let owned = names.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        for stale in MacVMRunDirectory.stale(owned, isAlive: { kill($0, 0) == 0 || errno == EPERM }) {
            report("removing the staging directory of an interrupted prepare")
            try? FileManager.default.removeItem(at: layout.images.appendingPathComponent(prefix + stale))
        }
    }

    // MARK: restore image

    private func restoreImage() async throws -> (URL, downloaded: Bool) {
        if let ipsw, !ipsw.contains("://") {
            let url = URL(fileURLWithPath: ipsw)
            guard FileManager.default.fileExists(atPath: url.path) else { throw SetupError("no restore image at \(ipsw)") }
            try requireFreeSpace(downloadBytes: 0)
            return (url, false)
        }
        let remote: URL
        if let ipsw {
            guard let url = URL(string: ipsw), url.scheme == "https" else { throw SetupError("--ipsw URL must be https") }
            remote = url
        } else {
            remote = try await latestSupportedURL()
        }
        let target = layout.cache.appendingPathComponent(remote.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            try requireFreeSpace(downloadBytes: 0)
            return (target, false)
        }
        report("checking the size of \(remote.lastPathComponent)")
        try requireFreeSpace(downloadBytes: await contentLength(remote) ?? (26 << 30))
        report("downloading \(remote.absoluteString)")
        try await Downloader().download(remote, to: target)
        return (target, true)
    }

    private func latestSupportedURL() async throws -> URL {
        report("asking Apple for the latest supported macOS restore image")
        let answer = Mutex<CheckedContinuation<URL, Error>?>(nil)
        let timeout = Task {
            try await Task.sleep(for: .seconds(60))
            answer.withLock { $0.take() }?.resume(throwing: SetupError(
                "Apple's restore image catalog did not answer within 60 s; pass --ipsw PATH or URL"
            ))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            answer.withLock { $0 = continuation }
            VZMacOSRestoreImage.fetchLatestSupported { result in
                guard let continuation = answer.withLock({ $0.take() }) else { return }
                switch result {
                case .success(let image): continuation.resume(returning: image.url)
                case .failure(let error):
                    continuation.resume(throwing: SetupError(
                        "Apple's restore image catalog is unavailable (\(error.localizedDescription)); pass --ipsw PATH or URL"
                    ))
                }
            }
        }
    }

    private func loadRestoreImage(_ url: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RestoreImageBox, Error>) in
            VZMacOSRestoreImage.load(from: url) { result in continuation.resume(with: result.map(RestoreImageBox.init)) }
        }.image
    }

    private func contentLength(_ url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let length = response.expectedContentLength
        return length > 0 ? length : nil
    }

    private func requireFreeSpace(downloadBytes: Int64) throws {
        let values = try layout.root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        let needed = downloadBytes + Self.installedBytes
        guard free >= needed else {
            throw SetupError("preparing needs about \(needed >> 30) GB free on this volume and \(free >> 30) GB are available")
        }
    }

    // MARK: install and provision

    private func createSparseDisk(_ url: URL, gib: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw SetupError("cannot create \(url.path)") }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(gib) << 30)
    }

    private func install(_ restore: URL, spec: MachineSpec) async throws {
        let machine = Machine(try spec.configuration())
        nonisolated(unsafe) var installer: VZMacOSInstaller!
        machine.onQueue { installer = VZMacOSInstaller(virtualMachine: machine.virtualMachine, restoringFromImageAt: restore) }
        let progress = Task {
            var last = -1
            while !Task.isCancelled {
                let percent = Int(machine.onQueue { installer.progress.fractionCompleted } * 100)
                if percent / 10 != last / 10 {
                    report("install \(percent)%")
                    last = percent
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        defer { progress.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            machine.onQueue {
                installer.install { result in continuation.resume(with: result) }
            }
        }
    }

    /// Starts a machine for `spec`, retrying while the installer's VM service
    /// still holds the storage lock (a failed start needs a fresh machine).
    private func startWhenStorageIsFree(spec: MachineSpec, options: VZMacOSVirtualMachineStartOptions) async throws -> Machine {
        let deadline = Date().addingTimeInterval(60)
        while true {
            let machine = Machine(try spec.configuration())
            do {
                try await machine.start(options)
                return machine
            } catch where MacVMSetup.isStorageStillLocked(error) && Date() < deadline {
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// First boot. Returns the agent hash the guest reported.
    private func provision(spec: MachineSpec) async throws -> String {
        let password = randomPassword()
        let options = VZMacOSVirtualMachineStartOptions()
        try applyProvisioning(options, password: password)
        let machine = try await startWhenStorageIsFree(spec: spec, options: options)
        do {
            guard let mac = spec.networkMAC?.string else { throw SetupError("the setup boot has no network device") }
            let address = try await guestAddress(mac: mac)
            report("guest is at \(address); waiting for SSH")
            try await waitForPort(address, 22, seconds: 900)
            let output = try await runSetup(address: address, password: password)
            guard let hash = MacVMSetup.agentHash(fromOutput: output) else {
                throw SetupError("guest setup failed:\n\(output.suffix(2000))")
            }
            report("agent installed; the guest is shutting down")
            // A forced stop may leave the disk unflushed: never commit it.
            guard machine.waitStopped(seconds: 300) else {
                throw SetupError("the guest did not shut down within 300 s after setup; the image was not saved")
            }
            return hash
        } catch {
            await machine.stop()
            throw error
        }
    }

    private func applyProvisioning(_ options: VZMacOSVirtualMachineStartOptions, password: String) throws {
        #if canImport(Virtualization, _version: 308)
        if #available(macOS 27, *) {
            let provisioning = VZMacGuestProvisioningOptions()
            provisioning.fullName = "rv"
            provisioning.username = MacVMAgent.user
            provisioning.password = password
            provisioning.logsInAutomatically = false
            provisioning.enablesRemoteLogin = true
            try options.setGuestProvisioning(provisioning)
            return
        }
        #endif
        throw SetupError("unattended setup needs macOS 27 on this Mac and an rv-macvm built with the macOS 27 SDK")
    }

    private func guestAddress(mac: String) async throws -> String {
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            if let leases = try? String(contentsOfFile: DHCPLeases.path, encoding: .utf8),
                let address = DHCPLeases.address(forMAC: mac, in: leases)
            {
                return address
            }
            try await Task.sleep(for: .seconds(5))
        }
        throw SetupError("the guest never requested a network address (no DHCP lease for \(mac))")
    }

    private func waitForPort(_ host: String, _ port: Int, seconds: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if let fd = connectTCP(host, port) {
                close(fd)
                return
            }
            try await Task.sleep(for: .seconds(5))
        }
        throw SetupError("SSH on \(host) did not open within \(seconds) s")
    }

    /// The setup script over SSH. Retries while the account is still being
    /// provisioned (authentication fails until it exists).
    private func runSetup(address: String, password: String) async throws -> String {
        var last = ""
        for attempt in 1...20 {
            let (status, output) = try await ssh(
                address: address, password: password,
                input: "\(password)\n" + MacVMSetup.script,
                command: "sudo -S -p '' /bin/sh -s"
            )
            if status == 0 { return output }
            last = output
            if status != 255 { break }
            report("SSH attempt \(attempt) failed; retrying")
            try await Task.sleep(for: .seconds(15))
        }
        throw SetupError("guest setup over SSH failed:\n\(last.suffix(2000))")
    }

    /// `ssh` with the password supplied through `SSH_ASKPASS` (this binary's
    /// `askpass` verb reading its environment) and `input` on stdin. The
    /// password is never in argv or on disk. The user's ssh configuration is
    /// ignored (`-F /dev/null`), and a session that stops answering or runs
    /// past `sshDeadlineSeconds` is terminated.
    ///
    /// Host keys are not checked: the guest is new, its key unknown, and it
    /// sits on this Mac's private NAT. The password is random, single-use,
    /// and belongs to an account that exists only in this image.
    private func ssh(address: String, password: String, input: String, command: String) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-F", "/dev/null", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
            "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=keyboard-interactive,password",
            "-o", "NumberOfPasswordPrompts=1", "-o", "ConnectTimeout=20",
            "\(MacVMAgent.user)@\(address)", command,
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "SSH_ASKPASS": siblingExecutable("rv-macvm").path,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": "rv-macvm",
            MacVMSetup.askpassVariable: password,
        ]
        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Self.sshDeadlineSeconds), execute: deadline)
        defer { deadline.cancel() }
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static let sshDeadlineSeconds = 1800

    private func randomPassword() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in alphabet.randomElement(using: &generator)! })
    }


    private func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
    }
}

struct RestoreImageBox: @unchecked Sendable {
    let image: VZMacOSRestoreImage
}

/// `connect` to an IPv4 host and port; nil on failure.
func connectTCP(_ host: String, _ port: Int) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
        close(fd)
        return nil
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else {
        close(fd)
        return nil
    }
    return fd
}

/// Restore image download into `<destination>.partial`, resumed with an
/// HTTP Range request if a previous download was interrupted, renamed to
/// `destination` only when complete. Progress goes to stderr.
final class Downloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: FileHandle?
    private var partial: URL?
    private var received: Int64 = 0
    private var expected: Int64 = 0
    private var lastDecile = -1

    func download(_ url: URL, to destination: URL) async throws {
        let partial = destination.appendingPathExtension("partial")
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let existing = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        var request = URLRequest(url: url)
        // Byte ranges must address the file itself, not a compressed encoding.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
            report("resuming at \(existing >> 20) MiB")
        }
        self.partial = partial
        self.received = existing
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { self.continuation = continuation }
            session.dataTask(with: request).resume()
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode), let partial else {
            finish(SetupError("download failed with HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
            return completionHandler(.cancel)
        }
        do {
            let handle = try FileHandle(forWritingTo: partial)
            if http.statusCode == 200 {
                // The server ignored the range: start over.
                try handle.truncate(atOffset: 0)
                received = 0
            } else {
                try handle.seekToEnd()
            }
            self.handle = handle
            expected = received + max(0, response.expectedContentLength)
            completionHandler(.allow)
        } catch {
            finish(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            finish(SetupError("cannot write the restore image: \(error.localizedDescription)"))
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        guard expected > 0 else { return }
        let decile = Int(received * 10 / expected)
        if decile != lastDecile {
            lastDecile = decile
            report("download \(decile * 10)% of \(expected >> 20) MiB")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let error {
            finish(SetupError("download failed: \(error.localizedDescription); run prepare again to resume"))
        } else if expected > 0, received != expected {
            finish(SetupError("download ended at \(received) of \(expected) bytes; run prepare again to resume"))
        } else {
            finish(nil)
        }
    }

    private func finish(_ error: Error?) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { continuation = nil }
            return continuation
        }
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
