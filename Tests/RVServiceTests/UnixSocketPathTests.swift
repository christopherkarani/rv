#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVService

@Suite(.serialized)
struct UnixSocketPathTests {
    @Test func injectedXDGResolvesUnderRuntimeDir() throws {
        let xdg = "/run/user/1000"
        let socket = try UnixSocketPath.resolve(xdgRuntimeDir: xdg)
        #expect(socket.path == "/run/user/1000/rv/evaluate.sock")
    }

    @Test func unsetAndEmptyXDGFailClosed() {
        #expect(throws: UnixSocketPathError.runtimeDirectoryMissing) {
            try UnixSocketPath.resolve(xdgRuntimeDir: nil)
        }
        #expect(throws: UnixSocketPathError.runtimeDirectoryMissing) {
            try UnixSocketPath.resolve(xdgRuntimeDir: "")
        }
        #expect(throws: UnixSocketPathError.runtimeDirectoryMissing) {
            try UnixSocketPath.resolve(xdgRuntimeDir: "   ")
        }
    }

    /// Mirrors `unix_socket_path` in Sources/rv-c/rv.c: only the uid-derived
    /// runtime dir is the owner's, because an agent can set XDG_RUNTIME_DIR
    /// through project-scoped host config.
    @Test func clientSocketFallsBackToTheUidRuntimeDirAndMarksOnlyItAsTheOwners() throws {
        let unset = try #require(UnixSocketPath.clientSocket(xdgRuntimeDir: nil, uid: 1000))
        #expect(unset.url.path == "/run/user/1000/rv/evaluate.sock")
        #expect(unset.isOwnerRuntime)

        let same = try #require(UnixSocketPath.clientSocket(xdgRuntimeDir: "/run/user/1000", uid: 1000))
        #expect(same == unset)

        let foreign = try #require(UnixSocketPath.clientSocket(xdgRuntimeDir: "/tmp/agent-dir", uid: 1000))
        #expect(foreign.url.path == "/tmp/agent-dir/rv/evaluate.sock")
        #expect(foreign.isOwnerRuntime == false)
        // Same socket file, but not the exact uid-derived string: fail closed like C.
        let slash = try #require(UnixSocketPath.clientSocket(xdgRuntimeDir: "/run/user/1000/", uid: 1000))
        #expect(slash.isOwnerRuntime == false)
        let otherUser = try #require(UnixSocketPath.clientSocket(xdgRuntimeDir: "/run/user/1001", uid: 1000))
        #expect(otherUser.isOwnerRuntime == false)

        #expect(UnixSocketPath.clientSocket(xdgRuntimeDir: "", uid: 1000) == nil)
        #expect(UnixSocketPath.clientSocket(xdgRuntimeDir: "/tmp/" + String(repeating: "x", count: 120), uid: 1000) == nil)
    }

    #if os(Linux)
    @Test func productionReadsInjectedXDGNotTmpFallback() throws {
        let previous = liveXDG()
        let injected = shortRuntimeDir("i")
        setenv("XDG_RUNTIME_DIR", injected.path, 1)
        defer { restoreXDG(previous) }

        let socket = try UnixSocketPath.production()
        #expect(socket.path.hasPrefix(injected.path))
        #expect(socket.path.contains("/tmp/rv.sock") == false)
        #expect(socket.lastPathComponent == UnixSocketPath.socketFileName)
    }

    /// rvd binds where every client dials: unset XDG_RUNTIME_DIR is the
    /// uid-derived runtime directory, never a /tmp fallback.
    @Test func productionUnsetXDGUsesTheUidRuntimeDirLikeClients() throws {
        let previous = liveXDG()
        unsetenv("XDG_RUNTIME_DIR")
        defer { restoreXDG(previous) }

        let socket = try UnixSocketPath.production()
        #expect(socket.path == "/run/user/\(getuid())/rv/evaluate.sock")
        #expect(socket == UnixSocketPath.clientSocket(xdgRuntimeDir: nil, uid: getuid())?.url)
        #expect(FileManager.default.fileExists(atPath: "/tmp/rv.sock") == false)
        #expect(FileManager.default.fileExists(atPath: "/tmp/evaluate.sock") == false)
    }

    @Test func serverSocketMatchesClientSocketForEveryXDGShape() throws {
        for xdg in [nil, "/run/user/1000", "/tmp/agent-dir"] as [String?] {
            let server = try UnixSocketPath.serverSocket(xdgRuntimeDir: xdg, uid: 1000)
            #expect(server == UnixSocketPath.clientSocket(xdgRuntimeDir: xdg, uid: 1000)?.url)
        }
        #expect(throws: UnixSocketPathError.runtimeDirectoryMissing) {
            try UnixSocketPath.serverSocket(xdgRuntimeDir: "", uid: 1000)
        }
        let fixture = try UnixSocketPath.serverSocket(xdgRuntimeDir: nil, uid: 7, userRuntimeRoot: "/x/user")
        #expect(fixture.path == "/x/user/7/rv/evaluate.sock")
    }

    /// No logind: rvd makes `<root>/<uid>` itself (one level, 0700) when
    /// the root exists, and refuses one that is not owner-only.
    @Test func prepareRuntimeCreatesTheUidRuntimeDirOnlyUnderAnExistingRoot() throws {
        let root = shortRuntimeDir("u")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = getuid()
        let socket = try UnixSocketPath.serverSocket(xdgRuntimeDir: nil, uid: uid, userRuntimeRoot: root.path)
        try UnixSocketPath.prepareRuntime(for: socket, userRuntimeRoot: root.path, uid: uid)
        let owner = root.appendingPathComponent("\(uid)")
        #expect(try UnixSocketPath.posixMode(of: owner) & 0o777 == 0o700)
        #expect(try UnixSocketPath.posixMode(of: socket.deletingLastPathComponent()) & 0o777 == 0o700)

        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: owner.path)
        #expect(throws: UnixSocketPathError.userRuntimeDirectoryUnavailable(owner.path)) {
            try UnixSocketPath.prepareRuntime(for: socket, userRuntimeRoot: root.path, uid: uid)
        }
        #expect(try UnixSocketPath.posixMode(of: owner) & 0o777 == 0o777)
    }

    @Test func prepareRuntimeRefusesAUidRuntimeDirThatIsASymlink() throws {
        let root = shortRuntimeDir("s")
        let target = shortRuntimeDir("t")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        let uid = getuid()
        let owner = root.appendingPathComponent("\(uid)")
        try FileManager.default.createSymbolicLink(at: owner, withDestinationURL: target)
        let socket = try UnixSocketPath.serverSocket(xdgRuntimeDir: nil, uid: uid, userRuntimeRoot: root.path)
        #expect(throws: UnixSocketPathError.userRuntimeDirectoryUnavailable(owner.path)) {
            try UnixSocketPath.prepareRuntime(for: socket, userRuntimeRoot: root.path, uid: uid)
        }
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("rv").path) == false)
    }

    @Test func prepareRuntimeNeverCreatesAMissingRootForANonRootUid() throws {
        let root = shortRuntimeDir("m")
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = try UnixSocketPath.serverSocket(xdgRuntimeDir: nil, uid: 4242, userRuntimeRoot: root.path)
        #expect(throws: UnixSocketPathError.userRuntimeDirectoryUnavailable(root.path + "/4242")) {
            try UnixSocketPath.prepareRuntime(for: socket, userRuntimeRoot: root.path, uid: 4242)
        }
        #expect(FileManager.default.fileExists(atPath: root.path) == false)
    }

    /// rvd's refusal names the actual problem, and a fix that works for it
    /// (`mkdir -p` would leave an existing directory's owner and mode alone).
    @Test func userRuntimeDirectoryProblemNamesWhatIsWrongAndAFixForIt() throws {
        let root = shortRuntimeDir("p")
        defer { try? FileManager.default.removeItem(at: root) }
        let me = getuid()
        let owner = root.appendingPathComponent("\(me)").path
        let make = "as root, install -d -m 0700 -o \(me) \(owner)"

        let noRoot = UnixSocketPath.userRuntimeDirectoryProblem(owner, userRuntimeRoot: root.path, uid: me)
        #expect(noRoot.reason.hasPrefix("\(root.path) does not exist (no login manager made it"))
        // The root directory with its mode spelled out: root's umask could
        // otherwise leave it 0700, which no other account can search.
        #expect(noRoot.fix == "as root, install -d -m 0755 \(root.path) && install -d -m 0700 -o \(me) \(owner)")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(UnixSocketPath.userRuntimeDirectoryProblem(owner, userRuntimeRoot: root.path, uid: me)
            == .init(reason: "\(owner) does not exist and this account cannot create it in \(root.path)", fix: make))

        try FileManager.default.createDirectory(atPath: owner, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: owner)
        #expect(UnixSocketPath.userRuntimeDirectoryProblem(owner, userRuntimeRoot: root.path, uid: me)
            == .init(reason: "\(owner) has mode 0770, which group or others can write", fix: make))

        let other: UInt32 = me == 4242 ? 4243 : 4242
        let foreign = UnixSocketPath.userRuntimeDirectoryProblem(owner, userRuntimeRoot: root.path, uid: other)
        #expect(foreign.reason == "\(owner) belongs to uid \(me), not to this account (uid \(other))")
        #expect(foreign.fix == "as root, remove \(owner), then install -d -m 0700 -o \(other) \(owner)")

        try FileManager.default.removeItem(atPath: owner)
        try FileManager.default.createSymbolicLink(atPath: owner, withDestinationPath: "/")
        #expect(UnixSocketPath.userRuntimeDirectoryProblem(owner, userRuntimeRoot: root.path, uid: me)
            == .init(reason: "\(owner) is a symbolic link", fix: "as root, remove \(owner), then install -d -m 0700 -o \(me) \(owner)"))
    }

    /// A runtime directory rvd cannot reach because a directory above it is
    /// not searchable is not "missing": making it would change nothing.
    @Test func userRuntimeDirectoryProblemNamesAnUnsearchableParent() {
        let owner = "/run/user/4242"
        let problem = UnixSocketPath.unexaminableUserRuntimeDirectoryProblem(
            owner, userRuntimeRoot: "/run/user", uid: 4242, error: EACCES)
        #expect(problem.reason.hasSuffix("is not searchable by this account (uid 4242), so rvd cannot reach \(owner)"))
        #expect(problem.reason.contains("does not exist") == false)
        #expect(problem.fix.hasPrefix("as root, chmod go+x /"))
        #expect(problem.fix.hasSuffix(", then, if \(owner) does not exist, install -d -m 0700 -o 4242 \(owner)"))

        let other = UnixSocketPath.unexaminableUserRuntimeDirectoryProblem(
            owner, userRuntimeRoot: "/run/user", uid: 4242, error: ELOOP)
        #expect(other.reason.hasPrefix("\(owner) cannot be examined ("))
    }

    /// The same through the file system, where the kernel says EACCES: only
    /// an account without CAP_DAC_READ_SEARCH can see it, so not as root.
    @Test(.enabled(if: getuid() != 0, "root can search any directory"))
    func userRuntimeDirectoryProblemFindsTheUnsearchableDirectory() throws {
        let root = shortRuntimeDir("q")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let me = getuid()
        let owner = root.appendingPathComponent("\(me)").path
        try FileManager.default.createDirectory(atPath: owner, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.path)
        let problem = UnixSocketPath.userRuntimeDirectoryProblem(owner, userRuntimeRoot: root.path, uid: me)
        #expect(problem == .init(
            reason: "\(root.path) is not searchable by this account (uid \(me)), so rvd cannot reach \(owner)",
            fix: "as root, chmod go+x \(root.path), then, if \(owner) does not exist, install -d -m 0700 -o \(me) \(owner)"))
    }

    /// Setup's up-front check names only a start `prepareRuntime` cannot
    /// make work: XDG unset, not root, nothing at `<root>/<uid>`, and a root
    /// this process cannot write.
    @Test func uncreatableUserRuntimeDirectoryNamesOnlyAStartThatCannotWork() throws {
        let missing = shortRuntimeDir("n")
        #expect(UnixSocketPath.uncreatableUserRuntimeDirectory(
            xdgRuntimeDir: nil, uid: 4242, userRuntimeRoot: missing.path) == missing.path + "/4242")
        #expect(UnixSocketPath.uncreatableUserRuntimeDirectory(
            xdgRuntimeDir: "/somewhere", uid: 4242, userRuntimeRoot: missing.path) == nil)
        #expect(UnixSocketPath.uncreatableUserRuntimeDirectory(
            xdgRuntimeDir: nil, uid: 0, userRuntimeRoot: missing.path) == nil)

        let root = shortRuntimeDir("w")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A root this process can write: rvd makes `<root>/<uid>` itself.
        #expect(UnixSocketPath.uncreatableUserRuntimeDirectory(
            xdgRuntimeDir: nil, uid: 4242, userRuntimeRoot: root.path) == nil)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("4243"), withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        // Something already at `<root>/<uid>`: not this check's case.
        #expect(UnixSocketPath.uncreatableUserRuntimeDirectory(
            xdgRuntimeDir: nil, uid: 4243, userRuntimeRoot: root.path) == nil)
        if getuid() != 0 {
            #expect(UnixSocketPath.uncreatableUserRuntimeDirectory(
                xdgRuntimeDir: nil, uid: 4242, userRuntimeRoot: root.path) == root.path + "/4242")
        }
    }

    /// The fix sets both modes itself: under root's umask 027 a `mkdir -p`
    /// that also makes `/run/user` leaves it 0750, which the user cannot
    /// search.
    @Test func userRuntimeDirectoryFixSetsBothModesWhateverTheUmask() {
        #expect(UnixSocketPath.userRuntimeDirectoryFix(directory: "/run/user/4242", uid: 4242)
            == "as root, install -d -m 0755 /run/user && install -d -m 0700 -o 4242 /run/user/4242; "
            + "or set XDG_RUNTIME_DIR to a directory only you can access, for rvd and for your agents")
    }

    @Test func productionEmptyXDGThrows() throws {
        let previous = liveXDG()
        setenv("XDG_RUNTIME_DIR", "", 1)
        defer { restoreXDG(previous) }

        #expect(throws: UnixSocketPathError.runtimeDirectoryMissing) {
            try UnixSocketPath.production()
        }
    }
    #else
    @Test func injectedHomeResolvesUnderConfigRV() throws {
        let socket = try UnixSocketPath.resolve(homeDirectory: "/Users/x")
        #expect(socket.path == "/Users/x/.config/rv/evaluate.sock")
        let trimmed = try UnixSocketPath.resolve(homeDirectory: "  /Users/x\n")
        #expect(trimmed.path == "/Users/x/.config/rv/evaluate.sock")
    }

    @Test func unsetAndEmptyHomeFailClosed() {
        #expect(throws: UnixSocketPathError.runtimeDirectoryMissing) {
            try UnixSocketPath.resolve(homeDirectory: nil)
        }
        #expect(throws: UnixSocketPathError.runtimeDirectoryMissing) {
            try UnixSocketPath.resolve(homeDirectory: "")
        }
        #expect(throws: UnixSocketPathError.runtimeDirectoryMissing) {
            try UnixSocketPath.resolve(homeDirectory: "   ")
        }
    }

    @Test func homePathTooLongFailsClosed() {
        #expect(throws: UnixSocketPathError.pathTooLong) {
            _ = try UnixSocketPath.resolve(homeDirectory: "/" + String(repeating: "x", count: 90))
        }
    }

    @Test func productionReadsInjectedHome() throws {
        let previous = liveHome()
        let injected = shortRuntimeDir("h")
        setenv("HOME", injected.path, 1)
        defer { restoreHome(previous) }

        let socket = try UnixSocketPath.production()
        #expect(socket.path == injected.path + "/.config/rv/evaluate.sock")
        #expect(socket.lastPathComponent == UnixSocketPath.socketFileName)
    }

    @Test func productionUnsetHomeThrows() throws {
        let previous = liveHome()
        unsetenv("HOME")
        defer { restoreHome(previous) }

        #expect(throws: UnixSocketPathError.runtimeDirectoryMissing) {
            try UnixSocketPath.production()
        }
    }

    @Test func productionEmptyHomeThrows() throws {
        let previous = liveHome()
        setenv("HOME", "", 1)
        defer { restoreHome(previous) }

        #expect(throws: UnixSocketPathError.runtimeDirectoryMissing) {
            try UnixSocketPath.production()
        }
    }
    #endif

    @Test func prepareRuntimeCreatesOwnerOnlyDirs() throws {
        let xdg = shortRuntimeDir("p")
        let socket = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        try UnixSocketPath.prepareRuntime(for: socket)
        defer { try? FileManager.default.removeItem(at: xdg) }

        #expect(try UnixSocketPath.posixMode(of: xdg) & 0o777 == 0o700)
        #expect(try UnixSocketPath.posixMode(of: socket.deletingLastPathComponent()) & 0o777 == 0o700)
        #expect(FileManager.default.fileExists(atPath: socket.path) == false)
    }

    @Test func prepareRuntimeTightensSafePreexistingBaseToOwnerOnly() throws {
        let base = shortRuntimeDir("b")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: base.path
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let socket = try UnixSocketPath.resolve(xdgRuntimeDir: base.path)
        try UnixSocketPath.prepareRuntime(for: socket)

        #expect(try UnixSocketPath.posixMode(of: base) & 0o777 == 0o700)
        #expect(try UnixSocketPath.posixMode(of: socket.deletingLastPathComponent()) & 0o777 == 0o700)
    }

    @Test func prepareRuntimeRejectsGroupOrWorldWritableBase() throws {
        for mode in [0o770, 0o707] {
            let base = shortRuntimeDir("w")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            try FileManager.default.setAttributes(
                [.posixPermissions: mode],
                ofItemAtPath: base.path
            )

            let socket = try UnixSocketPath.resolve(xdgRuntimeDir: base.path)
            #expect(throws: UnixSocketPathError.permission) {
                try UnixSocketPath.prepareRuntime(for: socket)
            }
            #expect(try UnixSocketPath.posixMode(of: base) & 0o777 == mode)
            #expect(FileManager.default.fileExists(atPath: socket.deletingLastPathComponent().path) == false)
        }
    }

    @Test func xdgResolveUsesPlatformPathBudget() throws {
        // 106 bytes + NUL: fits the Linux 108 budget, exceeds Darwin's 104.
        let base = "/" + String(repeating: "y", count: 89 - 1)
        #if os(Linux)
        let socket = try UnixSocketPath.resolve(xdgRuntimeDir: base)
        #expect(socket.path.hasSuffix("/rv/evaluate.sock"))
        #else
        #expect(throws: UnixSocketPathError.pathTooLong) {
            _ = try UnixSocketPath.resolve(xdgRuntimeDir: base)
        }
        #endif
    }
}

/// Darwin TMPDIR plus a UUID overflows sockaddr_un (108 bytes) in resolve.
private func shortRuntimeDir(_ tag: String) -> URL {
    let token = String(UInt32.random(in: .min ... .max), radix: 16)
    return FileManager.default.temporaryDirectory
        .appendingPathComponent("rv\(tag)-\(token)", isDirectory: true)
}

private func liveXDG() -> String? {
    getenv("XDG_RUNTIME_DIR").map { String(cString: $0) }
}

private func restoreXDG(_ previous: String?) {
    if let previous {
        setenv("XDG_RUNTIME_DIR", previous, 1)
    } else {
        unsetenv("XDG_RUNTIME_DIR")
    }
}

private func liveHome() -> String? {
    getenv("HOME").map { String(cString: $0) }
}

private func restoreHome(_ previous: String?) {
    if let previous {
        setenv("HOME", previous, 1)
    } else {
        unsetenv("HOME")
    }
}
