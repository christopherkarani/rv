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
