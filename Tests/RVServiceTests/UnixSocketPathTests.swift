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

    @Test func prepareRuntimeCreatesOwnerOnlyDirs() throws {
        let xdg = shortRuntimeDir("p")
        let socket = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        try UnixSocketPath.prepareRuntime(for: socket)
        defer { try? FileManager.default.removeItem(at: xdg) }

        #expect(try UnixSocketPath.posixMode(of: xdg) & 0o777 == 0o700)
        #expect(try UnixSocketPath.posixMode(of: socket.deletingLastPathComponent()) & 0o777 == 0o700)
        #expect(FileManager.default.fileExists(atPath: socket.path) == false)
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
