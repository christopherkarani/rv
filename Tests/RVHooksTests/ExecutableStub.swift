import Foundation

/// Writes a stub rv that an adapter then runs, mode 0755 unless `mode` says
/// otherwise. `path` must not exist.
///
/// Exec fails with ETXTBSY while any process holds the file open for
/// writing. `String.write(toFile:atomically:)` opens without O_CLOEXEC, so a
/// child that another suite's thread spawns during the write inherits the
/// descriptor and keeps it as long as it runs (several suites `posix_spawn`
/// with no file actions). With O_CLOEXEC a spawned child drops the
/// descriptor at its own exec.
func writeExecutableStub(_ source: String, toFile path: String, mode: mode_t = 0o755) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw stubError(errno, path) }
    var closed = false
    defer { if !closed { close(fd) } }
    let bytes = Array(source.utf8)
    var offset = 0
    while offset < bytes.count {
        let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
        if count < 0 {
            if errno == EINTR { continue }
            throw stubError(errno, path)
        }
        offset += count
    }
    guard fchmod(fd, mode) == 0, fsync(fd) == 0 else { throw stubError(errno, path) }
    closed = true
    guard close(fd) == 0 else { throw stubError(errno, path) }
}

private func stubError(_ code: Int32, _ path: String) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
}
