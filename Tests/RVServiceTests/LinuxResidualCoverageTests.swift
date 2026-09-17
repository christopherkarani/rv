#if canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
@testable import RVService

struct LinuxResidualCoverageTests {
    @Test func unixSocketPath_injectedEnvironmentAndPathTooLong() throws {
        let socket = try UnixSocketPath.production(environment: ["XDG_RUNTIME_DIR": "/run/user/1"])
        #expect(socket.path == "/run/user/1/rv/evaluate.sock")
        #expect(throws: UnixSocketPathError.pathTooLong) {
            _ = try UnixSocketPath.resolve(xdgRuntimeDir: "/" + String(repeating: "x", count: 120))
        }
    }

    @Test func unixSocketPath_prepareRuntimeRemovesStaleSocket() throws {
        let xdg = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-xdg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: xdg) }
        let socket = try UnixSocketPath.resolve(xdgRuntimeDir: xdg.path)
        try UnixSocketPath.prepareRuntime(for: socket)
        try Data("stale".utf8).write(to: socket)
        #expect(FileManager.default.fileExists(atPath: socket.path))
        try UnixSocketPath.prepareRuntime(for: socket)
        #expect(FileManager.default.fileExists(atPath: socket.path) == false)
    }

    @Test func gitRebaseProbe_missingCwdIsFalse() {
        #expect(GitRebaseProbe.rebaseInProgress(cwd: nil) == false)
    }
}
