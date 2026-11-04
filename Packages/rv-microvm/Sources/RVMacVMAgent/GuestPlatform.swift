import Darwin
import Foundation
import RVMicroVMCore

/// AF_VSOCK in the guest: the agent's listener and relay connections to
/// the host (CID 2).
public enum Vsock {
    public static func listen(port: UInt32) -> Result<Int32, AgentError> {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(AgentError("cannot create vsock socket: \(String(cString: strerror(errno)))")) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = Self.address(cid: UInt32(bitPattern: -1), port: port)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            let message = "cannot listen on vsock port \(port): \(String(cString: strerror(errno)))"
            close(fd)
            return .failure(AgentError(message))
        }
        return .success(fd)
    }

    /// The host's context ID. Only it may open agent sessions: a guest
    /// process connecting to the agent locally could otherwise send its own
    /// exec request with a permissive profile.
    public static let hostCID: UInt32 = 2

    /// Next connection from the host; connections from anyone else are
    /// closed. Nil when the listener fails.
    public static func acceptHost(_ listener: Int32) -> Int32? {
        while true {
            var peer = sockaddr_vm()
            var length = socklen_t(MemoryLayout<sockaddr_vm>.size)
            let client = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
            }
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return nil
            }
            if peer.svm_family == sa_family_t(AF_VSOCK), peer.svm_cid == hostCID { return client }
            close(client)
        }
    }

    public static func connectHost(port: UInt32) -> Int32? {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = Self.address(cid: 2, port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func address(cid: UInt32, port: UInt32) -> sockaddr_vm {
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_port = port
        address.svm_cid = cid
        return address
    }
}

/// The workspace share at the workspace's own path, owned in the guest by
/// `owner` so the guest user can write it whatever the host uid is.
public enum GuestMount {
    public static func workspace(_ path: String, owner: String) -> String? {
        guard let entry = getpwnam(owner) else { return "no guest user \(owner)" }
        let uid = entry.pointee.pw_uid
        let gid = entry.pointee.pw_gid
        if mountProblem(path) == nil { return nil }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            return "cannot create \(path): \(error.localizedDescription)"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount_virtiofs")
        process.arguments = ["-u", String(uid), "-g", String(gid), MacVMAgent.workspaceTag, path]
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return "cannot run mount_virtiofs: \(error.localizedDescription)"
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return "mount_virtiofs exited \(process.terminationStatus): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return mountProblem(path).map { "after mounting, \($0)" }
    }

    /// Nil when `path` is itself a virtiofs mount; otherwise what it is.
    static func mountProblem(_ path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return "\(path): \(String(cString: strerror(errno)))" }
        let type = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let mountPoint = withUnsafeBytes(of: info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard type == virtiofsType, mountPoint == path else {
            return "\(path) is on a \(type) mount at \(mountPoint), not its own virtiofs mount"
        }
        return nil
    }

    /// `f_fstypename` of a `mount_virtiofs` mount in a macOS guest.
    static let virtiofsType = "AppleVirtIOFS"
}
