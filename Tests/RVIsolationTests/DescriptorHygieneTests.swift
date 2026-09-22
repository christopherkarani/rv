#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Stdio plus the admission pipes. Handshake fd 3 is closed before exec.
private let grantedPayloadDescriptors: [Int32] = [0, 1, 2, 4, 5]

/// Effect tests for contained descriptor inheritance. A path denial is not
/// enough: the child must see `EBADF` on a descriptor the parent still holds.
/// The payload keeps stdio and fds 4 and 5. Every other parent descriptor stays closed.
@Suite("DescriptorHygiene", .serialized)
struct DescriptorHygieneTests {
    @Test func ambientOutsideFileDescriptorIsNotWritable() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let outside = tree.siblingURL.appendingPathComponent("ambient-file")
        var held = try OwnedDescriptors.file(outside, bytes: Array("PARENT".utf8))
        defer { held.release() }
        guard try macOSContainedLaunch(tree) else { return }
        let report = try runProbe(
            tree,
            io: .discard,
            checks: held.checks(label: "file") + ["handshake:3"]
        )
        report.expectClosed("file")
        report.expectClosed("handshake", errno: EBADF)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "PARENT")
    }

    @Test func ambientSocketpairIsNotUsable() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        var held = try OwnedDescriptors.makeSocketPair()
        defer { held.release() }
        try held.proveParentCanTransfer("Z")
        guard try macOSContainedLaunch(tree) else { return }
        let report = try runProbe(tree, io: .discard, checks: held.checks(label: "socket"))
        report.expectClosed("socket")
        #expect(held.peerReceived("C") == false)
    }

    @Test func ambientPipeIsNotUsable() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        var held = try OwnedDescriptors.makePipe()
        defer { held.release() }
        try held.proveParentCanTransfer("Z")
        guard try macOSContainedLaunch(tree) else { return }
        let report = try runProbe(tree, io: .discard, checks: held.checks(label: "pipe"))
        report.expectClosed("pipe")
        #expect(held.peerReceived("C") == false)
    }

    @Test func containedProcessListsOnlyGrantedDescriptors() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let outside = tree.siblingURL.appendingPathComponent("listed-file")
        var file = try OwnedDescriptors.file(outside, bytes: Array("PARENT".utf8))
        var socket = try OwnedDescriptors.makeSocketPair()
        var pipe = try OwnedDescriptors.makePipe()
        defer {
            file.release()
            socket.release()
            pipe.release()
        }
        guard try macOSContainedLaunch(tree) else { return }
        let checks = file.checks(label: "file") + socket.checks(label: "socket")
            + pipe.checks(label: "pipe") + ["handshake:3"]
        let report = try runProbe(tree, io: .discard, checks: checks)
        report.expectClosed("file")
        report.expectClosed("socket")
        report.expectClosed("pipe")
        report.expectClosed("handshake", errno: EBADF)
        let forbidden = file.identities() + socket.identities() + pipe.identities()
        #expect(report.openFDs == grantedPayloadDescriptors)
        #expect(report.openIdentities().contains(where: { forbidden.contains($0) }) == false)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "PARENT")
    }

    @Test func inheritedStandardIOMatchesParent() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        guard try macOSContainedLaunch(tree) else { return }
        let parent = try stdioIdentities()
        let report = try runProbe(tree, io: .inherit, checks: ["handshake:3"])
        #expect(report.stdio[0] == parent[0])
        #expect(report.stdio[1] == parent[1])
        #expect(report.stdio[2] == parent[2])
        #expect(report.stdoutWrite == 1)
        #expect(report.stderrWrite == 1)
        report.expectClosed("handshake", errno: EBADF)
        #expect(report.openFDs == grantedPayloadDescriptors)
    }

    @Test func discardedStandardIOIsNullDevice() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        guard try macOSContainedLaunch(tree) else { return }
        let nullFD = open("/dev/null", O_RDWR | O_CLOEXEC)
        try #require(nullFD >= 0)
        defer { close(nullFD) }
        let nullIdentity = try #require(fileIdentity(nullFD))
        let parent = try stdioIdentities()
        let report = try runProbe(tree, io: .discard, checks: ["handshake:3"])
        #expect(report.stdio[0] == nullIdentity)
        #expect(report.stdio[1] == nullIdentity)
        #expect(report.stdio[2] == nullIdentity)
        #expect(report.stdinRead == 0)
        #expect(report.stdoutWrite == 1)
        #expect(report.stderrWrite == 1)
        if parent[1] != nullIdentity {
            #expect(report.stdio[1] != parent[1])
        }
        #expect(report.openFDs == grantedPayloadDescriptors)
    }

    @Test func innerExecutableDoesNotKeepHandshakeDescriptor() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        guard try macOSContainedLaunch(tree) else { return }
        let report = try runProbe(tree, io: .discard, checks: ["handshake:3"])
        report.expectClosed("handshake", errno: EBADF)
        #expect(report.openFDs.contains(3) == false)
        switch report.run.established {
        case .seatbelt(let session):
            #expect(report.run.session?.id == session.id)
        case .observed, .mediated:
            Issue.record("probe must establish seatbelt")
        }
    }

    @Test func failedLaunchesDoNotAccumulateDescriptors() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let sentinel = open(tree.workspaceURL.appendingPathComponent("sentinel").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(sentinel >= 0)
        defer { close(sentinel) }
        let before = openDescriptors()
        #if os(macOS)
        let workspace = try #require(posixRealpath(tree.workspaceURL.path))
        let command = try #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", "printf ran > must-not-run"]))
        let marker = tree.workspaceURL.appendingPathComponent("must-not-run")
        for _ in 0..<12 {
            let request = try #require(IsolatedLaunchRequest(
                plan: tree.contained,
                command: command,
                launch: .seatbelt(SeatbeltProfile(source: "(invalid-profile", workspacePath: workspace))
            ))
            let log = tree.rootURL.appendingPathComponent("sessions.jsonl")
            switch runSeatbeltLaunch(request, host: nil, sessionStore: .file(log)) {
            case .failure(.seatbeltNotEstablished):
                break
            case .failure(let error):
                Issue.record("invalid Seatbelt profile must be seatbeltNotEstablished, got \(error)")
            case .success:
                Issue.record("invalid Seatbelt profile must not establish isolation")
            }
            switch IsolationBackends.applyLaunch(
                tree.contained,
                command: command,
                io: .discard,
                host: nil,
                sessionStore: .failing(.sessionRecordFailed)
            ) {
            case .failure(.sessionRecordFailed):
                break
            case .failure(let error):
                Issue.record("failed session record must be sessionRecordFailed, got \(error)")
            case .success:
                Issue.record("failed session record must not launch")
            }
        }
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        #else
        let command = try #require(IsolatedCommand(executable: "/bin/true"))
        for _ in 0..<12 {
            switch IsolationBackends.apply(tree.contained, command: command) {
            case .failure(.containedGuaranteesUnsupported):
                break
            case .failure(let error):
                Issue.record("Linux contained launch must be refused, got \(error)")
            case .success(let run):
                Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
            }
        }
        #endif
        let after = openDescriptors()
        // Other suites share this process and can close their own descriptors
        // while this test refuses launch. A refused launch must not keep a
        // new descriptor, and this test's sentinel must stay open.
        #expect(after.subtracting(before).isEmpty)
        #expect(after.contains(sentinel))
    }

    @Test func cancellationClosesLaunchDescriptors() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let sentinel = open(tree.workspaceURL.appendingPathComponent("sentinel").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(sentinel >= 0)
        defer { close(sentinel) }
        #if os(macOS)
        let started = tree.workspaceURL.appendingPathComponent("started")
        let command = try #require(IsolatedCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf started > started; /bin/sleep 30"]
        ))
        let before = openDescriptors()
        let task = Task {
            IsolationBackends.apply(tree.contained, command: command)
        }
        // The private volume is mounted before the shell writes `started`.
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, FileManager.default.fileExists(atPath: started.path) == false {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard FileManager.default.fileExists(atPath: started.path) else {
            task.cancel()
            _ = await task.value
            Issue.record("contained command did not start before cancellation")
            return
        }
        task.cancel()
        let result = await task.value
        switch result {
        case .failure(.cancelled):
            break
        case .failure(let error):
            Issue.record("cancelled contained run must be cancelled, got \(error)")
        case .success(let run):
            Issue.record("cancelled contained run must not succeed, got exit \(run.exitStatus)")
        }
        let after = openDescriptors()
        // Other suites share this process and open descriptors while this
        // launch is mounted. Only paths this launch creates are attributable.
        let leaked = after.subtracting(before).filter { fd in
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return false }
            let count = buffer.firstIndex(of: 0) ?? buffer.count
            let path = String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return path.hasPrefix(tree.rootURL.path)
                || path.hasPrefix("/dev/disk")
                || path.contains("rv-inode-")
                || path.contains(".rv-saved-")
        }
        #expect(leaked.isEmpty)
        #expect(after.contains(sentinel))
        #else
        let command = try #require(IsolatedCommand(executable: "/bin/sleep", arguments: ["30"]))
        switch IsolationBackends.apply(tree.contained, command: command) {
        case .failure(.containedGuaranteesUnsupported):
            break
        case .failure(let error):
            Issue.record("Linux contained launch must be refused, got \(error)")
        case .success(let run):
            Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
        }
        #endif
    }
}

private enum DescriptorFixtureError: Error {
    case socketpair
    case pipe
    case stdio
}

private struct ProbeReport {
    var run: IsolatedRunResult
    var text: String
    var checks: [(label: String, fd: Int32, closed: Bool, errno: Int32)] = []
    var stdio: [Int32: FileIdentity] = [:]
    var stdinRead: Int?
    var stdoutWrite: Int?
    var stderrWrite: Int?
    var openFDs: [Int32] = []
    var openByFD: [Int32: FileIdentity] = [:]

    func expectClosed(_ label: String, errno expected: Int32? = nil) {
        let matches = checks.filter { $0.label == label }
        #expect(matches.isEmpty == false, "probe report has no \(label) check\n\(text)")
        for check in matches {
            // Fds 4 and 5 are the admission pipes. A parent descriptor that
            // happened to use one of those numbers is a different object.
            if check.fd == RuntimeAdmissionDescriptors.request
                || check.fd == RuntimeAdmissionDescriptors.response
            {
                continue
            }
            #expect(check.closed, "\(label) fd \(check.fd) stayed open\n\(text)")
            if let expected {
                #expect(check.errno == expected, "\(label) errno \(check.errno), want \(expected)\n\(text)")
            }
        }
    }

    func openIdentities() -> [FileIdentity] {
        Array(openByFD.values)
    }
}

private struct FileIdentity: Equatable, Hashable {
    var device: UInt64
    var inode: UInt64
}

/// Descriptors the parent keeps open across the launch. The parked number is
/// at least 100 and is not close-on-exec, so an ordinary spawn would inherit it.
private struct OwnedDescriptors {
    var ends: [Int32]
    var parked: [Int32]
    var readEnd: Int32?

    static func file(_ url: URL, bytes: [UInt8]) throws -> OwnedDescriptors {
        let fd = open(url.path, O_CREAT | O_RDWR | O_TRUNC, 0o600)
        try #require(fd >= 0)
        let wrote = bytes.withUnsafeBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return write(fd, base, buffer.count)
        }
        try #require(wrote == bytes.count)
        let parked = try park(fd)
        return OwnedDescriptors(ends: [fd], parked: [parked], readEnd: nil)
    }

    static func makeSocketPair() throws -> OwnedDescriptors {
        var fds: [Int32] = [-1, -1]
        let result = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            #if os(Linux)
            let kind = Int32(SOCK_STREAM.rawValue)
            return Glibc.socketpair(AF_UNIX, kind, 0, base)
            #else
            return Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, base)
            #endif
        }
        if result != 0 { throw DescriptorFixtureError.socketpair }
        let parked = try park(fds[0])
        return OwnedDescriptors(ends: fds, parked: [parked], readEnd: fds[1])
    }

    static func makePipe() throws -> OwnedDescriptors {
        var fds: [Int32] = [-1, -1]
        let result = fds.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            #if os(Linux)
            return Glibc.pipe(base)
            #else
            return Darwin.pipe(base)
            #endif
        }
        if result != 0 { throw DescriptorFixtureError.pipe }
        let parked = try park(fds[1])
        return OwnedDescriptors(ends: fds, parked: [parked], readEnd: fds[0])
    }

    func checks(label: String) -> [String] {
        var values = parked.map { "\(label):\($0)" }
        for fd in ends where fd >= 3 && parked.contains(fd) == false {
            values.append("\(label):\(fd)")
        }
        return values
    }

    func identities() -> [FileIdentity] {
        (ends + parked).compactMap(fileIdentity)
    }

    func proveParentCanTransfer(_ byte: String) throws {
        var payload = Array(byte.utf8)
        let writeEnd = ends.count == 2 && readEnd == ends[0] ? ends[1] : ends[0]
        let wrote = payload.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return write(writeEnd, base, buffer.count)
        }
        try #require(wrote == payload.count)
        #expect(peerReceived(byte))
    }

    func peerReceived(_ byte: String) -> Bool {
        guard let readEnd else { return false }
        let flags = fcntl(readEnd, F_GETFL)
        guard flags >= 0 else { return false }
        _ = fcntl(readEnd, F_SETFL, flags | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 8)
        let count = buffer.withUnsafeMutableBufferPointer { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return read(readEnd, base, raw.count)
        }
        guard count > 0 else { return false }
        return String(bytes: buffer.prefix(count), encoding: .utf8)?.contains(byte) == true
    }

    mutating func release() {
        for fd in Set(ends + parked) where fd >= 0 {
            _ = close(fd)
        }
        ends = []
        parked = []
        readEnd = nil
    }

    private static func park(_ fd: Int32) throws -> Int32 {
        let parked = fcntl(fd, F_DUPFD, 100)
        try #require(parked >= 100)
        let flags = fcntl(parked, F_GETFD)
        try #require(flags >= 0)
        _ = fcntl(parked, F_SETFD, flags & ~FD_CLOEXEC)
        return parked
    }
}

private func macOSContainedLaunch(_ tree: ContainmentTree) throws -> Bool {
    #if os(macOS)
    _ = tree
    return true
    #else
    let command = try #require(IsolatedCommand(executable: "/bin/true"))
    switch IsolationBackends.apply(tree.contained, command: command) {
    case .failure(.containedGuaranteesUnsupported):
        return false
    case .failure(let error):
        Issue.record("Linux contained launch must be refused, got \(error)")
        return false
    case .success(let run):
        Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
        return false
    }
    #endif
}

private func runProbe(
    _ tree: ContainmentTree,
    io: IsolatedIO,
    checks: [String]
) throws -> ProbeReport {
    let binary = try compileDescriptorProbe(in: tree.workspaceURL)
    let reportURL = tree.workspaceURL.appendingPathComponent("descriptor-report-\(UUID().uuidString)")
    let command = try #require(IsolatedCommand(
        executable: binary.path,
        arguments: [reportURL.path, io == .inherit ? "inherit" : "discard"] + checks
    ))
    let log = tree.rootURL.appendingPathComponent("sessions.jsonl")
    let result = IsolationBackends.applyLaunch(
        tree.contained,
        command: command,
        io: io,
        host: nil,
        sessionStore: .file(log)
    )
    let run = try result.get()
    #expect(run.exitStatus == 0)
    switch run.established {
    case .seatbelt:
        break
    case .observed, .mediated:
        Issue.record("probe must establish seatbelt")
    }
    let text = try String(contentsOf: reportURL, encoding: .utf8)
    return try parseProbeReport(text, run: run)
}

private func parseProbeReport(_ text: String, run: IsolatedRunResult) throws -> ProbeReport {
    var report = ProbeReport(run: run, text: text)
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ").map(String.init)
        switch parts.first {
        case "check":
            guard parts.count >= 5, let fd = Int32(parts[2]) else {
                Issue.record("bad check line \(line)")
                continue
            }
            if parts[3] == "closed" {
                report.checks.append((parts[1], fd, true, Int32(parts[4]) ?? -1))
            } else if parts.count >= 7, parts[3] == "open" {
                report.checks.append((parts[1], fd, false, Int32(parts[6]) ?? -1))
            }
        case "stdio":
            guard parts.count >= 4, let fd = Int32(parts[1]),
                let device = UInt64(parts[2]), let inode = UInt64(parts[3])
            else { continue }
            report.stdio[fd] = FileIdentity(device: device, inode: inode)
        case "stdin-read":
            report.stdinRead = Int(parts.count > 1 ? parts[1] : "")
        case "stdio-write":
            report.stdoutWrite = Int(parts.count > 1 ? parts[1] : "")
            report.stderrWrite = Int(parts.count > 2 ? parts[2] : "")
        case "open":
            guard parts.count >= 4, let fd = Int32(parts[1]),
                let device = UInt64(parts[2]), let inode = UInt64(parts[3])
            else { continue }
            report.openFDs.append(fd)
            report.openByFD[fd] = FileIdentity(device: device, inode: inode)
        default:
            break
        }
    }
    try #require(report.stdio.count == 3, "probe report missing stdio\n\(text)")
    return report
}

private func compileDescriptorProbe(in workspace: URL) throws -> URL {
    let file = workspace.appendingPathComponent("descriptor-probe.c")
    let binary = workspace.appendingPathComponent("descriptor-probe")
    try Data(descriptorProbeSource.utf8).write(to: file)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compile.arguments = ["-O2", "-o", binary.path, file.path]
    compile.standardOutput = FileHandle.nullDevice
    compile.standardError = FileHandle.nullDevice
    try compile.run()
    compile.waitUntilExit()
    try #require(compile.terminationStatus == 0)
    return binary
}

private func stdioIdentities() throws -> [Int32: FileIdentity] {
    var identities: [Int32: FileIdentity] = [:]
    for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
        guard let identity = fileIdentity(fd) else {
            throw DescriptorFixtureError.stdio
        }
        identities[fd] = identity
    }
    return identities
}

private func fileIdentity(_ fd: Int32) -> FileIdentity? {
    var info = stat()
    guard fstat(fd, &info) == 0 else { return nil }
    // `dev_t` is signed. A socket can report -1, and `UInt64.init` traps on that.
    let device = UInt64(bitPattern: Int64(info.st_dev))
    return FileIdentity(device: device, inode: UInt64(info.st_ino))
}

private func openDescriptors() -> Set<Int32> {
    var limit = rlimit()
    let cap: Int32
    // Linux Swift imports `RLIMIT_NOFILE` as `__rlimit_resource`. `getrlimit`
    // takes `__rlimit_resource_t` (`Int32`). glibc's value is 7. Darwin's
    // macro is already that integer.
    #if os(Linux)
    let nofileLimit: Int32 = 7
    #else
    let nofileLimit = RLIMIT_NOFILE
    #endif
    if getrlimit(nofileLimit, &limit) == 0, limit.rlim_cur < 4096 {
        cap = Int32(limit.rlim_cur)
    } else {
        cap = 4096
    }
    var open = Set<Int32>()
    var fd: Int32 = 0
    while fd < cap {
        if fcntl(fd, F_GETFD) >= 0 {
            open.insert(fd)
        }
        fd += 1
    }
    return open
}

private let descriptorProbeSource = #"""
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char report_bytes[32768];
static size_t report_used;

static void add(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    int wrote = vsnprintf(
        report_bytes + report_used,
        sizeof report_bytes - report_used,
        fmt,
        args
    );
    va_end(args);
    if (wrote > 0 && (size_t)wrote < sizeof report_bytes - report_used) {
        report_used += (size_t)wrote;
    }
}

int main(int argc, char **argv) {
    if (argc < 3) return 2;
    for (int i = 3; i < argc; i++) {
        char *colon = strchr(argv[i], ':');
        if (colon == NULL) return 2;
        *colon = 0;
        int fd = atoi(colon + 1);
        errno = 0;
        int flags = fcntl(fd, F_GETFD);
        int error = errno;
        if (flags == -1) {
            add("check %s %d closed %d\n", argv[i], fd, error);
            continue;
        }
        char byte = 'C';
        errno = 0;
        ssize_t count = write(fd, &byte, 1);
        add("check %s %d open write %zd %d\n", argv[i], fd, count, count < 0 ? errno : 0);
    }
    for (int fd = 0; fd <= 2; fd++) {
        struct stat info;
        if (fstat(fd, &info) != 0) {
            add("stdio %d missing %d\n", fd, errno);
            continue;
        }
        add("stdio %d %llu %llu\n", fd,
            (unsigned long long)info.st_dev,
            (unsigned long long)info.st_ino);
    }
    if (strcmp(argv[2], "discard") == 0) {
        char byte = 0;
        errno = 0;
        ssize_t count = read(0, &byte, 1);
        add("stdin-read %zd %d\n", count, count < 0 ? errno : 0);
    }
    ssize_t stdoutCount = write(1, "S", 1);
    ssize_t stderrCount = write(2, "E", 1);
    add("stdio-write %zd %zd\n", stdoutCount, stderrCount);
    for (int fd = 0; fd < 256; fd++) {
        struct stat info;
        if (fstat(fd, &info) != 0) continue;
        add("open %d %llu %llu\n", fd,
            (unsigned long long)info.st_dev,
            (unsigned long long)info.st_ino);
    }
    int out = open(argv[1], O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (out < 0) return 3;
    if (write(out, report_bytes, report_used) < 0) return 4;
    close(out);
    return 0;
}
"""#
