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

    /// `MCPSandbox.profile` on a thread of its own: nil when it did not
    /// return within 30 s, so a walk that never ends fails the test instead
    /// of holding the run.
    private static func profileWithin30Seconds(
        home: String, scratch: String, temporary: String
    ) -> Result<String, MCPLaunchError>? {
        let box = ProfileBox()
        let done = DispatchSemaphore(value: 0)
        Thread {
            let result = MCPSandbox.profile(
                policy: MCPSandboxPolicy(network: false), scratch: scratch, home: home,
                configDirectory: home + "/.config/rv", temporaryDirectory: temporary)
            box.value.withLock { $0 = result }
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + 30) == .success else { return nil }
        return box.value.withLock { $0 }
    }

    private final class ProfileBox: Sendable {
        let value = Mutex<Result<String, MCPLaunchError>?>(nil)
    }

    /// Credential links whose targets hold `..` (absolute, through a
    /// symlinked directory, after a missing name, relative) and link
    /// cycles: each profile is built, or refused, in bounded time. Before,
    /// `URL.deletingLastPathComponent` turned `a/..` into `a/../..` and the
    /// ancestor walk never reached `/`.
    @Test(.timeLimit(.minutes(2)))
    func dotDotAndCyclicLinksAboveACredentialEndTheAncestorWalk() throws {
        let root = try MCPStrictProfileTests.resolvedTemporaryRoot("rv-walk-ends")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["tmp", "scratch", "home", "Users/me", "real/keys"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let home = root.appendingPathComponent("home").path
        let me = root.appendingPathComponent("Users/me").path
        try #require(symlink("/private/tmp/anchor", me + "/jump") == 0)
        try #require(symlink(root.path + "/b", root.path + "/a") == 0)
        try #require(symlink(root.path + "/a", root.path + "/b") == 0)
        try #require(symlink(root.path + "/c/sub", root.path + "/c") == 0)
        let shapes = [
            "/private/tmp/no-such/../future-keys",
            me + "/jump/../private/tmp/future-keys",
            me + "/jump/./../private/tmp/future-keys",
            me + "/jump/foo/../../private/tmp/future-keys",
            me + "/jump/../x/tmp/future-keys",
            "../real/../real/keys",
            root.path + "/a/keys",
            root.path + "/c/keys",
            root.path + "/real/keys/../../a/../real/keys",
        ]
        for shape in shapes {
            try? FileManager.default.removeItem(atPath: home + "/.ssh")
            try #require(symlink(shape, home + "/.ssh") == 0)
            let result = Self.profileWithin30Seconds(
                home: home, scratch: root.appendingPathComponent("scratch").path,
                temporary: root.appendingPathComponent("tmp").path)
            let built = try #require(result, "the profile for \(shape) did not return")
            switch built {
            case .success(let text):
                #expect(text.contains("(deny file-read* file-write* file-link file-clone "), "\(shape)")
            case .failure(.sandbox):
                break
            case .failure(let error):
                Issue.record("\(shape): \(error)")
            }
        }
    }

    @Test func dotComponentsAreTakenAsOpenTakesThem() throws {
        let root = try MCPStrictProfileTests.resolvedTemporaryRoot("rv-dot-components")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("y/z"), withIntermediateDirectories: true)
        try #require(symlink(root.path + "/y/z", root.path + "/x") == 0)
        #expect(MCPSandbox.withoutDotComponents(root.path + "/x/../k") == root.path + "/y/k")
        #expect(MCPSandbox.withoutDotComponents(root.path + "/./y/./z/k") == root.path + "/y/z/k")
        #expect(MCPSandbox.withoutDotComponents(root.path + "/missing/../k") == root.path + "/k")
        #expect(MCPSandbox.withoutDotComponents("/../..") == "/")
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
