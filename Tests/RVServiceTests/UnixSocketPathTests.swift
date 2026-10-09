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

    @Test func productionUnsetXDGThrowsWithoutCreatingTmpSocket() throws {
        let previous = liveXDG()
        unsetenv("XDG_RUNTIME_DIR")
        defer { restoreXDG(previous) }

        #expect(throws: UnixSocketPathError.runtimeDirectoryMissing) {
            try UnixSocketPath.production()
        }
        #expect(FileManager.default.fileExists(atPath: "/tmp/rv.sock") == false)
        #expect(FileManager.default.fileExists(atPath: "/tmp/evaluate.sock") == false)
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

    @Test func prepareRuntimeLeavesPreexistingBaseModeAlone() throws {
        let base = shortRuntimeDir("b")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: base.path
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let socket = try UnixSocketPath.resolve(xdgRuntimeDir: base.path)
        try UnixSocketPath.prepareRuntime(for: socket)

        #expect(try UnixSocketPath.posixMode(of: base) & 0o777 == 0o755)
        #expect(try UnixSocketPath.posixMode(of: socket.deletingLastPathComponent()) & 0o777 == 0o700)
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
