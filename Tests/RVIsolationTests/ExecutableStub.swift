import Foundation

/// Writes a fake CLI that a test then runs, mode 0755.
///
/// Exec fails with ETXTBSY while any process holds the file open for
/// writing. `Data.write(to:)` opens without O_CLOEXEC, so a child that
/// another suite's thread spawns during the write inherits the descriptor
/// and keeps it as long as it runs (several suites `posix_spawn` with no
/// file actions). The provider then cannot start the fake, and reports the
/// launch failure as a timeout. With O_CLOEXEC a spawned child drops the
/// descriptor at its own exec.
func writeExecutableStub(_ source: String, to url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw stubError(errno, url) }
    var closed = false
    defer { if !closed { close(fd) } }
    let bytes = Array(source.utf8)
    var offset = 0
    while offset < bytes.count {
        let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
        if count < 0 {
            if errno == EINTR { continue }
            throw stubError(errno, url)
        }
        offset += count
    }
    guard fchmod(fd, 0o755) == 0 else { throw stubError(errno, url) }
    closed = true
    guard close(fd) == 0 else { throw stubError(errno, url) }
}

private func stubError(_ code: Int32, _ url: URL) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
}
