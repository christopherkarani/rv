#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import RVMCP

/// libsandbox expands a profile's conditions recursively, so its stack use
/// grows with the number of filters: an 828 KB profile overflowed a 512 KiB
/// thread (SIGBUS in `expand_logical_conditions`, this test process) and
/// compiled to an error on 1 MiB. `rv mcp serve` runs on a 512 KiB
/// cooperative-pool thread too. These compile from such a thread, which
/// must report, never crash.
extension MCPStrictProfileTests {
    private final class Outcome: Sendable {
        let value = Mutex<String??>(nil)
    }

    /// `profileCompileError` run on a 512 KiB thread: nil when it did not
    /// return within 90 s, otherwise its answer.
    private static func compileOnSmallStack(_ text: String) -> String?? {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let error = MCPSandbox.profileCompileError(text)
            outcome.value.withLock { $0 = .some(error) }
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        guard done.wait(timeout: .now() + 90) == .success else { return nil }
        return outcome.value.withLock { $0 }
    }

    /// 200 `sandbox.writable` entries: the write allows, the link allow and
    /// the directory-clone deny each name all of them.
    @Test(.timeLimit(.minutes(2)))
    func manyWriteRootsCompileFromASmallStack() throws {
        let root = try MCPStrictProfileTests.resolvedTemporaryRoot("rv-many-roots")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["tmp", "scratch", "home"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let writable = (0..<200).map { root.appendingPathComponent("w/\($0)").path }
        for path in writable {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let home = root.appendingPathComponent("home").path
        let text = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false, writable: writable), scratch: root.appendingPathComponent("scratch").path,
            home: home, configDirectory: home + "/.config/rv", temporaryDirectory: root.appendingPathComponent("tmp").path).get()
        let clone = try #require(text.split(separator: "\n").first { $0.contains("vnode-type DIRECTORY") })
        #expect(clone.components(separatedBy: "/w/").count > 200)
        let outcome = try #require(Self.compileOnSmallStack(text), "the compile did not return")
        #expect(outcome == nil, "\(outcome ?? "")")
    }

    /// The profile that crashed: a home under the temp directory as
    /// Foundation spells it, through `/var`. It is refused by size, from a
    /// small stack, without reaching libsandbox.
    @Test(.timeLimit(.minutes(2)))
    func aTempSpelledHomeProfileIsRefusedBySizeNotACrash() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-oversize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["tmp", "scratch"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let home = root.appendingPathComponent("home").path
        let text = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: root.appendingPathComponent("scratch").path,
            home: home, configDirectory: home + "/.config/rv", temporaryDirectory: root.appendingPathComponent("tmp").path).get()
        try #require(text.utf8.count > MCPSandbox.maximumProfileBytes, "\(text.utf8.count) bytes: the shape changed")
        let outcome = try #require(Self.compileOnSmallStack(text), "the compile did not return")
        let error = try #require(outcome, "an oversized profile compiled")
        #expect(error.contains("\(text.utf8.count) bytes"), "\(error)")
    }

    /// Just under the limit, with distinct filters: compiled on a 512 KiB
    /// stack, a 128 KB profile of these already overflowed (measured), so
    /// this passes only because the compile runs on rv's own thread.
    @Test(.timeLimit(.minutes(2)))
    func aProfileJustUnderTheLimitCompilesFromASmallStack() throws {
        var text = "(version 1)\n(allow default)\n"
        for index in 0... {
            let name = String(format: "%06d", index)
            let rule = "(deny file-read* (subpath \"/rv-compile-stack/\(name)/\(String(repeating: "d", count: 30))\") "
                + "(regex #\"^/rv-compile-stack/\(name)/[Kk][Ee][Yy](/+.*)?$\"))\n"
            guard text.utf8.count + rule.utf8.count <= MCPSandbox.maximumProfileBytes else { break }
            text += rule
        }
        let outcome = try #require(Self.compileOnSmallStack(text), "the compile did not return")
        #expect(outcome == nil, "\(outcome ?? "")")
    }
}
#endif
