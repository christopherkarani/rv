#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVIsolation

/// Unit tests for the fused spawn primitives: fd relocation, C-string
/// vectors, the handshake script, and the handshake-prefix matcher.
/// Real fds only, created and closed in-test. Serialized: relocate tests
/// depend on low-numbered fd allocation.
@Suite("SpawnPrimitives", .serialized)
struct SpawnPrimitivesTests {
    // MARK: - relocate

    private func openPipe() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        let opened = pair.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return pipe(base)
        }
        try #require(opened == 0)
        return (pair[0], pair[1])
    }

    @Test func relocateMovesBelowFloorUp() throws {
        let (readEnd, writeEnd) = try openPipe()
        var fd = readEnd
        defer {
            if fd >= 0 { close(fd) }
            close(writeEnd)
        }
        // Deterministic under parallel suites: the floor sits above
        // whatever number lowest-free allocation handed us.
        let floor = fd + 8
        let original = fd
        #expect(relocateDescriptor(&fd, above: floor) == true)
        #expect(fd >= floor)
        #expect(fd != original)
        // Moved end carries CLOEXEC (pipe() does not set it).
        let movedFlags = fcntl(fd, F_GETFD)
        #expect(movedFlags >= 0)
        #expect(movedFlags & FD_CLOEXEC != 0)
        // Original is closed; capture errno before the framework runs.
        let probe = fcntl(original, F_GETFD)
        let probeErrno = errno
        #expect(probe == -1)
        #expect(probeErrno == EBADF)
        // Moved end is the same pipe: a byte round-trips.
        let written: [UInt8] = [0x7A]
        #expect(written.withUnsafeBytes { write(writeEnd, $0.baseAddress, $0.count) } == 1)
        var byte: UInt8 = 0
        #expect(withUnsafeMutableBytes(of: &byte) { read(fd, $0.baseAddress, $0.count) } == 1)
        #expect(byte == 0x7A)
    }

    /// Both production floors (admission 8, seatbelt/terminal/boundary
    /// 16). Deterministic: F_DUPFD always hands back an fd at/above floor.
    @Test(arguments: [Int32(8), Int32(16)])
    func relocateLeavesAboveFloorUntouched(floor: Int32) throws {
        let (readEnd, writeEnd) = try openPipe()
        defer { close(writeEnd) }
        var high = fcntl(readEnd, F_DUPFD, floor)
        close(readEnd)
        defer {
            if high >= 0 { close(high) }
        }
        try #require(high >= floor)
        // F_DUPFD clears CLOEXEC; relocate must not add it back.
        try #require(fcntl(high, F_GETFD) & FD_CLOEXEC == 0)
        let before = high
        #expect(relocateDescriptor(&high, above: floor) == true)
        #expect(high == before)
        #expect(fcntl(high, F_GETFL) >= 0)
        #expect(fcntl(high, F_GETFD) & FD_CLOEXEC == 0)
    }

    @Test func relocateRejectsInvalidDescriptor() {
        var bad: Int32 = -1
        #expect(relocateDescriptor(&bad, above: 16) == false)
        #expect(bad == -1)
    }

    /// fcntl failure returns false and leaves the original fd open and
    /// unmodified. The floor sits above OPEN_MAX so no fd can satisfy it;
    /// the fd stays open throughout, so a parallel suite cannot reuse its
    /// number between a close and the probe.
    @Test func relocateFailureLeavesOriginalOpen() throws {
        let (readEnd, writeEnd) = try openPipe()
        var fd = readEnd
        defer {
            if fd >= 0 { close(fd) }
            close(writeEnd)
        }
        #expect(relocateDescriptor(&fd, above: Int32.max) == false)
        #expect(fd == readEnd)
        #expect(fcntl(fd, F_GETFD) >= 0)
    }

    /// `a35644a2` leaves a Darwin socket that landed on 0, 1, or 2 open
    /// after `F_DUPFD_CLOEXEC`. The published fd is close-on-exec; the
    /// original is closed once. Stdout is not closed.
    @Test func stdioSlotSocketIsClosedOnceAfterCloexecDup() throws {
        let stdoutBefore = fcntl(1, F_GETFD)
        let slot = try occupyStdioSlotWithSocket()
        defer { slot.restore() }
        let published = publishCloexecSocket(raw: slot.fd, above: 64)
        defer { if published >= 0 { close(published) } }
        #expect(published >= 64)
        let flags = fcntl(published, F_GETFD)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC != 0)
        let probe = fcntl(slot.fd, F_GETFD)
        let probeErrno = errno
        #expect(probe == -1)
        #expect(probeErrno == EBADF)
        if stdoutBefore >= 0 {
            #expect(fcntl(1, F_GETFD) >= 0)
        }
    }

    /// A failed cloexec dup still closes the original once, including a
    /// socket on 0, 1, or 2. `a35644a2` returns `-1` and leaks that fd.
    @Test func stdioSlotSocketIsClosedOnceWhenCloexecDupFails() throws {
        let slot = try occupyStdioSlotWithSocket()
        defer { slot.restore() }
        let published = publishCloexecSocket(raw: slot.fd, above: Int32.max)
        #expect(published == -1)
        let probe = fcntl(slot.fd, F_GETFD)
        let probeErrno = errno
        #expect(probe == -1)
        #expect(probeErrno == EBADF)
    }

    /// `accept` on 0, 1, or 2 is dup'd close-on-exec, and
    /// `closeRelocatedOriginal` does not close that original.
    /// `a35644a2` leaves the client connection inheritable.
    @Test func acceptedSocketOnStdioIsClosedOnce() throws {
        let slot = try occupyStdioSlotWithSocket()
        defer { slot.restore() }
        var held = slot.fd
        #expect(relocateOwnedSocket(&held, above: 64))
        defer { if held >= 3 { close(held) } }
        #expect(held >= 64)
        #expect(held != slot.fd)
        let flags = fcntl(held, F_GETFD)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC != 0)
        let probe = fcntl(slot.fd, F_GETFD)
        let probeErrno = errno
        #expect(probe == -1)
        #expect(probeErrno == EBADF)
    }

    // MARK: - vectors

    @Test func vectorYieldsContentPlusTerminator() {
        let vector = SpawnPointers(["alpha", "beta"])
        defer { vector.release() }
        var seen: [String] = []
        let terminated = vector.withPointers { base -> Bool in
            var index = 0
            // Bound the walk: content slots plus the terminator.
            while index < 3, let slot = base[index] {
                seen.append(String(cString: slot))
                index += 1
            }
            return index < 3 && base[index] == nil
        }
        #expect(terminated == true)
        #expect(seen == ["alpha", "beta"])
    }

    @Test func vectorWithEmptyInputYieldsOnlyTerminator() {
        let vector = SpawnPointers([])
        defer { vector.release() }
        let terminated = vector.withPointers { $0[0] == nil }
        #expect(terminated == true)
    }

    // MARK: - handshake script

    @Test func handshakeScriptIsPinned() {
        #expect(
            spawnHandshakeScript
                == "printf %s \"$1\" >&3 || exit 127; exec 3>&- || exit 127; shift; exec \"$@\""
        )
    }

    // MARK: - matcher

    @Test func matcherEstablishesOnSplitPackets() {
        var matcher = HandshakePrefixMatcher(expected: Data("nonce123".utf8))
        #expect(matcher.append(Data("non".utf8)) == false)
        #expect(matcher.append(Data("ce123".utf8)) == true)
    }

    @Test func matcherEstablishesAtExactBoundary() {
        var matcher = HandshakePrefixMatcher(expected: Data("ab".utf8))
        #expect(matcher.append(Data("a".utf8)) == false)
        #expect(matcher.append(Data("b".utf8)) == true)
    }

    @Test func matcherEstablishesWithTrailingBytes() {
        var matcher = HandshakePrefixMatcher(expected: Data("ab".utf8))
        #expect(matcher.append(Data("abEXTRA".utf8)) == true)
    }

    @Test func matcherRejectsWrongPrefixForever() {
        var matcher = HandshakePrefixMatcher(expected: Data("nonce".utf8))
        #expect(matcher.append(Data("nope!".utf8)) == false)
        #expect(matcher.append(Data("more-bytes-past-expected".utf8)) == false)
    }

    @Test func matcherNeverRecoversAfterWrongByte() {
        var matcher = HandshakePrefixMatcher(expected: Data("ab".utf8))
        #expect(matcher.append(Data("x".utf8)) == false)
        // Accumulated "xab": the prefix gate stays shut, matching the loops.
        #expect(matcher.append(Data("ab".utf8)) == false)
    }

    @Test func matcherEmptyAppendsAreHarmless() {
        var matcher = HandshakePrefixMatcher(expected: Data("ab".utf8))
        #expect(matcher.append(Data()) == false)
        #expect(matcher.append(Data("ab".utf8)) == true)
    }

    @Test func matcherHonorsPreface() {
        var matcher = HandshakePrefixMatcher(
            expected: Data("ab".utf8),
            preface: Data("a".utf8)
        )
        #expect(matcher.append(Data()) == false)
        #expect(matcher.append(Data("b".utf8)) == true)
    }
}

/// A socket sitting on 0, 1, or 2. A slot that was already free is used as-is.
/// When every stdio slot is live, fd 0 is replaced and `restore` puts the
/// saved copy back. The test does not close a live descriptor it does not own.
private struct StdioSlotSocket {
    var fd: Int32
    var saved: Int32

    func restore() {
        if saved >= 0 {
            _ = dup2(saved, fd)
            _ = close(saved)
        }
    }
}

private func occupyStdioSlotWithSocket() throws -> StdioSlotSocket {
    #if canImport(Darwin)
    let raw = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let raw = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    try #require(raw >= 0)
    if raw < 3 {
        return StdioSlotSocket(fd: raw, saved: -1)
    }
    for candidate: Int32 in 0..<3 {
        if fcntl(candidate, F_GETFD) < 0, errno == EBADF {
            let placed = dup2(raw, candidate)
            if placed != candidate {
                close(raw)
                try #require(placed == candidate)
            }
            close(raw)
            return StdioSlotSocket(fd: candidate, saved: -1)
        }
    }
    let saved = fcntl(0, F_DUPFD_CLOEXEC, 64)
    try #require(saved >= 64)
    let placed = dup2(raw, 0)
    if placed != 0 {
        close(saved)
        close(raw)
        try #require(placed == 0)
    }
    if raw != 0 { close(raw) }
    return StdioSlotSocket(fd: 0, saved: saved)
}
