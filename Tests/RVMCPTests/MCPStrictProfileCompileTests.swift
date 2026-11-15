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
    /// cycles: each profile is built, in bounded time, with the credential
    /// deny (none of these is past a cap, so a refusal is a regression).
    /// Before, `URL.deletingLastPathComponent` turned `a/..` into `a/../..`
    /// and the ancestor walk never reached `/`.
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
            root.path + "/c/../real/keys",
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
            case .failure(let error):
                Issue.record("\(shape) was refused: \(error)")
            }
        }
    }

    /// A directory `..` steps out of decides where the rest of the path
    /// lands, so `l` in `W/l/../keys` is named like any ancestor: at its
    /// link path and where it resolves, refused a rename or removal.
    @Test(.timeLimit(.minutes(1)))
    func aDirectoryADotDotStepsOutOfIsNamed() throws {
        let root = try MCPStrictProfileTests.resolvedTemporaryRoot("rv-dotdot-named")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["tmp", "scratch", "home", "z/q", "z/keys", "d"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let home = root.appendingPathComponent("home").path
        try #require(symlink(root.path + "/z/q", root.path + "/l") == 0)
        try #require(symlink(root.path + "/l/../keys", home + "/.ssh") == 0)
        try #require(symlink(root.path + "/d/../z/keys", home + "/.aws") == 0)
        let result = try #require(Self.profileWithin30Seconds(
            home: home, scratch: root.appendingPathComponent("scratch").path,
            temporary: root.appendingPathComponent("tmp").path), "the profile did not return")
        let text = try result.get()
        let ancestors = try #require(text.split(separator: "\n").first { $0.hasPrefix("(deny file-clone file-write-unlink ") })
        for path in ["l", "z/q", "z", "d"] {
            #expect(ancestors.contains("(literal \"\(root.path)/\(path)\")"), "\(path)")
        }
    }

    /// A directory link reached through another directory link
    /// (`~/.ssh -> W/b/keys`, `W/b -> Z/q`, `Z/q -> Y/r`) is named, so the
    /// inner link `Z/q` cannot be swapped. The dot-dot spelling of the
    /// outer link (`W/b -> Z/q/..`... here `~/.ssh -> W/b/../keys2`) names
    /// it too.
    @Test(.timeLimit(.minutes(1)))
    func aDirectoryLinkReachedThroughAnotherLinkIsNamed() throws {
        let root = try MCPStrictProfileTests.resolvedTemporaryRoot("rv-link-to-link")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["tmp", "scratch", "home", "Y/r/keys", "Y/r/keys2", "Z", "W"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let home = root.appendingPathComponent("home").path
        try #require(symlink(root.path + "/Y/r", root.path + "/Z/q") == 0)
        try #require(symlink(root.path + "/Z/q", root.path + "/W/b") == 0)
        try #require(symlink(root.path + "/W/b/keys", home + "/.ssh") == 0)
        try #require(symlink(root.path + "/W/b/../keys2", home + "/.aws") == 0)
        let result = try #require(Self.profileWithin30Seconds(
            home: home, scratch: root.appendingPathComponent("scratch").path,
            temporary: root.appendingPathComponent("tmp").path), "the profile did not return")
        let ancestors = try #require(try result.get().split(separator: "\n").first { $0.hasPrefix("(deny file-clone file-write-unlink ") })
        for path in ["W", "W/b", "Z", "Z/q", "Y", "Y/r"] {
            #expect(ancestors.contains("(literal \"\(root.path)/\(path)\")"), "\(path)")
        }
    }

    /// The whole class the last three findings share: for many seeded link
    /// trees, EVERY directory `open` passes through on the way to a
    /// credential is either outside every write root or named in the
    /// ancestor rule, so none can be swapped to move the credential.
    @Test(.timeLimit(.minutes(2)))
    func everyEntryOnACredentialPathInsideAWriteRootIsNamed() throws {
        for seed in UInt64(1)...40 {
            var rng = FuzzRandom(seed: seed)
            let root = try MCPStrictProfileTests.resolvedTemporaryRoot("rv-entries-\(seed)")
            defer { try? FileManager.default.removeItem(at: root) }
            for name in ["tmp", "scratch", "home"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            // A chain of directories, some replaced by links to the next, all
            // inside the temp write root, ending in a real key directory.
            let depth = Int.random(in: 2...6, using: &rng)
            var realDirs: [String] = []
            for level in 0..<depth {
                let dir = root.path + "/d\(level)"
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                realDirs.append(dir)
            }
            let keys = realDirs.last! + "/keys"
            try FileManager.default.createDirectory(atPath: keys, withIntermediateDirectories: true)
            // Build the credential link target by walking the chain, taking
            // a link hop (to a sibling link that points at the real dir) at
            // random, sometimes with a `..` detour.
            var target = keys
            for level in (0..<depth).reversed() {
                if Bool.random(using: &rng) {
                    let link = root.path + "/l\(level)_\(UInt16.random(in: 0...9999, using: &rng))"
                    try? FileManager.default.removeItem(atPath: link)
                    let points = Bool.random(using: &rng) ? realDirs[level] + "/../d\(level)" : realDirs[level]
                    try #require(symlink(points, link) == 0)
                    target = target.replacingOccurrences(of: realDirs[level], with: link)
                }
            }
            let sshPath = root.path + "/home/.ssh"
            try? FileManager.default.removeItem(atPath: sshPath)
            try #require(symlink(target, sshPath) == 0)
            let result = try #require(Self.profileWithin30Seconds(
                home: root.path + "/home", scratch: root.path + "/scratch",
                temporary: root.path + "/tmp"), "seed \(seed): the profile did not return")
            let ancestors = try #require(try result.get().split(separator: "\n")
                .first { $0.hasPrefix("(deny file-clone file-write-unlink ") }, "seed \(seed): no ancestor line")
            let entries = try #require(MCPSandbox.entriesOnPath(sshPath), "seed \(seed): entriesOnPath nil")
            let inside = MCPSandbox.insideAny([root.path + "/scratch", root.path + "/tmp", "/private/tmp", "/private/var/folders"])
            for entry in entries where entry != sshPath && entry != keys {
                guard inside(entry) else { continue }
                let real = MCPSandbox.realPath(entry)
                #expect(ancestors.contains("(literal \"\(entry)\")") || ancestors.contains("(literal \"\(real)\")"),
                    "seed \(seed): \(entry) (real \(real)) not named")
            }
        }
    }

    @Test func dotComponentsAreTakenAsOpenTakesThem() throws {
        let root = try MCPStrictProfileTests.resolvedTemporaryRoot("rv-dot-components")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("y/z"), withIntermediateDirectories: true)
        try #require(symlink(root.path + "/y/z", root.path + "/x") == 0)
        let link = MCPSandbox.withoutDotComponents(root.path + "/x/../k")
        #expect(link.path == root.path + "/y/k")
        #expect(link.steppedOutOf == [root.path + "/x"])
        let plain = MCPSandbox.withoutDotComponents(root.path + "/./y/./z/k")
        #expect(plain.path == root.path + "/y/z/k")
        #expect(plain.steppedOutOf.isEmpty)
        let missing = MCPSandbox.withoutDotComponents(root.path + "/missing/a/../../k")
        #expect(missing.path == root.path + "/k")
        #expect(missing.steppedOutOf == [root.path + "/missing/a", root.path + "/missing"])
        #expect(MCPSandbox.withoutDotComponents("/../..").path == "/")
        #expect(MCPSandbox.withoutDotComponents("/../..").steppedOutOf.isEmpty)
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
    /// small stack, without reaching libsandbox. Two letter-heavy components
    /// (each under NAME_MAX) carry the home past the raised cap; every
    /// credential deny repeats the prefix, so the profile clears 384 KiB.
    @Test(.timeLimit(.minutes(2)))
    func aTempSpelledHomeProfileIsRefusedBySizeNotACrash() throws {
        let long = String(repeating: "Abcdefghij", count: 20)
        let top = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-oversize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: top) }
        let root = top.appendingPathComponent(long, isDirectory: true).appendingPathComponent(long, isDirectory: true)
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
