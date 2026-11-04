import Foundation

/// Pinned guest assets. The kernel is the same archive, member and digest
/// that apple/container 1.6.1 installs as its recommended kernel. The init
/// image tag must equal the Containerization package version in
/// `Package.swift`: vminitd speaks that library's gRPC API.
public enum MicroVMPins {
    public static let kernelArchiveURL = URL(
        string: "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst"
    )!
    public static let kernelArchiveSHA256 = "8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5"
    public static let kernelMemberPath = "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug"
    /// Digest of the extracted kernel. Checked after extraction and when a
    /// cached kernel is reused by `prepare`.
    public static let kernelSHA256 = "fb2cfb79eb1ae19447a85d75682d7fa5cfec97e24beb2609a492b806e8072c8d"
    /// Manifest-list digest that `vminit:0.54.0` resolved to on 2026-11-03.
    /// Pulled by digest alone (a reference with a tag would resolve the
    /// mutable tag), and Containerization refuses substituted content.
    public static let initImageDigest = "sha256:ab76bf71fbedcbf67a54dc5f37b0acefd68b1ba090d93f752f8e27c9961a685c"
    public static let initImageReference = "ghcr.io/apple/containerization/vminit@\(initImageDigest)"
    /// Version tag used in cached file names, so a pin bump never reuses a
    /// stale init filesystem.
    public static let initImageTag = "0.54.0"
}

/// On-disk layout under the micro-VM state root (`~/.config/rv/microvm`).
public struct MicroVMLayout: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var kernelDirectory: URL { root.appendingPathComponent("kernel", isDirectory: true) }
    public var kernel: URL { kernelDirectory.appendingPathComponent("vmlinux") }
    public var initfs: URL {
        root.appendingPathComponent("initfs", isDirectory: true)
            .appendingPathComponent("vminit-\(MicroVMPins.initImageTag)-\(MicroVMDigest.hex(MicroVMPins.initImageDigest) ?? "invalid").ext4")
    }
    /// Containerization `ImageStore` root. Containers live under `containers/`.
    public var store: URL { root.appendingPathComponent("store", isDirectory: true) }
    public var containers: URL { store.appendingPathComponent("containers", isDirectory: true) }
    public var rootfsCache: URL { root.appendingPathComponent("rootfs", isDirectory: true) }
    /// Read-only share mounted at `/.rv` in every guest.
    public var guestTools: URL { root.appendingPathComponent("guest", isDirectory: true) }
    public var guestRelay: URL { guestTools.appendingPathComponent(MicroVMGuest.relayName) }
    public var lockFile: URL { root.appendingPathComponent(".lock") }

    /// Cached root filesystem for one image manifest digest (`sha256:<hex>`).
    public func rootfs(forDigest digest: String) -> URL? {
        guard let hex = MicroVMDigest.hex(digest) else { return nil }
        return rootfsCache.appendingPathComponent("\(hex).ext4")
    }
}

public enum MicroVMDigest {
    /// The hex part of `sha256:<64 hex>`, or nil for anything else.
    public static func hex(_ digest: String) -> String? {
        let prefix = "sha256:"
        guard digest.hasPrefix(prefix) else { return nil }
        let hex = digest.dropFirst(prefix.count)
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else {
            return nil
        }
        return String(hex)
    }
}

/// Fixed guest-side names.
public enum MicroVMGuest {
    public static let relayName = "rv-guest-relay"
    public static let toolsMount = "/.rv"
    public static var relayPath: String { "\(toolsMount)/\(relayName)" }
    public static let socketDirectory = "/run/rv"
    public static let hostname = "rv-microvm"
    public static let home = "/root"
    public static let defaultPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    /// vminitd creates a guest pty at 0x0 and the host can resize it only
    /// after the process starts, so terminal launches exec through the
    /// helper, which waits for the first resize.
    public static func commandArguments(_ command: [String], terminal: Bool) -> [String] {
        terminal ? [relayPath, "--exec-sized"] + command : command
    }
}

/// Exit statuses `rv-microvm run` reserves. Guest statuses pass through.
public enum MicroVMExit {
    /// Nothing ran in a guest: a prerequisite, the VM, or the guest process
    /// failed before the handshake. Same value as rv-isolation-exec's
    /// could-not-establish exit.
    public static let couldNotEstablish: Int32 = 125
    /// Command-line usage error.
    public static let usage: Int32 = 64

    /// Guest exit codes are reported as 0...255. A signalled guest process
    /// already arrives as 128+n from vminitd.
    public static func status(fromGuest code: Int32) -> Int32 {
        if code < 0 { return 128 }
        return min(code, 255)
    }
}
