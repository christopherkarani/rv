#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// Correlates secret use without storing the value: the first 16 hex digits
/// of HMAC-SHA256 under a per-install key (`~/.config/rv/audit.key`, 0600).
/// Two events with the same fingerprint used the same value; the key never
/// leaves the machine, so the fingerprint cannot be brute-forced offline.
public struct SecretFingerprinter: Sendable {
    public static let keyFileName = "audit.key"

    let key: [UInt8]

    init(key: [UInt8]) {
        self.key = key
    }

    func fingerprint(_ value: SecretValue) -> String? {
        #if canImport(CryptoKit)
        let mac = HMAC<SHA256>.authenticationCode(for: value.bytes, using: SymmetricKey(data: key))
        return mac.prefix(8).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    /// Loads the install key, creating it (32 random bytes, 0600) if absent.
    public static func load(configDirectory: URL) -> SecretFingerprinter? {
        let url = configDirectory.appendingPathComponent(keyFileName, isDirectory: false)
        if let key = readKey(url) { return SecretFingerprinter(key: key) }
        try? FileManager.default.createDirectory(
            at: configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var key = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in key.indices { key[index] = generator.next() }
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            // Lost a creation race: use the winner's key.
            return readKey(url).map(SecretFingerprinter.init(key:))
        }
        defer { close(fd) }
        let written = key.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == key.count, fsync(fd) == 0 else { return nil }
        return SecretFingerprinter(key: key)
    }

    private static func readKey(_ url: URL) -> [UInt8]? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
            (info.st_mode & 0o077) == 0, info.st_size == 32
        else { return nil }
        var key = [UInt8](repeating: 0, count: 32)
        let count = key.withUnsafeMutableBytes { read(fd, $0.baseAddress, 32) }
        return count == 32 ? key : nil
    }
}
